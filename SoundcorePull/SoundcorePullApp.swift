import AppKit
import SwiftUI

@main
struct SoundcorePullApp: App {
    @State private var syncer = Syncer(
        library: .iCloud,
        startAutomatically: ProcessInfo.processInfo.environment["SOUNDCORE_PULL_TESTING"] != "1"
    )

    var body: some Scene {
        WindowGroup {
            ContentView(syncer: syncer)
                .frame(minWidth: 480, minHeight: 360)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Soundcore Pull") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Soundcore Pull",
                        .credits: Self.credits,
                    ])
                }
            }
        }
        Settings {
            SettingsView(syncer: syncer)
        }
    }

    private static let credits: NSAttributedString = {
        let credits = NSMutableAttributedString()
        let links: [(String, String)] = [
            ("Website", "https://knorthfield.github.io/soundcore-pull/"),
            ("Source on GitHub", "https://github.com/knorthfield/soundcore-pull"),
        ]
        for (index, (title, url)) in links.enumerated() {
            if index > 0 { credits.append(NSAttributedString(string: "\n")) }
            credits.append(NSAttributedString(string: title, attributes: [.link: url]))
        }
        credits.addAttributes(
            [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)],
            range: NSRange(location: 0, length: credits.length)
        )
        return credits
    }()
}
