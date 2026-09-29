import XCTest
@testable import SoundcorePull

final class RecorderPairingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var pairing: RecorderPairing!

    override func setUp() {
        suite = "RecorderPairingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        pairing = RecorderPairing(defaults: defaults)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testFirstConnectionPersistsBeforeAnyRecordingCommandAndSurvivesReload() throws {
        let transport = FakeRecorder(serial: "MY-RECORDER")
        transport.onSend = { frame in
            if frame != Frames.getDeviceInfo() {
                XCTAssertEqual(self.defaults.string(forKey: RecorderPairing.serialKey), "my-recorder")
            }
        }
        let recorder = try connect(transport)
        XCTAssertEqual(transport.sent, [Frames.getDeviceInfo()])
        try recorder.send(Frames.listFiles(page: 0))
        try recorder.send(Frames.startExport(fileId: 1))
        try recorder.send(Frames.deleteFile(fileId: 1))
        XCTAssertEqual(RecorderPairing(defaults: defaults).serial, "my-recorder")
    }

    func testDeviceInfoResponseWithObservedFirmwareHeaderPairsSuccessfully() throws {
        // Reproduce the on-device RX header and payload layout, with a synthetic serial.
        let payload = Data([1, 1, 0]) + Data("03.44".utf8) + Data("TEST000000000001".utf8)
        var raw = Data([0x09, 0xFF, 0, 0, 0x01, 0x01, 0x01, 34, 0]) + payload
        raw.append(Frames.checksum(raw))
        var buffer = PacketBuffer()
        let frame = try XCTUnwrap(buffer.feed(raw).first)
        let transport = FakeRecorder(payload: frame.payload, status: frame.status)
        let recorder = try connect(transport)
        XCTAssertEqual(pairing.serial, "test000000000001")
        try recorder.send(Frames.listFiles(page: 0))
        XCTAssertEqual(transport.sent, [Frames.getDeviceInfo(), Frames.listFiles(page: 0)])
    }

    func testMatchingReconnectRechecksInfoBeforeListing() throws {
        _ = try connect(FakeRecorder(serial: "mine"))
        let transport = FakeRecorder(serial: "mine")
        let recorder = try connect(transport)
        try recorder.send(Frames.listFiles(page: 0))
        XCTAssertEqual(transport.sent, [Frames.getDeviceInfo(), Frames.listFiles(page: 0)])
    }

    func testMismatchDisconnectsWithoutListExportOrDeleteAndKeepsPairing() throws {
        _ = try connect(FakeRecorder(serial: "mine"))
        let transport = FakeRecorder(serial: "coworker")
        XCTAssertThrowsError(try connect(transport)) { error in
            guard case PairingError.differentRecorder = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(transport.sent, [Frames.getDeviceInfo()])
        XCTAssertTrue(transport.disconnected)
        XCTAssertEqual(pairing.serial, "mine")
    }

    func testInvalidInfoNeverPairsOrEnumerates() {
        for transport in [FakeRecorder(serial: ""), FakeRecorder(payload: Data(repeating: 0, count: 23)),
                          FakeRecorder(serial: "bad\nserial"), FakeRecorder(serial: "valid", status: 0),
                          FakeRecorder(payload: Data(repeating: 0xFF, count: 24))] {
            XCTAssertThrowsError(try connect(transport))
            XCTAssertNil(pairing.serial)
            XCTAssertTrue(transport.disconnected)
            XCTAssertEqual(transport.sent, [Frames.getDeviceInfo()])
        }
    }

    func testForgetRevokesEveryCommandAndLocalSaveThenAllowsNewRecorder() throws {
        let transport = FakeRecorder(serial: "mine")
        let recorder = try connect(transport)
        pairing.forget()
        XCTAssertNil(RecorderPairing(defaults: defaults).serial)
        XCTAssertTrue(transport.disconnected)
        for command in [Frames.listFiles(page: 0), Frames.startExport(fileId: 1), Frames.deleteFile(fileId: 1)] {
            XCTAssertThrowsError(try recorder.send(command))
        }
        var saved = false
        XCTAssertThrowsError(try recorder.authorized { saved = true })
        XCTAssertFalse(saved)
        XCTAssertEqual(transport.sent, [Frames.getDeviceInfo()])
        _ = try connect(FakeRecorder(serial: "replacement"))
        XCTAssertEqual(pairing.serial, "replacement")
        XCTAssertThrowsError(try recorder.send(Frames.deleteFile(fileId: 1)))
    }

    func testForgetDuringInfoReplyCannotPairOldSession() {
        let transport = FakeRecorder(serial: "mine")
        transport.onNext = { self.pairing.forget() }
        XCTAssertThrowsError(try connect(transport))
        XCTAssertNil(pairing.serial)
        XCTAssertEqual(transport.sent, [Frames.getDeviceInfo()])
    }

    func testForgetDuringDownloadDiscardsBufferedReply() throws {
        let transport = FakeRecorder(serial: "mine")
        let recorder = try connect(transport)
        transport.onNext = { self.pairing.forget() }
        XCTAssertThrowsError(try recorder.next(timeout: 1, waitingFor: "file data"))
    }

    func testRejectedDevicesAreSkippedUntilForgetAndOldSessionCannotRejectAgain() {
        let token = pairing.currentGeneration
        let id = UUID()
        pairing.reject(id, generation: token)
        XCTAssertEqual(pairing.rejectedIdentifiers, [id])
        pairing.forget()
        XCTAssertTrue(pairing.rejectedIdentifiers.isEmpty)
        pairing.reject(id, generation: token)
        XCTAssertTrue(pairing.rejectedIdentifiers.isEmpty)
    }

    private func connect(_ transport: FakeRecorder) throws -> PairedRecorder {
        let token = pairing.begin { transport.disconnect() }
        return try PairedRecorder(transport, pairing: pairing, generation: token)
    }
}

private final class FakeRecorder: RecorderTransport {
    var sent: [Data] = []
    var disconnected = false
    var onSend: ((Data) -> Void)?
    var onNext: (() -> Void)?
    let reply: Frame

    convenience init(serial: String, status: UInt8 = 1) {
        let bytes = Data(serial.utf8.prefix(16))
        self.init(payload: Data(repeating: 0, count: 8) + bytes + Data(repeating: 0, count: 16 - bytes.count), status: status)
    }

    init(payload: Data, status: UInt8 = 1) {
        reply = Frame(raw: Data(), status: status, type: 0x01, id: 0x01, payload: payload)
    }
    func send(_ frame: Data) throws { sent.append(frame); onSend?(frame) }
    func next(timeout: TimeInterval, waitingFor what: String) throws -> Frame { onNext?(); return reply }
    func disconnect() { disconnected = true }
}
