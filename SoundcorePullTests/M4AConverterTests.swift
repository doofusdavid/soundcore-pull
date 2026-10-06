import XCTest
@testable import SoundcorePull

final class M4AConverterTests: XCTestCase {
    func testConversionBackfillsPreservesOriginalAndRetriesFailures() throws {
        let ffmpeg = try XCTUnwrap(M4AConverter.ffmpeg, "Install FFmpeg to run the audio integration check.")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("M4A check \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = Library(folder: folder)
        let converter = M4AConverter(library: library)
        let source = folder.appendingPathComponent("20261006-120000-100.ogg")
        try run(ffmpeg, ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
                         "-ac", "1", "-c:a", "libopus", source.path])
        let original = try Data(contentsOf: source)
        XCTAssertNil(try converter.convertPending())
        let output = source.deletingPathExtension().appendingPathExtension("m4a")
        let converted = try Data(contentsOf: output)
        XCTAssertFalse(converted.isEmpty)
        // Decode the actual output, rather than accepting any nonempty file as success.
        try run(ffmpeg, ["-i", output.path, "-f", "null", "-"])
        XCTAssertNil(try converter.convertPending())
        XCTAssertEqual(try Data(contentsOf: output), converted)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(library.downloadedIds(), [100])

        let broken = folder.appendingPathComponent("20261006-120000-200.ogg")
        try Data("invalid audio".utf8).write(to: broken)
        let later = folder.appendingPathComponent("20261006-120000-250.ogg")
        try original.write(to: later)
        XCTAssertNotNil(try converter.convertPending())
        XCTAssertTrue(FileManager.default.fileExists(atPath: later.deletingPathExtension().appendingPathExtension("m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.deletingPathExtension().appendingPathExtension("m4a").path))
        XCTAssertEqual(try Data(contentsOf: broken), Data("invalid audio".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".part") })
        try original.write(to: broken)
        XCTAssertNil(try converter.convertPending())
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.deletingPathExtension().appendingPathExtension("m4a").path))

        // Existing evicted M4As count as completed conversions too.
        let archived = folder.appendingPathComponent("20261006-120000-300.ogg")
        try original.write(to: archived)
        try Data().write(to: folder.appendingPathComponent(".20261006-120000-300.m4a.icloud"))
        XCTAssertNil(try converter.convertPending())
        XCTAssertFalse(FileManager.default.fileExists(atPath: archived.deletingPathExtension().appendingPathExtension("m4a").path))
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n"] + arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostic, as: UTF8.self))
    }
}
