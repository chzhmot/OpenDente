import XCTest
@testable import OpenDente

/// In-memory SMC: key -> (type, size, bytes). Records every write in order.
/// Writes update the stored bytes so read-back works.
final class FakeSMC: SMCAccess {
    struct Write: Equatable {
        let key: String
        let bytes: [UInt8]
        init(_ key: String, _ bytes: [UInt8]) { self.key = key; self.bytes = bytes }
    }
    struct WriteError: Error {}

    private var store: [String: (type: String, size: UInt32, bytes: [UInt8])] = [:]
    private(set) var writes: [Write] = []
    var failingKeys: Set<String> = []

    func add(_ key: String, type: String = "ui8 ", bytes: [UInt8]) {
        store[key] = (type, UInt32(bytes.count), bytes)
    }

    func readKeyOptional(_ key: String) -> SMCValue? {
        guard let e = store[key] else { return nil }
        return SMCValue(key: key, dataSize: e.size, dataType: e.type, bytes: e.bytes)
    }

    func writeKey(_ key: String, bytes: [UInt8]) throws {
        if failingKeys.contains(key) { throw WriteError() }
        writes.append(Write(key, bytes))
        if let e = store[key] { store[key] = (e.type, e.size, bytes) }
    }

    func keyInfo(_ key: String) -> (type: String, size: UInt32)? {
        store[key].map { ($0.type, $0.size) }
    }

    func clearWrites() { writes = [] }
}

private typealias W = FakeSMC.Write

final class ChargingBackendTests: XCTestCase {

    // MARK: - Fixtures

    private func tahoeSMC() -> FakeSMC {
        let s = FakeSMC()
        s.add("CHTE", type: "hex_", bytes: [0, 0, 0, 0])
        s.add("CHIE", bytes: [0])
        return s
    }

    private func legacySMC() -> FakeSMC {
        let s = FakeSMC()
        s.add("CH0B", bytes: [0])
        s.add("CH0C", bytes: [0])
        s.add("CH0I", bytes: [0])
        return s
    }

    private func firmwareKeys(_ s: FakeSMC, mode: UInt8 = 0x00) {
        s.add("bfD0", type: "ui32", bytes: [100, 0, 0, 0])
        s.add("bfE0", type: "ui32", bytes: [98, 0, 0, 0])
        s.add("bfF0", type: "ui8 ", bytes: [mode])
    }

    private func firmwareBackend(percentage: Int? = 57, adapterKey: String? = "CHIE") -> (FirmwareBackend, FakeSMC) {
        let s = FakeSMC()
        firmwareKeys(s)
        if let k = adapterKey { s.add(k, bytes: [0]) }
        let b = FirmwareBackend(smc: s, batteryPercentage: { percentage },
                                adapterKey: adapterKey ?? "CHIE", adapterCutByte: 0x08)
        return (b, s)
    }

    private func adapterBackend(key: String = "CHIE", cut: UInt8 = 0x08, keyPresent: Bool = true) -> (AdapterBackend, FakeSMC) {
        let s = FakeSMC()
        if keyPresent { s.add(key, bytes: [0]) }
        return (AdapterBackend(smc: s, adapterKey: key, adapterCutByte: cut), s)
    }

    // MARK: - Tahoe

    func testTahoeWrites() throws {
        let s = tahoeSMC()
        let b = TahoeBackend(smc: s)
        XCTAssertEqual(b.api, .tahoe)

        try b.enable()
        XCTAssertEqual(s.writes, [W("CHTE", [0, 0, 0, 0])])
        s.clearWrites()
        try b.inhibit()
        XCTAssertEqual(s.writes, [W("CHTE", [1, 0, 0, 0])])
        s.clearWrites()
        try b.setDischarge(true)
        XCTAssertEqual(s.writes, [W("CHIE", [0x08]), W("CHTE", [1, 0, 0, 0])])
        s.clearWrites()
        try b.setDischarge(false)
        XCTAssertEqual(s.writes, [W("CHIE", [0x00])])
        s.clearWrites()
        try b.reset()
        XCTAssertEqual(s.writes, [W("CHIE", [0x00]), W("CHTE", [0, 0, 0, 0])])
    }

    func testTahoeReadbackMismatchDoesNotThrow() throws {
        let s = FakeSMC()   // CHTE not readable at all: readback fails, still no throw
        let b = TahoeBackend(smc: s)
        XCTAssertNoThrow(try b.inhibit())
        XCTAssertNoThrow(try b.enable())
    }

    // MARK: - Legacy

