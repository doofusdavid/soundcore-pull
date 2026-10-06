import Foundation

/// Creates Talat-compatible AAC copies without changing the archived OGGs.
struct M4AConverter {
    let library: Library

    static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Called by a dedicated worker, including when no recorder is connected.
    /// Failed files remain eligible on the next pass; one bad recording does not block others.
    func convertPending() throws -> String? {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: library.folder.path)
        let existing = Set(names)
        var issue: String?
        for name in names.sorted() where Library.fileId(fromName: name) != nil {
            let evicted = name.hasPrefix(".") && name.hasSuffix(".icloud")
            let original = evicted ? String(name.dropFirst().dropLast(7)) : name
            let source = library.folder.appendingPathComponent(original)
            let output = source.deletingPathExtension().appendingPathExtension("m4a")
            guard !existing.contains(output.lastPathComponent),
                  !existing.contains(".\(output.lastPathComponent).icloud") else { continue }
            guard let executable = Self.ffmpeg else {
                return "Install FFmpeg with brew install ffmpeg to create M4A copies."
            }
            do {
                if evicted {
                    try manager.startDownloadingUbiquitousItem(at: source)
                    continue // Convert after iCloud has restored the original on a later pass.
                }
                let values = try source.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                if values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try manager.startDownloadingUbiquitousItem(at: source)
                    continue
                }
                try convert(source, using: executable)
            } catch {
                if issue == nil { issue = "\(original): \(error.localizedDescription)" }
            }
        }
        return issue
    }

    func convert(_ source: URL, using executable: URL) throws {
        let manager = FileManager.default
        let output = source.deletingPathExtension().appendingPathExtension("m4a")
        guard !manager.fileExists(atPath: output.path),
              !manager.fileExists(atPath: output.deletingLastPathComponent()
                .appendingPathComponent(".\(output.lastPathComponent).icloud").path) else { return }
        let temp = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).part")
        defer { try? manager.removeItem(at: temp) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                             "-i", source.path, "-map", "0:a:0", "-c:a", "aac", "-b:a", "96k",
                             "-f", "mp4", temp.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain before waiting so a full stderr pipe cannot stall FFmpeg.
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let size = try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else {
            let detail = String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "SoundcorePull.M4A", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "FFmpeg did not create an M4A file." : detail])
        }
        // A same-directory rename publishes only a completed file and never overwrites a copy.
        try manager.moveItem(at: temp, to: output)
    }
}
