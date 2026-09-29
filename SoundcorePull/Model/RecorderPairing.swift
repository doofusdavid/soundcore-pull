import Foundation

enum PairingError: Error {
    case invalidDeviceInfo
    case differentRecorder
    case forgotten
}

/// Serial is the identity; peripheral IDs only keep rejected advertisers out of this scan cycle.
/// The generation invalidates in-flight handshakes and work when the user forgets a recorder.
final class RecorderPairing: @unchecked Sendable {
    static let serialKey = "pairedRecorderSerial"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var generation = UUID()
    private var rejected: Set<UUID> = []
    private var cancel: (() -> Void)?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var serial: String? { lock.withLock { defaults.string(forKey: Self.serialKey) } }
    var currentGeneration: UUID { lock.withLock { generation } }
    var rejectedIdentifiers: Set<UUID> { lock.withLock { rejected } }

    func begin(_ cancel: @escaping () -> Void) -> UUID {
        lock.withLock {
            self.cancel = cancel
            return generation
        }
    }

    func verify(_ info: DeviceInfo, generation token: UUID) throws {
        try lock.withLock {
            guard token == generation else { throw PairingError.forgotten }
            guard !info.serial.isEmpty,
                  info.serial.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else {
                throw PairingError.invalidDeviceInfo
            }
            if let saved = defaults.string(forKey: Self.serialKey) {
                guard saved == info.serial else { throw PairingError.differentRecorder }
            } else {
                defaults.set(info.serial, forKey: Self.serialKey)
            }
        }
    }

    func reject(_ identifier: UUID?, generation token: UUID) {
        lock.withLock {
            if token == generation, let identifier { rejected.insert(identifier) }
        }
    }

    /// Only short sends / local commits run under this lock, never a blocking Bluetooth wait.
    func authorized<T>(_ token: UUID, _ action: () throws -> T) throws -> T {
        try lock.withLock {
            guard token == generation, defaults.string(forKey: Self.serialKey) != nil else {
                throw PairingError.forgotten
            }
            return try action()
        }
    }

    func forget() {
        let disconnect: (() -> Void)? = lock.withLock {
            generation = UUID()
            defaults.removeObject(forKey: Self.serialKey)
            rejected.removeAll()
            defer { cancel = nil }
            return cancel
        }
        disconnect?()
    }
}

protocol RecorderTransport: AnyObject {
    func send(_ frame: Data) throws
    func next(timeout: TimeInterval, waitingFor what: String) throws -> Frame
    func disconnect()
}

extension RecorderTransport {
    func request(_ frame: Data, type: UInt8, id: UInt8, timeout: TimeInterval, _ what: String) throws -> Frame {
        try send(frame)
        while true {
            let reply = try next(timeout: timeout, waitingFor: what)
            if reply.type == type && reply.id == id { return reply }
        }
    }
}

/// Cannot be constructed until DeviceInfo.serial is accepted and persisted. Every subsequent
/// command, including list/export/delete, passes through the revocable authorization gate.
final class PairedRecorder: RecorderTransport {
    private let transport: RecorderTransport
    private let pairing: RecorderPairing
    let generation: UUID
    let info: DeviceInfo

    init(_ transport: RecorderTransport, pairing: RecorderPairing, generation: UUID) throws {
        self.transport = transport
        self.pairing = pairing
        self.generation = generation
        do {
            let reply = try transport.request(Frames.getDeviceInfo(), type: 0x01, id: 0x01, timeout: 8, "device info")
            // Device-info replies use 0x01 (observed on firmware 03.44).
            // Do not borrow the delete-command success code, which is 0x00.
            guard reply.status == 0x01, reply.payload.count >= 24 else { throw PairingError.invalidDeviceInfo }
            info = DeviceInfo.parse(reply.payload)
            try pairing.verify(info, generation: generation)
        } catch {
            transport.disconnect()
            throw error
        }
    }

    func send(_ frame: Data) throws {
        try authorized { try transport.send(frame) }
    }

    func next(timeout: TimeInterval, waitingFor what: String) throws -> Frame {
        try authorized {}
        let reply = try transport.next(timeout: timeout, waitingFor: what)
        try authorized {}
        return reply
    }

    func authorized<T>(_ action: () throws -> T) throws -> T {
        try pairing.authorized(generation, action)
    }

    func disconnect() { transport.disconnect() }
}
