import SkepCore
import SwiftUI

@main
struct SkepApp: App {
    @StateObject private var model = AppModel()
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

        Settings {
            SettingsView()
        }
    }
}

private struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("skep.appearance") private var appearance = SkepAppearance.dark.rawValue

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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                Text("Local workspaces use a private Unix socket. Remote hosts use your existing OpenSSH and Google Cloud CLI credentials. Passwords and private keys are never stored by Skep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 500, height: 230)
        .background(SkepUI.canvas(colorScheme))
        .preferredColorScheme(
            SkepAppearance(rawValue: appearance)?.colorScheme ?? .dark
        )
    }
}