    func testLegacyWrites() throws {
        let s = legacySMC()
        let b = LegacyBackend(smc: s)
        XCTAssertEqual(b.api, .legacy)

        try b.enable()
        XCTAssertEqual(s.writes, [W("CH0B", [0]), W("CH0C", [0])])
        s.clearWrites()
        try b.inhibit()
        XCTAssertEqual(s.writes, [W("CH0B", [2]), W("CH0C", [2])])
        s.clearWrites()
        try b.setDischarge(true)
        XCTAssertEqual(s.writes, [W("CH0I", [1]), W("CH0B", [2]), W("CH0C", [2])])
        s.clearWrites()
        try b.setDischarge(false)
        XCTAssertEqual(s.writes, [W("CH0I", [0])])
        s.clearWrites()
        try b.reset()
        XCTAssertEqual(s.writes, [W("CH0I", [0]), W("CH0B", [0]), W("CH0C", [0])])
    }

    // MARK: - Firmware

    func testFirmwareEnableAndReset() throws {
        let (b, s) = firmwareBackend()
        XCTAssertEqual(b.api, .firmware)
        try b.enable()
        XCTAssertEqual(s.writes, [W("bfF0", [0])])
        s.clearWrites()
        try b.reset()
        XCTAssertEqual(s.writes, [W("CHIE", [0]), W("bfF0", [0])])
    }

    func testFirmwareResetSkipsMissingAdapterKey() throws {
        let (b, s) = firmwareBackend(adapterKey: nil)
        try b.reset()
        XCTAssertEqual(s.writes, [W("bfF0", [0])])
    }

    func testFirmwareResetIgnoresAdapterKeyWriteFailure() throws {
        let (b, s) = firmwareBackend()
        s.failingKeys = ["CHIE"]
        try b.reset()
        XCTAssertEqual(s.writes, [W("bfF0", [0])])
    }

    func testFirmwareInhibitAt57() throws {
        let (b, s) = firmwareBackend(percentage: 57)
        try b.inhibit()
        // range(holding: 57) = upper 57, lower 55
        XCTAssertEqual(s.writes, [
            W("bfF0", [0x00]),
            W("bfD0", [57, 0, 0, 0]),
            W("bfE0", [55, 0, 0, 0]),
            W("bfF0", [0x02]),
        ])
    }

