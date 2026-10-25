import XCTest
@testable import OpenDente

final class InhibitVerifierTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func sent() -> InhibitVerifier {
        var v = InhibitVerifier()
        v.didSend(at: t0)
        return v
    }

    /// Exhaust all retries, returning the verifier and the time of the last send.
    private func exhausted() -> (InhibitVerifier, Date) {
        var v = sent()
        var now = t0
        for _ in 1...InhibitVerifier.maxRetries {
            now = now.addingTimeInterval(InhibitVerifier.resendAfter)
            XCTAssertEqual(v.observe(stillCharging: true, now: now), .resend)
            v.didSend(at: now)
        }
        return (v, now)
    }

    func testDidSend_setsFirstOnlyOnce() {
        var v = sent()
        v.didSend(at: t0.addingTimeInterval(20))
        XCTAssertEqual(v.firstSent, t0)
        XCTAssertEqual(v.lastSent, t0.addingTimeInterval(20))
        XCTAssertEqual(v.elapsedSinceFirst(now: t0.addingTimeInterval(30)), 30)
    }

    func testElapsed_isInfinityWhenNothingSent() {
        let v = InhibitVerifier()
        XCTAssertEqual(v.elapsedSinceFirst(now: t0), .infinity)
        XCTAssertEqual(v.elapsedSinceLast(now: t0), .infinity)
    }

    func testResend_atFifteenSeconds_notBefore() {
        var v = sent()
        XCTAssertEqual(v.observe(stillCharging: true, now: t0.addingTimeInterval(14.9)), .none)
        XCTAssertEqual(v.retryCount, 0)
        XCTAssertEqual(v.observe(stillCharging: true, now: t0.addingTimeInterval(15)), .resend)
        XCTAssertEqual(v.retryCount, 1)
    }

    func testResend_whenNeverSent_resendsImmediately() {
        var v = InhibitVerifier()
        XCTAssertEqual(v.observe(stillCharging: true, now: t0), .resend)
    }

    func testStopsAfterThreeRetries_thenExhaustedExactlyOnce() {
        var (v, last) = exhausted()
        XCTAssertEqual(v.retryCount, 3)
        XCTAssertFalse(v.didNotifyExhausted)

        let later = last.addingTimeInterval(60)
        XCTAssertEqual(v.observe(stillCharging: true, now: later), .exhausted)
        XCTAssertTrue(v.didNotifyExhausted)
        XCTAssertEqual(v.observe(stillCharging: true, now: later.addingTimeInterval(60)), .none)
        XCTAssertEqual(v.retryCount, 3)
    }

    func testConfirm_atTwoSeconds_notBefore() {
        var v = sent()
        XCTAssertEqual(v.observe(stillCharging: false, now: t0.addingTimeInterval(1.9)), .none)
        XCTAssertNotNil(v.lastSent)
        XCTAssertEqual(v.observe(stillCharging: false, now: t0.addingTimeInterval(2)), .confirmed)
    }

    func testConfirm_clearsAllFields() {
        var (v, last) = exhausted()
        XCTAssertEqual(v.observe(stillCharging: true, now: last.addingTimeInterval(1)), .exhausted)
        XCTAssertEqual(v.observe(stillCharging: false, now: last.addingTimeInterval(3)), .confirmed)
        XCTAssertNil(v.lastSent)
        XCTAssertNil(v.firstSent)
        XCTAssertEqual(v.retryCount, 0)
        XCTAssertFalse(v.didNotifyExhausted)
    }

    func testNothingToConfirm_whenNeverSent() {
        var v = InhibitVerifier()
        XCTAssertEqual(v.observe(stillCharging: false, now: t0), .none)
    }

    func testResetRetryCount_clearsOnlyRetryCount() {
        var (v, last) = exhausted()
        _ = v.observe(stillCharging: true, now: last.addingTimeInterval(1))
        v.resetRetryCount()
        XCTAssertEqual(v.retryCount, 0)
        XCTAssertNotNil(v.lastSent)
        XCTAssertNotNil(v.firstSent)
        XCTAssertTrue(v.didNotifyExhausted)
    }

    func testResetForBattery_clearsFirstLastRetry_keepsNotified() {
        var (v, last) = exhausted()
        _ = v.observe(stillCharging: true, now: last.addingTimeInterval(1))
        v.resetForBattery()
        XCTAssertNil(v.lastSent)
        XCTAssertNil(v.firstSent)
        XCTAssertEqual(v.retryCount, 0)
        XCTAssertTrue(v.didNotifyExhausted)
    }

    func testResetAll_clearsEverything() {
        var (v, last) = exhausted()
        _ = v.observe(stillCharging: true, now: last.addingTimeInterval(1))
        v.resetAll()
        XCTAssertNil(v.lastSent)
        XCTAssertNil(v.firstSent)
        XCTAssertEqual(v.retryCount, 0)
        XCTAssertFalse(v.didNotifyExhausted)
    }
}
