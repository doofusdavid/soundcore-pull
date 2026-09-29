import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let syncer: Syncer
    @State private var confirmingForget = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Paired Recorder") {
                if let serial = syncer.pairedSerial {
                    LabeledContent("Serial number", value: serial)
                    Button("Forget Recorder…", role: .destructive) { confirmingForget = true }
                } else {
                    Text("No recorder paired")
                    Text("The next compatible recorder found will be paired automatically. Keep only your recorder awake and nearby.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
            Text("Keeps the recorder syncing without opening the app by hand.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .confirmationDialog("Forget the paired recorder?", isPresented: $confirmingForget) {
            Button("Forget Recorder", role: .destructive) { syncer.forgetRecorder() }
        } message: {
            Text("This stops the current sync. The next compatible recorder found will be paired automatically. Keep only your intended recorder awake and nearby. Downloaded files are kept.")
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
        .onChange(of: launchAtLogin) { _, enabled in
            guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                launchAtLogin = !enabled
            }
        }
    }
}
