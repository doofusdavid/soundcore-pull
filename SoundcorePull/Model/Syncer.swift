import Foundation
import os

private let log = Logger(subsystem: "soundcore-pull", category: "protocol")

/// Keeps a recorder session alive in the background and pulls new recordings into the library.
@Observable @MainActor
final class Syncer {
    enum Phase: Equatable {
        case scanning
        case connected
        case pulling(fileId: UInt32, progress: Double)
        case failed(String)
    }

    private(set) var phase: Phase = .scanning
    private(set) var deviceInfo: DeviceInfo?
    private(set) var recordings: [RecordingEntry] = []
    private(set) var downloaded: Set<UInt32>
    private(set) var conversionIssue: String?

    var rows: [RecordingRow] { RecordingRow.merge(onRecorder: recordings, downloaded: downloaded) }

    let library: Library
    private let pendingDeletes = PendingDeletes()

    init(library: Library) {
        self.library = library
        downloaded = library.downloadedIds()
        try? FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        let thread = Thread { [self] in runForever() }
        thread.name = "soundcore-pull.sync"
        thread.start()
        let conversionThread = Thread { [self] in convertForever() }
        conversionThread.name = "soundcore-pull.m4a"
        conversionThread.start()
    }

    func deleteFromRecorder(_ fileId: UInt32) {
        pendingDeletes.append(fileId)
    }

    // MARK: background loop

    private nonisolated func post(_ change: @escaping @MainActor (Syncer) -> Void) {
        Task { @MainActor in change(self) }
    }

    private nonisolated func runForever() {
        while true {
            post { $0.phase = .scanning }
            let recorder = Recorder()
            do {
                try recorder.connect(scanTimeout: 30)
                try session(recorder)
            } catch RecorderError.notFound {
                // recorder asleep; scan again
            } catch {
                post { $0.phase = .failed("\(error)") }
                Thread.sleep(forTimeInterval: 3)
            }
            recorder.disconnect()
        }
    }

    private nonisolated func convertForever() {
        let converter = M4AConverter(library: library)
        while true {
            do {
                let issue = try converter.convertPending()
                post { $0.conversionIssue = issue }
            } catch {
                post { $0.conversionIssue = error.localizedDescription }
            }
            Thread.sleep(forTimeInterval: 15)
        }
    }

    private nonisolated func session(_ recorder: Recorder) throws {
        let crypto = DeviceCrypto()
        let infoReply = try recorder.request(Frames.getDeviceInfo(), type: 0x01, id: 0x01, timeout: 8, "device info")
        let info = DeviceInfo.parse(infoReply.payload)
        log.notice("device info: \(infoReply.hex, privacy: .public)")
        post { $0.deviceInfo = info; $0.phase = .connected }

        // The recorder stamps each recording's id with its own clock, so keep it in step with ours.
        let clockReply = try recorder.request(Frames.syncTime(), type: 0x01, id: 0xA6, timeout: 8, "clock sync")
        log.notice("clock sync: \(clockReply.hex, privacy: .public)")

        while true {
            let entries = try fetchRecordings(recorder)
            post { $0.recordings = entries }
            let have = library.downloadedIds()
            for entry in entries where !have.contains(entry.fileId) {
                try pull(entry, recorder: recorder, crypto: crypto)
            }
            for fileId in pendingDeletes.drain() {
                let reply = try recorder.request(Frames.deleteFile(fileId: fileId), type: 0x1A, id: 0x10, timeout: 10, "delete")
                if reply.status == 0 { post { $0.recordings.removeAll { $0.fileId == fileId } } }
            }
            post { $0.phase = .connected }
            for _ in 0..<15 where pendingDeletes.isEmpty {
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    private nonisolated func fetchRecordings(_ recorder: Recorder) throws -> [RecordingEntry] {
        var entries: [UInt32: RecordingEntry] = [:]
        for page in UInt16(0)..<50 {
            let reply = try recorder.request(Frames.listFiles(page: page), type: 0x1A, id: 0x0E, timeout: 8, "recording list")
            let pageEntries = RecordingEntry.parseList(reply.payload)
            log.notice("list 0x1A page \(page): \(reply.hex, privacy: .public) -> \(pageEntries.count) entries")
            let before = entries.count
            for entry in pageEntries { entries[entry.fileId] = entry }
            if entries.count == before { break }
        }
        return entries.values.sorted { $0.fileId > $1.fileId }
    }

    private nonisolated func pull(_ entry: RecordingEntry, recorder: Recorder, crypto: DeviceCrypto) throws {
        if !crypto.hasSession {
            let reply = try recorder.request(Frames.handshake(publicKey: crypto.publicKey), type: 0x2E, id: 0x01, timeout: 12, "encryption handshake")
            try crypto.completeHandshake(reply.payload)
        }
        defer { crypto.clearFile(entry.fileId) }
        post { $0.phase = .pulling(fileId: entry.fileId, progress: 0) }

        var audio = Data()
        var expected = Int(entry.sizeBytes)
        var chunks = 0
        try recorder.send(Frames.startExport(fileId: entry.fileId))
        while true {
            let frame = try recorder.next(timeout: 90, waitingFor: "file data")
            guard frame.type == 0x1A || frame.type == 0x1B else { continue }
            switch frame.id {
            case 0x07:
                log.notice("export header \(entry.fileId): \(frame.hex, privacy: .public)")
                let head = try crypto.prepareFile(frame.payload)
                log.notice("export header fileSize \(head.fileSize), list size \(entry.sizeBytes)")
                if head.fileSize > 0 { expected = Int(head.fileSize) }
            case 0x08, 0x12:
                let raw = frame.raw
                var offset = 9
                while raw.count - offset >= 165 {
                    let sequence = raw.u32le(at: offset)
                    offset += 5
                    let encrypted = Data(raw[offset..<(offset + 160)])
                    offset += 160
                    audio.append(try crypto.decryptChunk(fileId: entry.fileId, sequence: sequence, data: encrypted))
                    if offset < raw.count { offset += 1 }
                    chunks += 1
                }
                if chunks % 25 == 0 {
                    let progress = expected > 0 ? min(1, Double(audio.count) / Double(expected)) : 0
                    post { $0.phase = .pulling(fileId: entry.fileId, progress: progress) }
                }
            case 0x0A:
                guard !audio.isEmpty else { throw CryptoError.badFileKey }
                try library.save(OggOpus.mux(audio), for: entry)
                post { $0.downloaded.insert(entry.fileId) }
                return
            default:
                continue
            }
        }
    }
}

/// File ids the UI asked to delete, handed to the background loop.
final class PendingDeletes: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UInt32] = []

    var isEmpty: Bool { lock.withLock { ids.isEmpty } }

    func append(_ id: UInt32) { lock.withLock { ids.append(id) } }

    func drain() -> [UInt32] {
        lock.withLock {
            defer { ids.removeAll() }
            return ids
        }
    }
}
