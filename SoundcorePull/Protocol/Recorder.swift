import CoreBluetooth
import Foundation
import os

private let log = Logger(subsystem: "soundcore-pull", category: "rx")

enum RecorderError: Error, CustomStringConvertible {
    case bluetoothOff(CBManagerState)
    case notFound
    case connectFailed(String)
    case timeout(String)
    case notConnected

    var description: String {
        switch self {
        case .bluetoothOff(let state): return "Bluetooth not ready (state \(state.rawValue)); check System Settings > Privacy > Bluetooth"
        case .notFound: return "no Soundcore Work found; take it out of the case or tap it, and keep the phone app closed"
        case .connectFailed(let why): return "connect failed: \(why)"
        case .timeout(let what): return "timed out waiting for \(what)"
        case .notConnected: return "not connected"
        }
    }
}

/// Blocking CoreBluetooth session with one recorder. The CLI is sequential, so every call
/// blocks the calling thread while delegate callbacks arrive on a private queue.
final class Recorder: NSObject, RecorderTransport {
    private let excludedIdentifiers: Set<UUID>
    var identifier: UUID? { peripheral?.identifier }
    static let serviceUUID = CBUUID(string: "020cf5da-0000-1000-8000-00805f9b34fb")
    static let writeUUID = CBUUID(string: "00007777-0000-1000-8000-00805f9b34fb")
    static let notifyUUID = CBUUID(string: "00008888-0000-1000-8000-00805f9b34fb")

    private let queue = DispatchQueue(label: "soundcore-pull.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var packets = PacketBuffer()

    private let frames = NSCondition()
    private var pending: [Frame] = []
    private let step = DispatchSemaphore(value: 0)
    private var stepError: String?
    private var disconnected = false

    var name: String { peripheral?.name ?? "soundcore Work" }

    init(excluding identifiers: Set<UUID> = []) {
        excludedIdentifiers = identifiers
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func connect(scanTimeout: TimeInterval = 15) throws {
        guard step.wait(timeout: .now() + 5) == .success else { throw RecorderError.bluetoothOff(central.state) }
        guard central.state == .poweredOn else { throw RecorderError.bluetoothOff(central.state) }

        guard !frames.withLock({ disconnected }) else { throw RecorderError.notConnected }
        central.scanForPeripherals(withServices: [Self.serviceUUID])
        let found = step.wait(timeout: .now() + scanTimeout) == .success
        central.stopScan()
        guard !frames.withLock({ disconnected }) else { throw RecorderError.notConnected }
        guard found, let peripheral else { throw RecorderError.notFound }

        central.connect(peripheral)
        try waitStep("connection")
        peripheral.discoverServices([Self.serviceUUID])
        try waitStep("service discovery")
        try waitStep("characteristic discovery")
        try waitStep("notifications")
    }

    func disconnect() {
        frames.lock()
        disconnected = true
        pending.removeAll()
        frames.broadcast()
        frames.unlock()
        central.stopScan()
        step.signal()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func send(_ frame: Data) throws {
        guard !frames.withLock({ disconnected }), let peripheral, let writeCharacteristic else { throw RecorderError.notConnected }
        let type: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(frame, for: writeCharacteristic, type: type)
    }

    /// Next complete frame from the device, in arrival order.
    func next(timeout: TimeInterval, waitingFor what: String) throws -> Frame {
        frames.lock()
        defer { frames.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while pending.isEmpty {
            if disconnected { throw RecorderError.notConnected }
            guard frames.wait(until: deadline) else { throw RecorderError.timeout(what) }
        }
        return pending.removeFirst()
    }

    private func waitStep(_ what: String) throws {
        guard step.wait(timeout: .now() + 10) == .success else { throw RecorderError.timeout(what) }
        guard !frames.withLock({ disconnected }) else { throw RecorderError.notConnected }
        if let stepError { throw RecorderError.connectFailed("\(what): \(stepError)") }
    }

    private func finishStep(_ error: Error?) {
        stepError = error?.localizedDescription
        step.signal()
    }
}

extension Recorder: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .unknown && central.state != .resetting { step.signal() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil, !excludedIdentifiers.contains(peripheral.identifier) else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        step.signal()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { finishStep(nil) }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { finishStep(error) }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        frames.lock()
        disconnected = true
        frames.broadcast()
        frames.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            return finishStep(error ?? RecorderError.connectFailed("service missing"))
        }
        finishStep(nil)
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        writeCharacteristic = service.characteristics?.first { $0.uuid == Self.writeUUID }
        guard error == nil, writeCharacteristic != nil,
              let notify = service.characteristics?.first(where: { $0.uuid == Self.notifyUUID }) else {
            return finishStep(error ?? RecorderError.connectFailed("characteristics missing"))
        }
        finishStep(nil)
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        finishStep(error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let complete = packets.feed(value)
        guard !complete.isEmpty else { return }
        for frame in complete where frame.id != 0x08 && frame.id != 0x12 {
            log.notice("rx type \(String(frame.type, radix: 16), privacy: .public) id \(String(frame.id, radix: 16), privacy: .public): \(frame.hex, privacy: .public)")
        }
        frames.lock()
        pending.append(contentsOf: complete)
        frames.broadcast()
        frames.unlock()
    }
}
