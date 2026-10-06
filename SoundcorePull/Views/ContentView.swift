import AppKit
import SwiftUI

struct ContentView: View {
    let syncer: Syncer
    @State private var selection: UInt32?
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
            Divider()
            List(syncer.rows, selection: $selection) { row in
                self.row(row)
            }
            .overlay {
                if syncer.rows.isEmpty {
                    Text(syncer.phase == .scanning ? "Wake the recorder to see its recordings." : "No recordings on the recorder.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toolbar {
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([syncer.library.folder])
            }
            Button("Delete from Recorder", systemImage: "trash") { confirmingDelete = true }
                .disabled(!canDeleteSelection)
        }
        .confirmationDialog("Delete this recording from the recorder?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let selection { syncer.deleteFromRecorder(selection) }
            }
        } message: {
            Text("The copy in iCloud Drive is kept.")
        }
    }

    private var canDeleteSelection: Bool {
        guard let selection, syncer.phase != .scanning,
              let row = syncer.rows.first(where: { $0.fileId == selection }) else { return false }
        return row.onRecorder != nil && row.downloaded
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                    .font(.headline)
                    .frame(width: 20)
                    .contentTransition(.symbolEffect(.replace))
                Text(statusText).font(.headline)
            }
            if case .pulling(_, let progress) = syncer.phase {
                ProgressView(value: progress)
            } else if let info = syncer.deviceInfo, syncer.phase != .scanning {
                Text(deviceText(info)).foregroundStyle(.secondary)
            }
            if let issue = syncer.conversionIssue {
                Text("M4A conversion: \(issue)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch syncer.phase {
        case .scanning:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .symbolEffect(.rotate, options: .repeat(.continuous))
        case .connected:
            Image(systemName: "app.badge.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.orange, .primary)
        case .pulling:
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeat(.continuous))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var statusText: String {
        switch syncer.phase {
        case .scanning: return "Looking for recorder…"
        case .connected: return "Connected"
        case .pulling(let fileId, let progress):
            return "Pulling \(Self.date.string(from: Date(timeIntervalSince1970: TimeInterval(fileId)))) · \(Int(progress * 100))%"
        case .failed(let message): return "Problem: \(message)"
        }
    }

    private func deviceText(_ info: DeviceInfo) -> String {
        var parts: [String] = []
        if let battery = info.batteryPercent { parts.append("Battery \(battery)%\(info.charging ? " charging" : "")") }
        parts.append("\(info.freeKB / 1024) MB free")
        if !info.firmware.isEmpty { parts.append("Firmware \(info.firmware)") }
        if info.recording { parts.append("Recording now") }
        return parts.joined(separator: " · ")
    }

    private func row(_ row: RecordingRow) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(Self.date.string(from: row.startDate))
                Text(caption(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: symbol(for: row.fileId))
                .foregroundStyle(row.downloaded ? .green : .secondary)
        }
        .padding(.vertical, 2)
    }

    private func caption(_ row: RecordingRow) -> String {
        var parts: [String] = []
        if let entry = row.onRecorder, let duration = Self.duration.string(from: entry.estimatedDuration) {
            parts.append(duration)
        }
        parts.append(row.statusText)
        return parts.joined(separator: " · ")
    }

    private func symbol(for fileId: UInt32) -> String {
        if syncer.downloaded.contains(fileId) { return "checkmark.icloud" }
        if case .pulling(let pulling, _) = syncer.phase, pulling == fileId { return "arrow.down.circle" }
        return "circle.dashed"
    }

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
