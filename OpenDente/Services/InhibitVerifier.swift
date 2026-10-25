import Foundation

/// Tracks whether an inhibit write took effect, and when to re-send it or give up.
///
/// IOKit can lag 15-30s on Apple Silicon before reflecting a new charging state,
/// so re-sends are debounced at `resendAfter` and capped at `maxRetries`.
struct InhibitVerifier {
    static let resendAfter: TimeInterval = 15
    static let maxRetries = 3
    /// Minimum time since the last send before "not charging" counts as confirmation,
    /// so the evaluateState call that sent the inhibit can't confirm it.
    static let confirmAfter: TimeInterval = 2

    /// Timestamp of last inhibit send, used to debounce re-sends.
    private(set) var lastSent: Date?
    /// Timestamp of the first inhibit in the current cycle, used for total elapsed logging.
    private(set) var firstSent: Date?
    /// Number of verification re-sends in the current inhibit cycle.
    private(set) var retryCount = 0
    /// Whether the user was already told about retry exhaustion this cycle.
    private(set) var didNotifyExhausted = false

    enum Outcome: Equatable { case none, resend, exhausted, confirmed }

    /// Record that an inhibit write was just sent.
    mutating func didSend(at now: Date) {
        lastSent = now
        if firstSent == nil { firstSent = now }
    }

    /// Seconds since the first send in this cycle (infinity if none).
    func elapsedSinceFirst(now: Date) -> TimeInterval {
        firstSent.map { now.timeIntervalSince($0) } ?? .infinity
    }

    /// Seconds since the last send (infinity if none).
    func elapsedSinceLast(now: Date) -> TimeInterval {
        lastSent.map { now.timeIntervalSince($0) } ?? .infinity
    }

    /// Call only while in an inhibited mode (paused / sailing / heatProtection).
    /// On `.resend` the caller must re-send the inhibit, which calls `didSend`.
    mutating func observe(stillCharging: Bool, now: Date) -> Outcome {
        let elapsed = elapsedSinceLast(now: now)
        if stillCharging {
            if elapsed >= Self.resendAfter && retryCount < Self.maxRetries {
                retryCount += 1
                return .resend
            } else if retryCount >= Self.maxRetries && !didNotifyExhausted {
                didNotifyExhausted = true
                return .exhausted
            }
        } else if lastSent != nil && elapsed >= Self.confirmAfter {
            resetAll()
            return .confirmed
        }
        return .none
    }

    /// Mode change: only the retry budget restarts.
    mutating func resetRetryCount() { retryCount = 0 }

    /// Unplugged: drop pending verification but keep the exhausted-notified flag.
    mutating func resetForBattery() {
        firstSent = nil
        lastSent = nil
        retryCount = 0
    }

    /// Wake, enable-charging and confirmation: start over completely.
    mutating func resetAll() {
        firstSent = nil
        lastSent = nil
        retryCount = 0
        didNotifyExhausted = false
    }
}