    func testFirmwareInhibitWithoutPercentageThrowsAndWritesNothing() {
        let (b, s) = firmwareBackend(percentage: nil)
        XCTAssertThrowsError(try b.inhibit()) { error in
            guard case ChargingBackendError.percentageUnavailable = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertTrue(s.writes.isEmpty)
    }

    func testFirmwareInhibitFailureMidwayRollsBackToNormal() {
        let (b, s) = firmwareBackend(percentage: 57)
        s.failingKeys = ["bfE0"]
        XCTAssertThrowsError(try b.inhibit()) { XCTAssertTrue($0 is FakeSMC.WriteError) }
        XCTAssertEqual(s.writes, [
            W("bfF0", [0x00]),
            W("bfD0", [57, 0, 0, 0]),
            W("bfF0", [0x00]),   // rollback
        ])
    }

    func testFirmwareInhibitReadbackMismatchRollsBackAndThrows() {
        let s2 = FakeSMC()
        s2.add("bfF0", type: "ui8 ", bytes: [0])  // bfD0 missing: readback nil -> mismatch
        let b2 = FirmwareBackend(smc: s2, batteryPercentage: { 57 }, adapterKey: "CHIE", adapterCutByte: 0x08)
        XCTAssertThrowsError(try b2.inhibit()) { error in
            guard case ChargingBackendError.readbackMismatch(let key) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(key, "bfD0")
        }
        XCTAssertEqual(s2.writes.last, W("bfF0", [0x00]))
    }

    func testFirmwareDischarge() throws {
        let (b, s) = firmwareBackend()
        try b.setDischarge(true)
        XCTAssertEqual(s.writes, [W("CHIE", [0x08])])
        s.clearWrites()
        try b.setDischarge(false)
        XCTAssertEqual(s.writes, [W("CHIE", [0x00])])
    }

    func testFirmwareDischargeWithoutAdapterKeyThrows() {
        let (b, s) = firmwareBackend(adapterKey: nil)
        XCTAssertThrowsError(try b.setDischarge(true)) {
            XCTAssertEqual($0.localizedDescription, "No adapter key for force discharge")
        }
        XCTAssertThrowsError(try b.setDischarge(false))
        XCTAssertTrue(s.writes.isEmpty)
    }

    // MARK: - Adapter

    func testAdapterWritesCHIE() throws {
        let (b, s) = adapterBackend()
        XCTAssertEqual(b.api, .adapter)
        try b.enable()
        XCTAssertEqual(s.writes, [W("CHIE", [0])])
        s.clearWrites()
        try b.inhibit()
        XCTAssertEqual(s.writes, [W("CHIE", [0x08])])
        s.clearWrites()
        try b.setDischarge(true)
        XCTAssertEqual(s.writes, [W("CHIE", [0x08])])
        s.clearWrites()
        try b.setDischarge(false)
        XCTAssertEqual(s.writes, [W("CHIE", [0x00])])
        s.clearWrites()
        try b.reset()
        XCTAssertEqual(s.writes, [W("CHIE", [0]), W("CHIE", [0])])
    }

    func testAdapterWritesCH0J() throws {
        let (b, s) = adapterBackend(key: "CH0J", cut: 0x20)
        try b.inhibit()
        try b.setDischarge(true)
        try b.setDischarge(false)
        try b.reset()
        XCTAssertEqual(s.writes, [
            W("CH0J", [0x20]), W("CH0J", [0x20]), W("CH0J", [0x00]),
            W("CH0J", [0]), W("CH0J", [0]),
        ])
    }

    func testAdapterDischargeWithoutKeyThrows() {
        let (b, s) = adapterBackend(keyPresent: false)
        XCTAssertThrowsError(try b.setDischarge(true)) {
            XCTAssertEqual($0.localizedDescription, "No adapter key for force discharge")
        }
        XCTAssertThrowsError(try b.setDischarge(false))
        XCTAssertTrue(s.writes.isEmpty)
    }

    // MARK: - Detection

    func testDetectTahoe() {
        let s = tahoeSMC()
        s.add("CH0B", bytes: [0])   // CHTE wins over CH0B
        XCTAssertEqual(detectChargingBackend(smc: s, batteryPercentage: { 50 })?.api, .tahoe)
    }

    func testDetectLegacy() {
        XCTAssertEqual(detectChargingBackend(smc: legacySMC(), batteryPercentage: { 50 })?.api, .legacy)
    }

    func testDetectFirmwareWhenWritable() {
        let s = FakeSMC()
        firmwareKeys(s)
        s.add("CHIE", bytes: [0])
        let backend = detectChargingBackend(smc: s, batteryPercentage: { 50 })
        XCTAssertEqual(backend?.api, .firmware)
        // Detection re-writes bfF0 normal as its probe
        XCTAssertEqual(s.writes, [W("bfF0", [0])])
    }

    func testDetectFirmwareWhenModeAlreadyLimitedDoesNotProbe() {
        let s = FakeSMC()
        firmwareKeys(s, mode: 0x02)
        s.failingKeys = ["bfF0"]
        XCTAssertEqual(detectChargingBackend(smc: s, batteryPercentage: { 50 })?.api, .firmware)
        XCTAssertTrue(s.writes.isEmpty)
    }

    func testDetectFirmwareKeysWithWrongLayoutIsNotFirmware() {
        let s = FakeSMC()
        s.add("bfD0", type: "ui16", bytes: [1, 0])
        s.add("bfE0", type: "ui32", bytes: [0, 0, 0, 0])
        s.add("bfF0", type: "ui8 ", bytes: [0])
        XCTAssertNil(detectChargingBackend(smc: s, batteryPercentage: { 50 }))
    }

    func testDetectAdapterWhenFirmwareKeysNotWritable() throws {
        let s = FakeSMC()
        firmwareKeys(s)
        s.add("CHIE", bytes: [0])
        s.failingKeys = ["bfF0"]
        let backend = detectChargingBackend(smc: s, batteryPercentage: { 50 })
        XCTAssertEqual(backend?.api, .adapter)
        try backend?.inhibit()
        XCTAssertEqual(s.writes, [W("CHIE", [0x08])])
    }

    func testDetectAdapterCH0JUsesCutByte0x20() throws {
        let s = FakeSMC()
        s.add("CH0J", bytes: [0])
        let backend = detectChargingBackend(smc: s, batteryPercentage: { 50 })
        XCTAssertEqual(backend?.api, .adapter)
        try backend?.inhibit()
        XCTAssertEqual(s.writes, [W("CH0J", [0x20])])
    }

    func testDetectAdapterPrefersCHIEOverCH0J() throws {
        let s = FakeSMC()
        s.add("CHIE", bytes: [0])
        s.add("CH0J", bytes: [0])
        let backend = detectChargingBackend(smc: s, batteryPercentage: { 50 })
        try backend?.inhibit()
        XCTAssertEqual(s.writes, [W("CHIE", [0x08])])
    }

    func testDetectFirmwareCarriesCH0JAdapterKey() throws {
        let s = FakeSMC()
        firmwareKeys(s)
        s.add("CH0J", bytes: [0])
        let backend = detectChargingBackend(smc: s, batteryPercentage: { 50 })
        XCTAssertEqual(backend?.api, .firmware)
        s.clearWrites()
        try backend?.setDischarge(true)
        XCTAssertEqual(s.writes, [W("CH0J", [0x20])])
    }

    func testDetectNothingIsNil() {
        XCTAssertNil(detectChargingBackend(smc: FakeSMC(), batteryPercentage: { 50 }))
    }
}
