import SkepCore
import SkepTerminal
import SwiftUI

@main
struct SkepApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updates = AppUpdateController()
    @AppStorage("skep.appearance") private var appearance = SkepAppearance.dark.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1120, minHeight: 760)
                .preferredColorScheme(
                    SkepAppearance(rawValue: appearance)?.colorScheme ?? .dark
                )
                .tint(.primary)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }

        Window("Skep Terminal", id: "terminal") {
            Group {
                if let session = model.activeTerminal {
                    TerminalPanel(session: session)
                        .id(session.id)
                } else {
                    ContentUnavailableView(
                        "No terminal selected",
                        systemImage: "terminal",
                        description: Text("Open a host, builder, or workspace terminal from the main window.")
                    )
                }
            }
            .preferredColorScheme(
                SkepAppearance(rawValue: appearance)?.colorScheme ?? .dark
            )
            .tint(.primary)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(updates: updates)
        }
    }
}

private struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("skep.appearance") private var appearance = SkepAppearance.dark.rawValue
    @ObservedObject var updates: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance")
                    .font(.headline)
                Text("Choose the day or night presentation. The interface remains strictly monochrome in both modes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AppearancePicker(selection: $appearance)
                    .frame(maxWidth: 260)
            }
            Divider()
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Updates")
                        .font(.headline)
                    Text("Skep checks its signed release feed automatically and installs updates in the background when macOS permits it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check now") {
                    updates.checkForUpdates()
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                Text("Local workspaces use a private Unix socket. Remote hosts use your existing OpenSSH and Google Cloud CLI credentials. Passwords and private keys are never stored by Skep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 520, height: 320)
        .background(SkepUI.canvas(colorScheme))
        .preferredColorScheme(
            SkepAppearance(rawValue: appearance)?.colorScheme ?? .dark
        )
    }
}
