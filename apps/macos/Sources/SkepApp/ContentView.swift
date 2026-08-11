import AppKit
import Network
import SkepCore
import SkepTerminal
import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @AppStorage("skep.appearance") private var appearance = SkepAppearance.dark.rawValue
    @StateObject private var connectivity = NetworkReachability()
    @State private var purgeHostConfirmation = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
            Rectangle()
                .fill(SkepUI.rule(colorScheme))
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SkepUI.canvas(colorScheme))
        }
        .background(SkepUI.canvas(colorScheme))
        .sheet(isPresented: $model.showingAddHost) {
            AddHostView { model.addHost($0) }
        }
        .alert(
            model.pendingDeletion?.kind == .builder ? "Delete builder?" : "Destroy workspace?",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.pendingDeletion = nil } }
            ),
            presenting: model.pendingDeletion
        ) { _ in
            Button("Cancel", role: .cancel) { model.pendingDeletion = nil }
            Button("Destroy", role: .destructive) { model.confirmDeletion() }
        } message: { workspace in
            Text(
                workspace.kind == .builder
                    ? "\(workspace.name), its editable microVM disk, and its Docker data disk will be permanently removed. Templates already published from it remain available."
                    : "\(workspace.name), its microVM disk, and its Docker data disk will be permanently removed."
            )
        }
        .alert(
            "Delete template?",
            isPresented: Binding(
                get: { model.pendingTemplateDeletion != nil },
                set: { if !$0 { model.pendingTemplateDeletion = nil } }
            ),
            presenting: model.pendingTemplateDeletion
        ) { _ in
            Button("Cancel", role: .cancel) { model.pendingTemplateDeletion = nil }
            Button("Delete", role: .destructive) { model.confirmTemplateDeletion() }
        } message: { template in
            Text("\(template.name) and its snapshot will be removed. Existing workspaces created from it are unaffected.")
        }
        .alert("Install or update Skep on this host?", isPresented: $model.showingInstallHostServiceConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Install Skep") { model.installHostService() }
        } message: {
            if model.selectedHost?.isLocal == true {
                Text("Skep will install its signed local helpers and checksum-pinned Apple Silicon Microsandbox runtime in Application Support. MicroVM data uses the shorter ~/.skep/msb path required by macOS Unix sockets. Administrator access is not required.")
            } else {
                Text("Skep will upload its bundled, checksummed Linux resources, install skepctl, skepd, and the pinned Microsandbox runtime with sudo, then enable the skepd system service.")
            }
        }
        .alert("Uninstall Skep and keep its data?", isPresented: $model.showingRemoveHostServiceConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall, keep data", role: .destructive) { model.removeHostService() }
        } message: {
            if model.selectedHost?.isLocal == true {
                Text("This removes the local Skep helpers and Microsandbox runtime. Local workspace state and exports are preserved.")
            } else {
                Text("This removes skepctl, skepd, the system service, and its sudo rule. Workspaces, templates, exports, and Microsandbox under /var/lib/skep are preserved.")
            }
        }
        .alert("Erase all Skep data from this VM?", isPresented: $model.showingPurgeHostConfirmation) {
            TextField("Type \(purgeConfirmationHostName)", text: $purgeHostConfirmation)
            Button("Cancel", role: .cancel) { purgeHostConfirmation = "" }
            Button("Erase everything", role: .destructive) {
                model.purgeHostServiceAndData()
                purgeHostConfirmation = ""
            }
            .disabled(purgeHostConfirmation != purgeConfirmationHostName)
        } message: {
            Text("This permanently stops and deletes every Skep builder and workspace, all templates, Docker volumes, exports, the Microsandbox runtime, skepd, skepctl, the system service, sudo rule, and /var/lib/skep. The underlying VM is not deleted. This cannot be undone.")
        }
        .onChange(of: model.showingPurgeHostConfirmation) { _, showing in
            if showing { purgeHostConfirmation = "" }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            model.beginAutomaticTerminalReconnectWindow()
        }
        .onChange(of: connectivity.isOnline) { previous, current in
            if previous == false, current == true {
                model.beginAutomaticTerminalReconnectWindow()
            }
        }
        .onChange(of: model.activeTerminal?.id) { _, sessionID in
            guard sessionID != nil else { return }
            openWindow(id: "terminal")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("SKEP")
                    .font(.system(size: 19, weight: .bold))
                    .tracking(2.8)
                Text("ISOLATED COMPUTE")
                    .font(SkepUI.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 24)

            ScrollView {
                LazyVStack(spacing: 0) {
                    sidebarSectionHeader("LOCAL")
                    HostSidebarGroup(model: model, host: .local)
                        .padding(.bottom, 18)

                    HStack {
                        Text("REMOTE HOSTS")
                            .font(SkepUI.eyebrow)
                            .tracking(1.1)
                            .foregroundStyle(SkepUI.muted(colorScheme))
                        Spacer()
                        Button { model.showingAddHost = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                                .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Add host")
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)

                    ForEach(model.remoteHosts) { host in
                        HostSidebarGroup(model: model, host: host)
                            .padding(.bottom, 4)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            VStack(spacing: 13) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("APPEARANCE")
                        .font(SkepUI.eyebrow)
                        .tracking(1.0)
                        .foregroundStyle(SkepUI.muted(colorScheme))
                    AppearancePicker(selection: $appearance)
                }

                HStack(spacing: 0) {
                    Button { model.showingAddHost = true } label: {
                        Text("ADD HOST")
                            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                    Button { model.removeSelectedHost() } label: {
                        Text("FORGET HOST")
                            .frame(maxWidth: .infinity, minHeight: 26, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .disabled(!model.canRemoveSelectedHost)
                }
                .font(SkepUI.eyebrow)
                .foregroundStyle(SkepUI.muted(colorScheme))
            }
            .padding(14)
            .overlay(alignment: .top) {
                Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            }
        }
        .background(SkepUI.rail(colorScheme))
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(SkepUI.eyebrow)
                .tracking(1.1)
                .foregroundStyle(SkepUI.muted(colorScheme))
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    private var purgeConfirmationHostName: String {
        model.selectedHost?.name ?? ""
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            if let host = model.selectedHost {
                HostDetailView(model: model, host: host)
                    .opacity(model.selectedWorkspace == nil ? 1 : 0)
                    .allowsHitTesting(model.selectedWorkspace == nil)
                    .accessibilityHidden(model.selectedWorkspace != nil)
            } else {
                EmptyHostView { model.showingAddHost = true }
            }

            ForEach(model.workspaceTerminalSessions) { session in
                if let workspaceID = session.workspaceID,
                   let workspace = model.cachedWorkspaces(for: session.host.id).first(where: {
                       $0.id == workspaceID
                   }) {
                    let active = model.isWorkspaceSessionActive(session)
                    WorkspaceTerminalSurface(
                        model: model,
                        host: session.host,
                        workspace: workspace,
                        session: session,
                        active: active
                    )
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                }
            }

            if let destination = model.selectedWorkspace,
               let host = model.hosts.first(where: { $0.id == destination.hostID }),
               let workspace = model.selectedWorkspaceItem,
               !model.workspaceTerminalSessions.contains(where: {
                   $0.matches(hostID: destination.hostID, workspaceID: destination.workspaceID)
               }) {
                WorkspaceStatusSurface(model: model, host: host, workspace: workspace)
            }
        }
    }
}

private struct HostSidebarGroup: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let host: SSHHost

    private var selected: Bool {
        model.selectedHostID == host.id && model.selectedWorkspace == nil
    }

    private var expanded: Bool {
        model.isHostExpanded(host.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HostSidebarRow(
                host: host,
                selected: selected,
                connected: model.isHostReady(host.id),
                busy: model.selectedHostID == host.id && model.isBusy,
                expanded: expanded,
                toggleExpansion: { model.toggleHostExpansion(host.id) },
                action: { model.selectHost(host.id) }
            )

            if expanded {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("WORKSPACES")
                            .font(SkepUI.eyebrow)
                            .tracking(0.8)
                        Text("\(model.cachedWorkspaces(for: host.id).count)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SkepUI.muted(colorScheme))
                        Spacer()
                        if model.selectedHostID == host.id && model.isHostReady(host.id) {
                            Button {
                                model.beginWorkspace()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .semibold))
                                    .frame(width: 24, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.templates.isEmpty)
                            .help(model.templates.isEmpty ? "Publish a template first" : "New workspace")
                        }
                    }
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .padding(.leading, 42)
                    .padding(.trailing, 8)
                    .frame(height: 32)

                    workspaceRows
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(SkepUI.rule(colorScheme))
                        .frame(width: 1)
                        .padding(.leading, 20)
                }
            }
        }
    }

    @ViewBuilder
    private var workspaceRows: some View {
        let cached = model.cachedWorkspaces(for: host.id)
        if !cached.isEmpty {
            ForEach(cached) { workspace in
                WorkspaceSidebarRow(
                    workspace: workspace,
                    selected: model.isWorkspaceSelected(hostID: host.id, workspaceID: workspace.id),
                    terminalState: model.workspaceTerminalConnectionState(
                        hostID: host.id,
                        workspaceID: workspace.id
                    ),
                    connectionIssue: model.workspaceConnectionIssue(
                        hostID: host.id,
                        workspaceID: workspace.id
                    )
                ) {
                    model.selectWorkspace(hostID: host.id, workspace: workspace)
                }
            }
        } else if model.selectedHostID == host.id && model.isBusy && !model.hasLoadedWorkspaces(for: host.id) {
            SidebarWorkspaceMessage(text: "LOADING", loading: true)
        } else if model.hasLoadedWorkspaces(for: host.id) {
            SidebarWorkspaceMessage(text: "NO WORKSPACES")
        } else {
            SidebarWorkspaceMessage(text: "SELECT HOST TO LOAD")
        }
    }
}

private struct HostSidebarRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let host: SSHHost
    let selected: Bool
    let connected: Bool
    let busy: Bool
    let expanded: Bool
    let toggleExpansion: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggleExpansion) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 28, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: action) {
                HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(host.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .opacity(0.62)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Rectangle()
                        .fill(connected ? currentInk : .clear)
                        .frame(width: 7, height: 7)
                        .overlay(Rectangle().stroke(currentInk.opacity(0.7), lineWidth: 1))
                }
                }
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(currentInk)
        .background(selected ? SkepUI.ink(colorScheme) : .clear)
        .overlay(Rectangle().stroke(selected ? SkepUI.ink(colorScheme) : .clear, lineWidth: 1))
    }

    private var currentInk: Color {
        selected ? SkepUI.inverseInk(colorScheme) : SkepUI.ink(colorScheme)
    }

    private var iconName: String {
        switch host.kind {
        case .local: "desktopcomputer"
        case .ssh: "server.rack"
        case .gcloudIAP: "cloud"
        }
    }

    private var subtitle: String {
        switch host.kind {
        case .local: "APPLE SILICON"
        case .ssh: host.hostname
        case .gcloudIAP: host.gcloudInstance
        }
    }
}

private struct WorkspaceSidebarRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let workspace: Workspace
    let selected: Bool
    let terminalState: TerminalConnectionState?
    let connectionIssue: HostConnectionIssue?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Rectangle()
                    .fill(workspace.status == .running ? currentInk : .clear)
                    .frame(width: 8, height: 8)
                    .overlay(Rectangle().stroke(currentInk, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .opacity(0.62)
                }
                Spacer(minLength: 4)
                Rectangle()
                    .fill(terminalIndicatorFilled ? currentInk : .clear)
                    .frame(width: 6, height: 6)
                    .overlay(Rectangle().stroke(currentInk.opacity(0.65), lineWidth: 1))
            }
            .padding(.leading, 40)
            .padding(.trailing, 11)
            .frame(maxWidth: .infinity, minHeight: 43)
            .contentShape(Rectangle())
            .foregroundStyle(currentInk)
            .background(selected ? SkepUI.ink(colorScheme) : .clear)
        }
        .buttonStyle(.plain)
    }

    private var currentInk: Color {
        selected ? SkepUI.inverseInk(colorScheme) : SkepUI.ink(colorScheme)
    }

    private var terminalIndicatorFilled: Bool {
        guard workspace.status == .running, connectionIssue == nil else { return false }
        return terminalState == nil || terminalState == .connected
    }

    private var statusText: String {
        guard workspace.status == .running else { return workspace.status.rawValue.uppercased() }
        if connectionIssue?.requiresGoogleCloudAuthentication == true { return "REAUTH REQUIRED" }
        return switch terminalState {
        case .reconnecting: "RECONNECTING"
        case .disconnected: "DISCONNECTED"
        case .connected, .none: workspace.status.rawValue.uppercased()
        }
    }
}

private struct SidebarWorkspaceMessage: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var loading = false

    var body: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.mini) }
            Text(text)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(0.4)
            Spacer()
        }
        .foregroundStyle(SkepUI.muted(colorScheme))
        .padding(.leading, 42)
        .frame(height: 34)
    }
}

private struct WorkspaceTerminalSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let host: SSHHost
    let workspace: Workspace
    let session: TerminalSession
    let active: Bool

    private var connectionState: TerminalConnectionState {
        model.terminalConnectionState(for: session)
    }

    private var connectionIssue: HostConnectionIssue? {
        model.terminalConnectionIssue(for: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            ZStack(alignment: .top) {
                TerminalView(
                    session: session,
                    isActive: active && connectionState != .disconnected,
                    onProcessExit: {
                        Task { @MainActor in
                            model.workspaceTerminalDidExit(sessionID: session.id)
                        }
                    }
                )
                .background(Color.black)

                if connectionState == .disconnected {
                    connectionLostNotice
                        .padding(.top, 18)
                        .padding(.horizontal, 24)
                }
            }
        }
        .background(SkepUI.canvas(colorScheme))
    }

    private var connectionLostNotice: some View {
        HStack(spacing: 16) {
            Rectangle()
                .fill(SkepUI.ink(colorScheme))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(connectionIssue?.label ?? "CONNECTION LOST")
                    .font(SkepUI.eyebrow)
                    .tracking(1)
                Text(connectionIssue?.workspaceMessage ?? "The workspace is still running. Reconnect opens a new terminal shell.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
            Spacer()
            if connectionIssue?.requiresGoogleCloudAuthentication == true {
                Button(model.isReauthenticatingGoogleCloud(hostID: host.id) ? "Opening browser…" : "Reauthenticate") {
                    model.reauthenticateGoogleCloud(hostID: host.id)
                }
                .buttonStyle(PrimaryButtonStyle(minWidth: 142))
                .disabled(model.isReauthenticatingGoogleCloud(hostID: host.id))
            } else {
                Button(connectionState == .reconnecting ? "Reconnecting…" : "Retry") {
                    model.reconnectWorkspaceTerminal(hostID: host.id, workspaceID: workspace.id)
                }
                .buttonStyle(SecondaryButtonStyle(minWidth: 102))
                .disabled(connectionState == .reconnecting)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: 660, minHeight: 64)
        .background(SkepUI.canvas(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }

    private var workspaceHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("WORKSPACE")
                    .font(SkepUI.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(SkepUI.muted(colorScheme))
                HStack(spacing: 10) {
                    Text(workspace.name)
                        .font(.system(size: 27, weight: .semibold))
                        .lineLimit(1)
                    StatusBadge(text: connectionBadge, filled: connectionState == .connected)
                }
                Text("\(host.name)  /  \(profileSummary(workspace.resources))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 24)
            Button("Host overview") { model.showSelectedHostManagement() }
                .buttonStyle(SecondaryButtonStyle(minWidth: 132))
            if connectionState != .connected {
                if connectionIssue?.requiresGoogleCloudAuthentication == true {
                    Button(model.isReauthenticatingGoogleCloud(hostID: host.id) ? "Opening browser…" : "Reauthenticate") {
                        model.reauthenticateGoogleCloud(hostID: host.id)
                    }
                    .buttonStyle(PrimaryButtonStyle(minWidth: 142))
                    .disabled(model.isReauthenticatingGoogleCloud(hostID: host.id))
                } else {
                    Button(connectionState == .reconnecting ? "Reconnecting…" : "Reconnect") {
                        model.reconnectWorkspaceTerminal(hostID: host.id, workspaceID: workspace.id)
                    }
                    .buttonStyle(PrimaryButtonStyle(minWidth: 132))
                    .disabled(connectionState == .reconnecting)
                }

                Button(model.activeResourceOperation?.targets(workspace.id) == true ? "Stopping…" : "Stop") {
                    model.setRunning(workspace, running: false)
                }
                .buttonStyle(SecondaryButtonStyle(minWidth: 108))
                .disabled(model.resourceOperationInProgress)
            } else {
                Button(model.activeResourceOperation?.targets(workspace.id) == true ? "Stopping…" : "Stop") {
                    model.setRunning(workspace, running: false)
                }
                .buttonStyle(PrimaryButtonStyle(minWidth: 108))
                .disabled(model.resourceOperationInProgress)
            }
        }
        .padding(.horizontal, 32)
        .frame(height: 94)
    }

    private var connectionBadge: String {
        switch connectionState {
        case .connected: workspace.status.rawValue.capitalized
        case .reconnecting: "Reconnecting"
        case .disconnected: connectionIssue?.badge ?? "Connection lost"
        }
    }
}

private final class NetworkReachability: ObservableObject, @unchecked Sendable {
    @Published private(set) var isOnline: Bool?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.skep.network-reachability")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

private struct WorkspaceStatusSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let host: SSHHost
    let workspace: Workspace

    private var targeted: Bool {
        model.activeResourceOperation?.targets(workspace.id) == true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if targeted {
                        ResourceOperationNotice(
                            title: model.activeResourceOperation?.title ?? "Updating workspace",
                            message: "Applying the requested machine state change. The terminal will open when the workspace is ready.",
                            working: true
                        )
                    } else if workspace.status == .error {
                        CapabilityNotice(
                            label: "WORKSPACE ERROR",
                            title: "This workspace needs attention",
                            message: workspace.lastError ?? "The workspace runtime reported an unknown error."
                        )
                    }

                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 16) {
                            MachineStatus(status: workspace.status)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(workspaceStateTitle)
                                    .font(.system(size: 20, weight: .semibold))
                                Text(workspaceStateMessage)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(SkepUI.muted(colorScheme))
                            }
                            Spacer()
                            if workspace.status == .running {
                                Button("Open terminal") { model.openSelectedWorkspaceTerminal() }
                                    .buttonStyle(PrimaryButtonStyle(minWidth: 150))
                            } else if workspace.status != .creating {
                                Button(targeted ? "Starting…" : "Start workspace") {
                                    model.setRunning(workspace, running: true)
                                }
                                .buttonStyle(PrimaryButtonStyle(minWidth: 150))
                                .disabled(model.resourceOperationInProgress)
                            }
                        }
                        .padding(22)
                        Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
                        HStack(spacing: 0) {
                            workspaceFact("HOST", host.name)
                            workspaceFact("RESOURCES", profileSummary(workspace.resources))
                            workspaceFact("AUTOSTART", workspace.autostart ? "ON" : "OFF")
                            workspaceFact("DOCKER DISK", formatGiB(UInt64(workspace.resources.dockerVolumeMib)))
                        }
                    }
                    .background(SkepUI.faint(colorScheme))
                    .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))

                    Text("Closing Skep or switching to another host does not stop this workspace. Machine lifecycle is always explicit.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SkepUI.muted(colorScheme))
                }
                .padding(32)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
            }
        }
        .background(SkepUI.canvas(colorScheme))
    }

    private var workspaceStateTitle: String {
        switch workspace.status {
        case .creating: "Workspace is being created"
        case .running: "Workspace is running"
        case .stopped: "Workspace is stopped"
        case .error: "Workspace is unavailable"
        }
    }

    private var workspaceStateMessage: String {
        switch workspace.status {
        case .creating:
            "Skep is preparing the isolated machine and its dedicated Docker disk."
        case .running:
            "The machine is ready. Open its terminal to attach a client session."
        case .stopped:
            "Its filesystem and Docker data are preserved. Start it to reconnect to the terminal."
        case .error:
            "The machine state is preserved. Review the runtime error, then try starting it again."
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("WORKSPACE")
                    .font(SkepUI.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(SkepUI.muted(colorScheme))
                HStack(spacing: 10) {
                    Text(workspace.name)
                        .font(.system(size: 27, weight: .semibold))
                        .lineLimit(1)
                    StatusBadge(text: workspace.status.rawValue.capitalized)
                }
                Text("\(host.name)  /  \(workspace.runtimeName)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 24)
            Button("Host overview") { model.showSelectedHostManagement() }
                .buttonStyle(SecondaryButtonStyle(minWidth: 132))
        }
        .padding(.horizontal, 32)
        .frame(height: 94)
    }

    private func workspaceFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(SkepUI.eyebrow)
                .tracking(0.7)
                .foregroundStyle(SkepUI.muted(colorScheme))
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .lineLimit(2)
        }
        .padding(17)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(width: 1)
        }
    }
}

private struct EmptyHostView: View {
    @Environment(\.colorScheme) private var colorScheme
    let addHost: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("NO HOST SELECTED")
                .font(SkepUI.eyebrow)
                .tracking(1.2)
                .foregroundStyle(SkepUI.muted(colorScheme))
            Text("Choose a compute host.")
                .font(.system(size: 34, weight: .semibold))
            Text("Run microVM workspaces on this Mac, a Linux host over SSH, or a Google Cloud VM through IAP.")
                .font(.system(size: 14))
                .foregroundStyle(SkepUI.muted(colorScheme))
                .frame(maxWidth: 520, alignment: .leading)
            Button("Add host", action: addHost)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct HostDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let host: SSHHost

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.vertical, 22)

            if model.hostInfo != nil && model.hostConnectionIssue(for: host.id) == nil {
                HostSectionNavigation(model: model)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }

            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)

            if let info = model.hostInfo {
                hostPage(info: info)
            } else {
                setupPage
            }
        }
        .task(id: host.id) {
            if model.hostInfo == nil {
                await model.refresh(hostID: host.id)
            }
        }
    }

    private func hostPage(info: HostInfo) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !host.isLocal, let issue = model.hostConnectionIssue(for: host.id) {
                    HostConnectionRecoveryPanel(model: model, host: host, issue: issue)
                    CapabilityNotice(
                        label: "LAST KNOWN STATE",
                        title: "Host state is unavailable while disconnected",
                        message: "Skep last saw the host service and workspace data before this connection failed. The remote machines may still be running, but their current state cannot be confirmed until the connection is restored."
                    )
                } else {
                    if let error = model.errorMessage {
                        CapabilityNotice(
                            label: host.isLocal ? "LOCAL RUNTIME ERROR" : "SERVICE ERROR",
                            title: host.isLocal ? "This Mac could not be refreshed" : "The host could not be refreshed",
                            message: error
                        )
                    }

                    if !host.isLocal && !info.virtualization.kvmUsable {
                        CapabilityNotice(
                            label: "HOST REQUIREMENT",
                            title: "Nested virtualization is unavailable",
                            message: friendlyKVMMessage(info.virtualization.reason),
                            footnote: "Builders remain disabled until this host exposes /dev/kvm. On Google Cloud, choose a compatible machine family and enable nested virtualization."
                        )
                    }

                    if let operation = model.activeResourceOperation {
                        ResourceOperationNotice(
                            title: operation.title,
                            message: operationMessage(operation),
                            working: true
                        )
                    } else if let notice = model.operationNotice {
                        ResourceOperationNotice(
                            title: notice.title,
                            message: notice.message,
                            working: false,
                            error: notice.kind == .error
                        )
                    }

                    switch model.selectedSection {
                    case .overview:
                        HostOverviewPage(model: model, info: info, host: host)
                    case .builders:
                        BuildersManagementPage(
                            model: model,
                            info: info,
                            enabled: info.virtualization.kvmUsable && info.microsandbox.installed
                        )
                    case .templates:
                        TemplatesManagementPage(model: model)
                    case .workspaces:
                        WorkspacesManagementPage(model: model)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 52)
            .frame(maxWidth: 1260)
            .frame(maxWidth: .infinity)
        }
    }

    private var setupPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if !host.isLocal, let issue = model.hostConnectionIssue(for: host.id) {
                    HostConnectionRecoveryPanel(model: model, host: host, issue: issue)
                } else if let error = model.errorMessage {
                    CapabilityNotice(
                        label: host.isLocal ? "LOCAL RUNTIME ERROR" : (model.hostPreflight == nil ? "CONNECTION ERROR" : "SERVICE ERROR"),
                        title: host.isLocal ? "This Mac is not ready" : (model.hostPreflight == nil ? "Could not reach this host" : "The Skep host service could not respond"),
                        message: error
                    )
                }

                if host.isLocal, let status = model.localRuntimeStatus {
                    LocalRuntimePanel(model: model, status: status)
                } else if model.hostConnectionIssue(for: host.id) == nil,
                          let preflight = model.hostPreflight {
                    HostServicePanel(
                        model: model,
                        preflight: preflight,
                        updateRequired: model.hostServiceUpdateRequired
                    )
                    if !preflight.kvmDevice {
                        CapabilityNotice(
                            label: "HOST REQUIREMENT",
                            title: "Nested virtualization is unavailable",
                            message: preflightKVMMessage(preflight),
                            footnote: host.kind == .gcloudIAP
                                ? "Enable nested virtualization on this Compute Engine VM and restart it. Installing Skep cannot create /dev/kvm."
                                : "The VM provider must expose hardware virtualization to this guest. Installing Skep cannot create /dev/kvm."
                        )
                    }
                }

                if model.isBusy {
                    HostLoadingPanel(activity: model.activityLabel ?? "Checking host")
                } else if !host.isLocal && model.hostPreflight == nil && model.errorMessage == nil {
                    HStack {
                        Text("This host has not been inspected.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect and inspect") { model.refreshSelectedHost() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    .skepPanel()
                }
            }
            .padding(32)
            .frame(maxWidth: 1260)
            .frame(maxWidth: .infinity)
        }
    }

    private func operationMessage(_ operation: ResourceOperation) -> String {
        switch operation {
        case .creatingBuilder:
            "Pulling the OCI image and booting an editable microVM. The rest of the app remains available."
        case .preparingBuilder:
            "Installing Git, curl, Git LFS, Docker, and tmux inside this builder. Package downloads can take several minutes."
        case .publishingTemplate:
            "Stopping the builder, capturing a consistent snapshot, and verifying it. The builder remains available afterward."
        case .exportingTemplate:
            "Writing a portable snapshot archive with its OCI image."
        case .deletingTemplate:
            "Removing the snapshot. Existing workspaces are unaffected."
        case .creatingWorkspace:
            "Cloning the selected template into a new persistent microVM and attaching its own Docker disk."
        case .changingWorkspace:
            "Applying the requested machine state change."
        case .deletingWorkspace:
            "Removing the microVM and its dedicated Docker disk."
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(host.isLocal ? "LOCAL HOST" : "REMOTE HOST")
                    .font(SkepUI.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 11) {
                    Text(host.name)
                        .font(.system(size: 29, weight: .semibold))
                    if model.isBusy {
                        StatusBadge(text: model.activityLabel ?? "Working")
                    } else if let issue = model.hostConnectionIssue(for: host.id) {
                        StatusBadge(text: issue.badge)
                    } else if model.hostServiceUpdateRequired {
                        StatusBadge(text: "Update required")
                    } else if model.selectedHostIsReady {
                        StatusBadge(text: "Ready", filled: true)
                    } else if host.isLocal, let status = model.localRuntimeStatus {
                        StatusBadge(text: localRuntimeBadge(status.state))
                    } else if let preflight = model.hostPreflight {
                        StatusBadge(text: serviceBadge(preflight.serviceState))
                    }
                }
                Text(hostDescription)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button { model.refreshSelectedHost() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle(minWidth: 142))
            .disabled(model.isBusy)

            if !host.isLocal,
               model.hostConnectionIssue(for: host.id)?.requiresGoogleCloudAuthentication == true {
                Button {
                    model.reauthenticateGoogleCloud(hostID: host.id)
                } label: {
                    Label(
                        model.isReauthenticatingGoogleCloud(hostID: host.id)
                            ? "Opening browser…"
                            : "Reauthenticate",
                        systemImage: "person.badge.key"
                    )
                }
                .buttonStyle(PrimaryButtonStyle(minWidth: 158))
                .disabled(model.isReauthenticatingGoogleCloud(hostID: host.id))
            } else {
                Button { model.openHostTerminal() } label: {
                    Label(host.isLocal ? "Mac terminal" : "Host terminal", systemImage: "terminal")
                }
                .buttonStyle(PrimaryButtonStyle(minWidth: 142))
            }
        }
    }

    private var hostDescription: String {
        switch host.kind {
        case .local: "Local / Apple Silicon / \(NSUserName())"
        case .ssh: host.destination
        case .gcloudIAP: "\(host.gcloudProject) / \(host.gcloudZone) / \(host.gcloudInstance)"
        }
    }

    private func localRuntimeBadge(_ state: LocalRuntimeState) -> String {
        switch state {
        case .unsupported: "Unsupported"
        case .notInstalled: "Setup required"
        case .incomplete: "Incomplete"
        case .stopped: "Starting"
        case .ready: "Ready"
        }
    }

    private func friendlyKVMMessage(_ reason: String?) -> String {
        guard let reason, !reason.isEmpty else {
            return "This host cannot currently run Microsandbox microVMs."
        }
        if reason.localizedCaseInsensitiveContains("VMX/SVM") {
            return "The host is reachable, but its CPU does not expose hardware virtualization to the guest."
        }
        return reason
    }

    private func preflightKVMMessage(_ preflight: HostPreflight) -> String {
        if preflight.cpuVirtualization {
            return "The guest CPU exposes virtualization instructions, but Linux does not provide /dev/kvm."
        }
        return "The VM is reachable, but its guest CPU does not expose hardware virtualization instructions."
    }

    private func serviceBadge(_ state: HostServiceState) -> String {
        switch state {
        case .notInstalled: "Setup required"
        case .incomplete: "Incomplete"
        case .stopped: "Service stopped"
        case .ready: "Service ready"
        }
    }
}

private struct HostConnectionRecoveryPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let host: SSHHost
    let issue: HostConnectionIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                Rectangle()
                    .fill(SkepUI.ink(colorScheme))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.label)
                        .font(SkepUI.eyebrow)
                        .tracking(1)
                    Text(issue.title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(issue.hostMessage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SkepUI.muted(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                controls
            }

            DisclosureGroup("Technical details") {
                Text(issue.diagnostic)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        }
        .padding(18)
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("Retry connection") { model.refreshSelectedHost() }
                .buttonStyle(SecondaryButtonStyle(minWidth: 132))
                .disabled(model.isBusy || model.isReauthenticatingGoogleCloud(hostID: host.id))

            if issue.requiresGoogleCloudAuthentication {
                Button(model.isReauthenticatingGoogleCloud(hostID: host.id) ? "Opening browser…" : "Reauthenticate") {
                    model.reauthenticateGoogleCloud(hostID: host.id)
                }
                .buttonStyle(PrimaryButtonStyle(minWidth: 142))
                .disabled(model.isBusy || model.isReauthenticatingGoogleCloud(hostID: host.id))
            }
        }
    }
}

private extension HostConnectionIssue {
    var badge: String {
        switch kind {
        case .googleCloudAuthentication: "Reauth required"
        case .googleCloudCLIUnavailable: "gcloud missing"
        case .permissionDenied: "Access denied"
        case .networkUnavailable: "Network offline"
        case .hostUnavailable: "Disconnected"
        case .transportFailed: "Connection error"
        }
    }

    var label: String {
        switch kind {
        case .googleCloudAuthentication: "GOOGLE CLOUD AUTHENTICATION"
        case .googleCloudCLIUnavailable: "GOOGLE CLOUD CLI"
        case .permissionDenied: "ACCESS ERROR"
        case .networkUnavailable: "NETWORK ERROR"
        case .hostUnavailable, .transportFailed: "CONNECTION ERROR"
        }
    }

    var title: String {
        switch kind {
        case .googleCloudAuthentication: "Your Google Cloud session expired"
        case .googleCloudCLIUnavailable: "Google Cloud CLI is unavailable"
        case .permissionDenied: "This account cannot reach the host"
        case .networkUnavailable: "The network connection is unavailable"
        case .hostUnavailable: "The remote host disconnected"
        case .transportFailed: "Skep could not open the remote connection"
        }
    }

    var hostMessage: String {
        switch kind {
        case .googleCloudAuthentication:
            "The saved host configuration and Skep installation are unchanged, but Skep cannot inspect them until gcloud has fresh credentials. Reauthenticate in your browser, then Skep will retry the IAP tunnel automatically."
        case .googleCloudCLIUnavailable:
            "Install the Google Cloud CLI on this Mac, then retry the connection. Skep uses your existing gcloud installation and never stores its credentials."
        case .permissionDenied:
            "The connection reached Google Cloud or SSH, but the current account does not have permission to access this host. Verify the active account, IAP role, OS Login role, and project."
        case .networkUnavailable:
            "Skep could not reach the remote endpoint. Restore network access, then retry; no workspace state was changed."
        case .hostUnavailable:
            "The remote endpoint closed or refused the connection. Confirm the VM is running, then retry."
        case .transportFailed:
            "The SSH or IAP transport exited before Skep could inspect the host. Review the technical details, then retry the connection."
        }
    }

    var workspaceMessage: String {
        switch kind {
        case .googleCloudAuthentication:
            "The workspace may still be running, but its IAP tunnel closed because your Google Cloud session expired. Reauthenticate to open a new terminal."
        case .permissionDenied:
            "The workspace may still be running, but the current account no longer has access to its host."
        case .networkUnavailable:
            "The workspace may still be running. Restore network access, then retry the terminal connection."
        case .googleCloudCLIUnavailable:
            "The workspace may still be running, but this Mac cannot find the Google Cloud CLI required for its IAP tunnel."
        case .hostUnavailable, .transportFailed:
            "The workspace may still be running. Retry to open a new terminal shell when the host is reachable."
        }
    }
}

private struct HostLoadingPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let activity: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("HOST INSPECTION")
                    .font(SkepUI.eyebrow)
                    .tracking(1.0)
                    .foregroundStyle(SkepUI.muted(colorScheme))
                Spacer()
                Text(activity.uppercased())
                    .font(SkepUI.eyebrow)
                    .tracking(0.8)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            MonochromeLoadingBar()

            HStack(spacing: 9) {
                Rectangle()
                    .fill(SkepUI.ink(colorScheme))
                    .frame(width: 6, height: 6)
                Text("Keep this window open. The connection continues in the background.")
                    .font(SkepUI.metadata)
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }

    private var title: String {
        switch activity {
        case "Checking this Mac": "Inspecting this Mac"
        case "Updating local service": "Updating the local Skep service"
        case "Updating host service": "Updating the remote Skep service"
        case "Starting local service": "Starting the local Skep service"
        case "Loading this Mac": "Loading local workspace state"
        case "Loading host": "Loading host state"
        case "Installing Skep": "Installing the Skep host service"
        case "Removing Skep": "Removing the Skep host service"
        default: "Inspecting the remote host"
        }
    }

    private var message: String {
        switch activity {
        case "Checking this Mac":
            "Checking the Apple Silicon runtime, local Skep helpers, and private control socket."
        case "Updating local service":
            "Replacing the installed skepctl and skepd helpers with the versions bundled in this app while preserving all builders, templates, and workspaces."
        case "Updating host service":
            "Uploading the matching skepctl and skepd binaries, verifying their checksums, and restarting the host service without touching builders, templates, or workspaces."
        case "Starting local service":
            "Starting the user-owned Skep service and reconnecting to its private Unix socket."
        case "Loading this Mac":
            "The local service is responding. Loading resources, templates, and workspaces."
        case "Loading host":
            "The Skep daemon is responding. Loading host resources, templates, and workspaces."
        case "Installing Skep":
            "Uploading and verifying the Linux payload, installing Microsandbox, and starting skepd."
        case "Removing Skep":
            "Stopping skepd and removing the host control binaries while preserving host data."
        default:
            "Opening the SSH connection and checking the operating system, Skep service, and virtualization support."
        }
    }
}

private struct MonochromeLoadingBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let segmentWidth = max(72, geometry.size.width * 0.18)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(SkepUI.rule(colorScheme))
                Rectangle()
                    .fill(SkepUI.ink(colorScheme))
                    .frame(width: segmentWidth)
                    .offset(x: reduceMotion ? 0 : progress * max(0, geometry.size.width - segmentWidth))
            }
        }
        .frame(height: 3)
        .clipped()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                progress = 1
            }
        }
    }
}

private struct LocalRuntimePanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let status: LocalRuntimeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("LOCAL RUNTIME")
                        .font(SkepUI.eyebrow)
                        .tracking(1.0)
                        .foregroundStyle(SkepUI.muted(colorScheme))
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SkepUI.muted(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                controls
            }

            HStack(spacing: 0) {
                fact("ARCH", value: status.architecture.uppercased(), ready: status.supported)
                fact("SKEPCTL", value: status.skepctlInstalled ? "READY" : "MISSING", ready: status.skepctlInstalled)
                fact("SKEPD", value: status.skepdInstalled ? "READY" : "MISSING", ready: status.skepdInstalled)
                fact("SOCKET", value: status.daemonSocket ? "READY" : "MISSING", ready: status.daemonSocket)
                fact(
                    "MICROSANDBOX",
                    value: status.microsandboxInstalled
                        ? (status.configurationUsable ? "READY" : "PATH ERROR")
                        : "MISSING",
                    ready: status.microsandboxInstalled && status.configurationUsable
                )
            }
            .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))

            Text(footnote)
                .font(.system(size: 11))
                .foregroundStyle(SkepUI.muted(colorScheme))
        }
        .padding(18)
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            if status.state != .ready && status.state != .unsupported {
                Button(status.state == .notInstalled ? "Install local runtime" : "Repair local runtime") {
                    model.showingInstallHostServiceConfirmation = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy)
            }
            if status.skepctlInstalled || status.skepdInstalled || status.microsandboxInstalled {
                Button("Remove runtime") {
                    model.showingRemoveHostServiceConfirmation = true
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isBusy)
            }
        }
    }

    private func fact(_ name: String, value: String, ready: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(SkepUI.eyebrow)
                .tracking(0.7)
                .foregroundStyle(SkepUI.muted(colorScheme))
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .opacity(ready ? 1 : 0.58)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(width: 1)
        }
    }

    private var title: String {
        switch status.state {
        case .unsupported: "Local workspaces require Apple Silicon"
        case .notInstalled: "Install Skep to use this Mac"
        case .incomplete: "The local installation is incomplete"
        case .stopped: "The local service is stopped"
        case .ready: "This Mac is ready"
        }
    }

    private var message: String {
        switch status.state {
        case .unsupported:
            "This build uses the native Apple Silicon Microsandbox runtime and cannot enable local workspaces on this architecture."
        case .notInstalled:
            "Run isolated microVM workspaces directly on this Mac without SSH, a cloud account, or administrator access."
        case .incomplete:
            status.configurationIssue
                ?? "One or more local control components are missing. Repair reinstalls the app's helpers and the pinned runtime."
        case .stopped:
            "The components are installed, but the app has not connected to the local control socket. Refresh to restart it."
        case .ready:
            "Skep communicates with its user-owned service through a private local Unix socket. Nothing is exposed on the network."
        }
    }

    private var footnote: String {
        if let version = status.microsandboxVersion, !version.isEmpty {
            return "Native runtime: \(version). App data is under ~/Library/Application Support/Skep/Local; microVM data is under ~/.skep/msb."
        }
        return "Installation is user-owned and stored under ~/Library/Application Support/Skep/Local."
    }
}

private struct HostServicePanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let preflight: HostPreflight
    let updateRequired: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("HOST SERVICE")
                        .font(SkepUI.eyebrow)
                        .tracking(1.0)
                        .foregroundStyle(SkepUI.muted(colorScheme))
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SkepUI.muted(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 24)
                controls
            }

            HStack(spacing: 0) {
                serviceFact("SKEPCTL", ready: preflight.skepctlInstalled)
                serviceFact("SKEPD", ready: preflight.skepdInstalled)
                serviceFact("SERVICE", ready: preflight.daemonActive)
                serviceFact("SOCKET", ready: preflight.daemonSocket)
                serviceFact("MICROSANDBOX", ready: preflight.microsandboxInstalled)
            }
            .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))

            if let requirementMessage {
                Text(requirementMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
        }
        .padding(18)
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            if updateRequired {
                Button("Update Skep") {
                    model.showingInstallHostServiceConfirmation = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!preflight.supportsAutomaticUpdate || model.isBusy)
            } else if preflight.serviceState != .ready {
                Button(preflight.serviceState == .notInstalled ? "Install Skep" : "Repair Skep") {
                    model.showingInstallHostServiceConfirmation = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!preflight.supportsAutomaticInstall || model.isBusy)
            } else {
                Button("Reinstall Skep") {
                    model.showingInstallHostServiceConfirmation = true
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!preflight.supportsAutomaticInstall || model.isBusy)
            }
            if preflight.skepctlInstalled || preflight.skepdInstalled {
                Button("Uninstall, keep data") {
                    model.showingRemoveHostServiceConfirmation = true
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!preflight.passwordlessSudo || model.isBusy)
                Button("Erase all data…") {
                    model.showingPurgeHostConfirmation = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!preflight.passwordlessSudo || model.isBusy)
            }
        }
    }

    private func serviceFact(_ name: String, ready: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(SkepUI.eyebrow)
                .tracking(0.7)
                .foregroundStyle(SkepUI.muted(colorScheme))
            Text(ready ? "READY" : "MISSING")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(width: 1)
        }
    }

    private var title: String {
        if updateRequired { return "Update the Skep host service" }
        return switch preflight.serviceState {
        case .notInstalled: "Install Skep to manage this host"
        case .incomplete: "The Skep installation is incomplete"
        case .stopped: "The Skep service is not running"
        case .ready: "Skep is installed and running"
        }
    }

    private var message: String {
        if updateRequired {
            return "This Mac app carries newer skepctl and skepd binaries. Update the host before managing its builders, templates, or workspaces. Host data is preserved."
        }
        return switch preflight.serviceState {
        case .notInstalled:
            "SSH is working, but this fresh VM does not have skepctl or skepd. Install the host service before creating builders or workspaces."
        case .incomplete:
            "Only part of the Skep host service is present. Repairing it reinstalls the version bundled with this app and restarts the daemon."
        case .stopped:
            "The Skep binaries are present, but skepd is inactive or its /run/skep/skepd.sock control socket is missing."
        case .ready:
            "The app reaches skepd through skepctl and the host-local /run/skep/skepd.sock control socket."
        }
    }

    private var requirementMessage: String? {
        guard preflight.serviceState != .ready || updateRequired else { return nil }
        if updateRequired && !preflight.supportsAutomaticUpdate {
            return "Automatic updates require x86-64, systemd, and non-interactive sudo for this SSH user. Open the host terminal to restore administrator access."
        }
        if preflight.operatingSystem != "ubuntu" || preflight.operatingSystemVersion != "24.04" {
            return "Automatic installation currently requires Ubuntu 24.04. This host reports \(preflight.operatingSystem) \(preflight.operatingSystemVersion)."
        }
        if preflight.architecture != "x86_64" {
            return "Automatic installation currently requires x86-64. This host reports \(preflight.architecture)."
        }
        if !preflight.systemd {
            return "Automatic installation requires systemd."
        }
        if !preflight.passwordlessSudo {
            return "Automatic installation requires non-interactive sudo for this SSH user. Open the host terminal to configure administrator access."
        }
        return "Installs skepctl, skepd, a systemd service, narrow sudo rules, and the checksum-pinned Microsandbox runtime."
    }
}

private struct CapabilityNotice: View {
    @Environment(\.colorScheme) private var colorScheme
    let label: String
    let title: String
    let message: String
    var footnote: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Rectangle()
                .fill(SkepUI.ink(colorScheme))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(label)
                    .font(SkepUI.eyebrow)
                    .tracking(1.0)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                if let footnote {
                    Text(footnote)
                        .font(.system(size: 11))
                        .foregroundStyle(SkepUI.muted(colorScheme))
                        .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }
}

private struct HostOverview: View {
    @Environment(\.colorScheme) private var colorScheme
    let info: HostInfo
    let local: Bool

    var body: some View {
        HStack(spacing: 0) {
            MetricCell(title: "PROCESSOR", value: "\(info.cpuCount) cores", detail: info.architecture)
            rule
            MetricCell(title: "FREE MEMORY", value: formatGiB(info.availableMemoryMib), detail: "\(formatGiB(info.totalMemoryMib)) total")
            rule
            MetricCell(title: "FREE STORAGE", value: formatGiB(info.rootDiskAvailableMib), detail: "\(formatGiB(info.rootDiskTotalMib)) total")
            rule
            MetricCell(
                title: "MICROVM",
                value: runtimeVersion,
                detail: local ? "Native virtualization" : (info.virtualization.kvmUsable ? "KVM ready" : "KVM unavailable")
            )
        }
        .frame(minHeight: 112)
        .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
    }

    private var rule: some View {
        Rectangle().fill(SkepUI.rule(colorScheme)).frame(width: 1)
    }

    private var runtimeVersion: String {
        guard info.microsandbox.installed else { return "Not installed" }
        return (info.microsandbox.version ?? "Installed").replacingOccurrences(of: "msb ", with: "v")
    }
}

private struct MetricCell: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(SkepUI.eyebrow)
                .tracking(0.8)
                .foregroundStyle(SkepUI.muted(colorScheme))
            Text(value)
                .font(.system(size: 20, weight: .semibold))
            Text(detail)
                .font(SkepUI.metadata)
                .foregroundStyle(SkepUI.muted(colorScheme))
                .lineLimit(1)
        }
        .padding(17)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct HostSectionNavigation: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            section(.overview, count: nil)
            section(.builders, count: model.builders.count)
            section(.templates, count: model.templates.count)
            section(.workspaces, count: model.managedWorkspaces.count)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
        }
    }

    private func section(_ section: HostSection, count: Int?) -> some View {
        let selected = model.selectedSection == section
        return Button { model.selectSection(section) } label: {
            HStack(spacing: 7) {
                Text(section.title.uppercased())
                if let count {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .opacity(0.65)
                }
            }
            .font(SkepUI.eyebrow)
            .tracking(0.7)
            .foregroundStyle(selected ? SkepUI.inverseInk(colorScheme) : SkepUI.ink(colorScheme))
            .frame(width: 132)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .background(selected ? SkepUI.ink(colorScheme) : .clear)
            .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct ResourceOperationNotice: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let message: String
    let working: Bool
    var error = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Text(error ? "!" : "✓")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(SkepUI.inverseInk(colorScheme))
                        .background(SkepUI.ink(colorScheme))
                }
                Text(title.uppercased())
                    .font(SkepUI.eyebrow)
                    .tracking(0.8)
                Spacer()
                Text(working ? "IN PROGRESS" : (error ? "FAILED" : "COMPLETE"))
                    .font(SkepUI.eyebrow)
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(SkepUI.muted(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if working { MonochromeLoadingBar() }
        }
        .padding(15)
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }
}

private struct HostOverviewPage: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let info: HostInfo
    let host: SSHHost

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HostOverview(info: info, local: host.isLocal)
            if model.managedWorkspaces.isEmpty {
                firstWorkspaceGuide
            } else {
                resourceSummary
                activeWorkspaces
            }
            if !host.isLocal {
                HostDangerZone(model: model, host: host)
            }
        }
    }

    private var firstWorkspaceGuide: some View {
        VStack(alignment: .leading, spacing: 0) {
            ManagementHeader(
                eyebrow: "GET STARTED",
                title: "Create your first workspace",
                subtitle: "Build one editable machine, capture it as a template, then launch as many isolated workspaces as you need."
            )
            .padding(20)
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            onboardingStep(
                number: 1,
                title: "Create and customize a builder",
                detail: "A persistent editable microVM. Install anything you want through its terminal.",
                complete: !model.builders.isEmpty,
                enabled: true,
                actionTitle: model.builders.isEmpty ? "Create builder" : "Manage builders"
            ) {
                model.builders.isEmpty ? model.beginNewBuilder() : model.selectSection(.builders)
            }
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            onboardingStep(
                number: 2,
                title: "Publish a reusable template",
                detail: "A verified, immutable snapshot of a builder. Publishing stops the builder but does not delete it.",
                complete: !model.templates.isEmpty,
                enabled: !model.builders.isEmpty,
                actionTitle: model.templates.isEmpty ? "Create template" : "Manage templates"
            ) {
                model.templates.isEmpty ? model.beginTemplate() : model.selectSection(.templates)
            }
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            onboardingStep(
                number: 3,
                title: "Launch an isolated workspace",
                detail: "A persistent microVM cloned from a template, with its own dedicated Docker data disk.",
                complete: false,
                enabled: !model.templates.isEmpty,
                actionTitle: "Create workspace"
            ) { model.beginWorkspace() }
        }
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }

    private func onboardingStep(
        number: Int,
        title: String,
        detail: String,
        complete: Bool,
        enabled: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            Text(complete ? "✓" : String(format: "%02d", number))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 30, height: 30)
                .foregroundStyle((complete || enabled) ? SkepUI.inverseInk(colorScheme) : SkepUI.muted(colorScheme))
                .background((complete || enabled) ? SkepUI.ink(colorScheme) : .clear)
                .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
            Spacer(minLength: 20)
            Button(actionTitle, action: action)
                .buttonStyle(PrimaryButtonStyle(minWidth: 154))
                .disabled(!enabled)
        }
        .padding(18)
        .opacity(enabled || complete ? 1 : 0.5)
    }

    private var resourceSummary: some View {
        HStack(spacing: 0) {
            summaryCell("BUILDERS", value: model.builders.count, action: { model.selectSection(.builders) })
            summaryCell("TEMPLATES", value: model.templates.count, action: { model.selectSection(.templates) })
            summaryCell("WORKSPACES", value: model.managedWorkspaces.count, action: { model.selectSection(.workspaces) })
        }
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }

    private func summaryCell(_ title: String, value: Int, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(SkepUI.eyebrow).tracking(0.8).foregroundStyle(SkepUI.muted(colorScheme))
            Text("\(value)").font(.system(size: 28, weight: .semibold, design: .monospaced))
            Button("Manage", action: action).buttonStyle(SecondaryButtonStyle())
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { Rectangle().fill(SkepUI.rule(colorScheme)).frame(width: 1) }
    }

    private var activeWorkspaces: some View {
        VStack(alignment: .leading, spacing: 0) {
            ManagementHeader(
                eyebrow: "CURRENT MACHINES",
                title: "Workspaces",
                subtitle: "Your persistent, isolated development machines."
            )
            .padding(18)
            ForEach(model.managedWorkspaces.prefix(3)) { workspace in
                Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
                HStack {
                    MachineStatus(status: workspace.status)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.name).font(.system(size: 13, weight: .semibold))
                        Text(profileSummary(workspace.resources)).font(SkepUI.metadata).foregroundStyle(SkepUI.muted(colorScheme))
                    }
                    Spacer()
                    Button("Open terminal") { model.openTerminal(for: workspace) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(workspace.status != .running)
                }
                .padding(16)
            }
        }
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }
}

private struct HostDangerZone: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let host: SSHHost

    private var canModifyInstallation: Bool {
        model.hostPreflight?.passwordlessSudo == true && !model.isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DANGER ZONE")
                        .font(SkepUI.eyebrow)
                        .tracking(0.9)
                    Text("Remove Skep from this VM")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Uninstall only the service and preserve its state, or permanently erase every Skep-owned machine, snapshot, volume, export, runtime, and control file. The VM itself is never deleted here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SkepUI.muted(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 20)
                HStack(spacing: 10) {
                    Button("Uninstall, keep data") {
                        model.showingRemoveHostServiceConfirmation = true
                    }
                    .buttonStyle(SecondaryButtonStyle(minWidth: 154))
                    .disabled(!canModifyInstallation)

                    Button("Erase all data…") {
                        model.showingPurgeHostConfirmation = true
                    }
                    .buttonStyle(PrimaryButtonStyle(minWidth: 142))
                    .disabled(!canModifyInstallation)
                }
            }
            .padding(18)

            if model.hostPreflight?.passwordlessSudo != true {
                Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
                Text("These actions require a working connection and non-interactive sudo on \(host.name).")
                    .font(.system(size: 11))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .padding(18)
            }
        }
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }
}

private struct BuildersManagementPage: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let info: HostInfo
    let enabled: Bool
    @State private var showingResources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ManagementHeader(
                eyebrow: "EDITABLE MACHINES",
                title: "Builders",
                subtitle: "Persistent base-image microVMs. Each builder is independent; customize it in Terminal, then capture it as a template."
            ) {
                if !model.builders.isEmpty {
                    Button(model.showingBuilderCreator ? "Close form" : "New builder") {
                        model.showingBuilderCreator ? (model.showingBuilderCreator = false) : model.beginNewBuilder()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            if model.builders.isEmpty || model.showingBuilderCreator {
                builderForm
            }

            if model.builders.isEmpty {
                ManagementEmptyState(title: "NO BUILDERS", message: "Create an editable microVM to begin.")
            } else {
                ForEach(model.builders) { builder in
                    BuilderManagementCard(model: model, builder: builder)
                }
            }
        }
        .sheet(isPresented: $showingResources) {
            ResourceEditorSheet(profile: $model.draftProfile, info: info) { showingResources = false }
        }
    }

    private var builderForm: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ModernTextField("Builder name", help: "Unique on this host.", prompt: "e.g. agent-base", text: $model.builderName)
                ModernTextField("Starting image", help: "A clean OCI operating-system image.", prompt: "e.g. ubuntu:24.04", text: $model.builderImage)
            }
            .padding(18)
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RESOURCE PROFILE").font(SkepUI.eyebrow).tracking(0.8)
                    Text(profileSummary(model.draftProfile)).font(.system(size: 11.5)).foregroundStyle(SkepUI.muted(colorScheme))
                }
                Spacer()
                Button("Edit resources") { showingResources = true }.buttonStyle(SecondaryButtonStyle())
                Button(operationLabel(default: "Create builder", active: .creatingBuilder)) { model.createBuilder() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!enabled || model.resourceOperationInProgress || trimmed(model.builderName).isEmpty || trimmed(model.builderImage).isEmpty)
            }
            .padding(18)
            if !enabled {
                Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
                Text("This host must have Microsandbox and working hardware virtualization before it can create a builder.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .padding(18)
            }
        }
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }

    private func operationLabel(default title: String, active: ResourceOperation) -> String {
        model.activeResourceOperation == active ? "Creating…" : title
    }
}

private struct BuilderManagementCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let builder: Workspace

    private var targeted: Bool { model.activeResourceOperation?.targets(builder.id) == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                MachineStatus(status: builder.status)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Text(builder.name).font(.system(size: 17, weight: .semibold))
                        Text(builder.status.rawValue.uppercased()).font(SkepUI.eyebrow).foregroundStyle(SkepUI.muted(colorScheme))
                    }
                    Text(builder.image ?? "OCI image unavailable")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SkepUI.muted(colorScheme))
                    Text(profileSummary(builder.resources))
                        .font(SkepUI.metadata)
                        .foregroundStyle(SkepUI.muted(colorScheme))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("BASELINE TOOLS").font(SkepUI.eyebrow).foregroundStyle(SkepUI.muted(colorScheme))
                    Text(builder.toolsInstalled == true ? "INSTALLED" : "OPTIONAL")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                }
            }
            .padding(18)
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            HStack(spacing: 10) {
                Text(builder.toolsInstalled == true
                    ? "Git, curl, Git LFS, Docker, and tmux are installed. You can add anything else manually."
                    : "Optional shortcut: install Git, curl, Git LFS, Docker, and tmux. You can also customize entirely in Terminal.")
                    .font(.system(size: 11))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                Spacer(minLength: 16)
                Button("Terminal") { model.openTerminal(for: builder) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(builder.status != .running)
                Button(builder.status == .running ? "Stop" : "Start") {
                    model.setRunning(builder, running: builder.status != .running)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.resourceOperationInProgress)
                if builder.toolsInstalled != true {
                    Button(targeted && model.activeResourceOperation == .preparingBuilder(builder.id) ? "Installing…" : "Install Docker & tools") {
                        model.bootstrap(builder)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.resourceOperationInProgress)
                }
                Button(targeted && model.activeResourceOperation == .publishingTemplate(builder.id) ? "Publishing…" : "Create template") {
                    model.beginTemplate(from: builder)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.resourceOperationInProgress)
                Button("Delete") { model.pendingDeletion = builder }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.resourceOperationInProgress)
            }
            .padding(15)
        }
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }
}

private struct TemplatesManagementPage: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ManagementHeader(
                eyebrow: "REUSABLE SNAPSHOTS",
                title: "Templates",
                subtitle: "Verified, immutable snapshots. Templates do not run and consume no CPU or memory until you launch a workspace."
            ) {
                if !model.templates.isEmpty && !model.builders.isEmpty {
                    Button(model.showingTemplateCreator ? "Close form" : "New template") {
                        model.showingTemplateCreator ? (model.showingTemplateCreator = false) : model.beginTemplate()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            if !model.builders.isEmpty && (model.templates.isEmpty || model.showingTemplateCreator) {
                templateForm
            }

            if model.templates.isEmpty {
                ManagementEmptyState(
                    title: "NO TEMPLATES",
                    message: model.builders.isEmpty ? "Create a builder first." : "Choose a builder and publish its first verified snapshot."
                )
            } else {
                ForEach(model.templates) { template in
                    TemplateManagementCard(model: model, template: template)
                }
            }

            if let path = model.lastExportPath {
                Text("LAST EXPORT  \(path)")
                    .font(SkepUI.metadata)
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
            }
        }
    }

    private var templateForm: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                FlatSelectionMenu(
                    title: "SOURCE BUILDER",
                    placeholder: "Choose a builder",
                    selection: $model.selectedBuilderID,
                    options: model.builders.map { FlatSelectionOption(id: $0.id, label: $0.name) }
                )
                .frame(width: 240)
                ModernTextField("Template name", help: "Unique reusable snapshot name.", prompt: "e.g. development", text: $model.templateName)
            }
            .padding(18)
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            HStack(spacing: 14) {
                Text("Publishing stops the selected builder for a consistent snapshot. The builder remains available and can be started again afterward.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                Spacer()
                Button(model.activeResourceOperation.map { if case .publishingTemplate = $0 { return true }; return false } == true ? "Publishing…" : "Publish template") {
                    model.publishTemplate()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.selectedBuilderID == nil || trimmed(model.templateName).isEmpty || model.resourceOperationInProgress)
            }
            .padding(18)
        }
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }
}

private struct TemplateManagementCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let template: Template

    private var sourceName: String {
        model.builders.first(where: { $0.id == template.sourceWorkspaceId })?.name ?? "deleted builder"
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(template.verified ? "✓" : "!")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(width: 30, height: 30)
                .foregroundStyle(SkepUI.inverseInk(colorScheme))
                .background(SkepUI.ink(colorScheme))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text(template.name).font(.system(size: 16, weight: .semibold))
                    Text(template.verified ? "VERIFIED" : "UNVERIFIED").font(SkepUI.eyebrow).foregroundStyle(SkepUI.muted(colorScheme))
                }
                Text("From \(sourceName)  /  \(profileSummary(template.resources))")
                    .font(SkepUI.metadata)
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
            Spacer(minLength: 18)
            Button("Launch workspace") { model.beginWorkspace(from: template) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!template.verified || model.resourceOperationInProgress)
            Button(model.activeResourceOperation == .exportingTemplate(template.id) ? "Exporting…" : "Export") {
                model.exportTemplate(template)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.resourceOperationInProgress)
            Button("Delete") { model.pendingTemplateDeletion = template }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.resourceOperationInProgress)
        }
        .padding(18)
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }
}

private struct WorkspacesManagementPage: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ManagementHeader(
                eyebrow: "ISOLATED MACHINES",
                title: "Workspaces",
                subtitle: "Persistent microVMs cloned from templates. Every workspace has its own filesystem, state, and dedicated Docker data disk."
            ) {
                if !model.managedWorkspaces.isEmpty && !model.templates.isEmpty {
                    Button(model.showingWorkspaceCreator ? "Close form" : "New workspace") {
                        model.showingWorkspaceCreator ? (model.showingWorkspaceCreator = false) : model.beginWorkspace()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            if !model.templates.isEmpty && (model.managedWorkspaces.isEmpty || model.showingWorkspaceCreator) {
                workspaceForm
            }

            if model.managedWorkspaces.isEmpty {
                ManagementEmptyState(
                    title: "NO WORKSPACES",
                    message: model.templates.isEmpty ? "Publish a template first." : "Choose a template and launch an isolated machine."
                )
            } else {
                ForEach(model.managedWorkspaces) { workspace in
                    WorkspaceManagementCard(model: model, workspace: workspace)
                }
            }
        }
    }

    private var workspaceForm: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                FlatSelectionMenu(
                    title: "TEMPLATE",
                    placeholder: "Choose a template",
                    selection: $model.selectedTemplateID,
                    options: model.templates.map { FlatSelectionOption(id: $0.id, label: $0.name) }
                )
                .frame(width: 240)
                ModernTextField("Workspace name", help: "Unique on this host.", prompt: "e.g. feature-auth", text: $model.workspaceName)
            }
            .padding(18)
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            HStack {
                Toggle("Start after host restart", isOn: $model.workspaceAutostart)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Button(model.activeResourceOperation == .creatingWorkspace ? "Creating…" : "Create workspace") { model.createWorkspace() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.selectedTemplateID == nil || trimmed(model.workspaceName).isEmpty || model.resourceOperationInProgress)
            }
            .padding(18)
        }
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }
}

private struct WorkspaceManagementCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let workspace: Workspace

    private var templateName: String {
        model.templates.first(where: { $0.id == workspace.templateId })?.name ?? "deleted template"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                MachineStatus(status: workspace.status)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Text(workspace.name).font(.system(size: 17, weight: .semibold))
                        Text(workspace.status.rawValue.uppercased()).font(SkepUI.eyebrow).foregroundStyle(SkepUI.muted(colorScheme))
                    }
                    Text("Template: \(templateName)  /  \(profileSummary(workspace.resources))")
                        .font(SkepUI.metadata)
                        .foregroundStyle(SkepUI.muted(colorScheme))
                    Text("Independent Docker disk: \(formatGiB(UInt64(workspace.resources.dockerVolumeMib)))")
                        .font(SkepUI.metadata)
                        .foregroundStyle(SkepUI.muted(colorScheme))
                }
                Spacer()
                Text(workspace.autostart ? "AUTOSTART ON" : "AUTOSTART OFF")
                    .font(SkepUI.eyebrow)
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
            .padding(18)
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
            HStack(spacing: 10) {
                Text("Persistent until you delete it. Closing Skep does not destroy this machine.")
                    .font(.system(size: 11))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                Spacer()
                Button(workspace.autostart ? "Disable autostart" : "Enable autostart") { model.toggleAutostart(workspace) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.resourceOperationInProgress)
                Button("Terminal") { model.openTerminal(for: workspace) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(workspace.status != .running)
                Button(workspace.status == .running ? "Stop" : "Start") {
                    model.setRunning(workspace, running: workspace.status != .running)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.resourceOperationInProgress)
                Button("Delete") { model.pendingDeletion = workspace }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.resourceOperationInProgress)
            }
            .padding(15)
        }
        .background(SkepUI.faint(colorScheme))
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }
}

private struct ManagementHeader<Actions: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let eyebrow: String
    let title: String
    let subtitle: String
    @ViewBuilder let actions: () -> Actions

    init(
        eyebrow: String,
        title: String,
        subtitle: String,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow).font(SkepUI.eyebrow).tracking(1).foregroundStyle(SkepUI.muted(colorScheme))
                Text(title).font(.system(size: 23, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            actions()
        }
    }
}

private extension ManagementHeader where Actions == EmptyView {
    init(eyebrow: String, title: String, subtitle: String) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

private struct ManagementEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 16) {
            Text(title).font(SkepUI.eyebrow).tracking(0.8)
            Text(message).font(.system(size: 12)).foregroundStyle(SkepUI.muted(colorScheme))
            Spacer()
        }
        .padding(20)
        .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
    }
}

private struct MachineStatus: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: WorkspaceStatus

    var body: some View {
        Rectangle()
            .fill(status == .running ? SkepUI.ink(colorScheme) : .clear)
            .frame(width: 12, height: 12)
            .overlay(Rectangle().stroke(SkepUI.ink(colorScheme), lineWidth: 1))
            .padding(.top, 4)
            .accessibilityLabel(status.rawValue)
    }
}

private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct WorkflowLine: View {
    @Environment(\.colorScheme) private var colorScheme
    let hasBuilder: Bool
    let hasTemplate: Bool
    let hasWorkspace: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("WORKFLOW")
                .font(SkepUI.eyebrow)
                .tracking(1.1)
                .foregroundStyle(SkepUI.muted(colorScheme))
            HStack(spacing: 0) {
                WorkflowStep(number: 1, title: "Build image", complete: hasBuilder, active: !hasBuilder)
                connector(done: hasBuilder)
                WorkflowStep(number: 2, title: "Save template", complete: hasTemplate, active: hasBuilder && !hasTemplate)
                connector(done: hasTemplate)
                WorkflowStep(number: 3, title: "Launch workspace", complete: hasWorkspace, active: hasTemplate && !hasWorkspace)
            }
        }
        .padding(.vertical, 3)
    }

    private func connector(done: Bool) -> some View {
        Rectangle()
            .fill(done ? SkepUI.ink(colorScheme) : SkepUI.rule(colorScheme))
            .frame(maxWidth: 58, minHeight: 1, maxHeight: 1)
            .padding(.horizontal, 10)
    }
}

private struct WorkflowStep: View {
    @Environment(\.colorScheme) private var colorScheme
    let number: Int
    let title: String
    let complete: Bool
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(complete ? "✓" : String(format: "%02d", number))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 22)
                .foregroundStyle(active || complete ? SkepUI.inverseInk(colorScheme) : SkepUI.muted(colorScheme))
                .background(active || complete ? SkepUI.ink(colorScheme) : .clear)
                .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active || complete ? SkepUI.ink(colorScheme) : SkepUI.muted(colorScheme))
        }
        .fixedSize()
    }
}

private struct BuilderSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let info: HostInfo
    let enabled: Bool
    @State private var showingResources = false

    var body: some View {
        VStack(spacing: 0) {
            StageHeader(
                number: 1,
                title: "Build your base image",
                subtitle: "Boot an editable microVM, install your tools, then publish it as a reusable template.",
                status: model.builders.isEmpty ? nil : "Builder ready"
            )
            .padding(20)

            sectionRule

            HStack(alignment: .top, spacing: 16) {
                ModernTextField(
                    "Builder name",
                    help: "A local name for this editable environment.",
                    prompt: "e.g. agent-base",
                    text: $model.builderName
                )
                ModernTextField(
                    "Starting image",
                    help: "The clean OCI operating-system image.",
                    prompt: "e.g. ubuntu:24.04",
                    text: $model.builderImage
                )
            }
            .padding(20)

            sectionRule

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RESOURCE PROFILE")
                            .font(SkepUI.eyebrow)
                            .tracking(0.9)
                        Text(profileSummary(model.draftProfile))
                            .font(.system(size: 12))
                            .foregroundStyle(SkepUI.muted(colorScheme))
                    }
                    Spacer()
                    Button("Edit resources") { showingResources = true }
                        .buttonStyle(SecondaryButtonStyle())
                }

                HStack(spacing: 0) {
                    ProfileValue(title: "CPU", value: cpuSummary(model.draftProfile))
                    ProfileValue(title: "MEMORY", value: memorySummary(model.draftProfile))
                    ProfileValue(title: "STORAGE", value: storageSummary(model.draftProfile))
                    ProfileValue(title: "NETWORK", value: networkLabel(model.draftProfile.networkProfile))
                }
                .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
            }
            .padding(20)

            sectionRule

            HStack {
                Text(enabled ? "Creates an editable microVM on this host." : "Requires a host with working KVM.")
                    .font(.system(size: 11))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                Spacer()
                Button("Create builder") { model.createBuilder() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!enabled || model.isBusy || model.builderName.isEmpty || model.builderImage.isEmpty)
            }
            .padding(20)

            ForEach(model.builders) { builder in
                sectionRule
                BuilderRow(model: model, builder: builder)
            }
        }
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
        .sheet(isPresented: $showingResources) {
            ResourceEditorSheet(profile: $model.draftProfile, info: info) {
                showingResources = false
            }
        }
    }

    private var sectionRule: some View {
        Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
    }
}

private struct ProfileValue: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(SkepUI.eyebrow)
                .tracking(0.7)
                .foregroundStyle(SkepUI.muted(colorScheme))
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(width: 1)
        }
    }
}

private struct ResourceEditorSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var profile: ResourceProfile
    let info: HostInfo
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("RESOURCE PROFILE")
                        .font(SkepUI.eyebrow)
                        .tracking(1.1)
                        .foregroundStyle(SkepUI.muted(colorScheme))
                    Text("Workspace resources")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Set the starting allocation and upper bounds used by Microsandbox.")
                        .font(.system(size: 12))
                        .foregroundStyle(SkepUI.muted(colorScheme))
                }
                Spacer()
                Button("Reset to recommendation") {
                    profile = info.suggestedProfile
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(24)

            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)

            ScrollView {
                ResourceProfileEditor(profile: $profile, info: info)
                    .padding(24)
            }

            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)

            HStack {
                Text(profileSummary(profile))
                    .font(SkepUI.metadata)
                    .foregroundStyle(SkepUI.muted(colorScheme))
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(20)
        }
        .frame(width: 780, height: 700)
        .background(SkepUI.canvas(colorScheme))
    }
}

private struct ResourceProfileEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var profile: ResourceProfile
    let info: HostInfo

    private var hostCPU: Int { max(1, Int(info.cpuCount)) }
    private var hostMemory: Int { max(512, Int(info.totalMemoryMib) - 512) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            resourceGroup("CPU AND MEMORY") {
                LazyVGrid(columns: twoColumns, spacing: 8) {
                    ResourceControl(
                        title: "Starting CPU",
                        explanation: "Cores available when the microVM boots.",
                        value: cpuBinding(\.startingCpus),
                        range: 1...max(1, min(hostCPU, Int(profile.maximumCpus))),
                        step: 1,
                        display: { "\($0) \($0 == 1 ? "core" : "cores")" }
                    )
                    ResourceControl(
                        title: "Maximum CPU",
                        explanation: "The ceiling available without recreating the VM.",
                        value: cpuBinding(\.maximumCpus),
                        range: max(1, Int(profile.startingCpus))...hostCPU,
                        step: 1,
                        display: { "\($0) \($0 == 1 ? "core" : "cores")" }
                    )
                    ResourceControl(
                        title: "Starting memory",
                        explanation: "RAM reserved when the workspace starts.",
                        value: memoryBinding(\.startingMemoryMib),
                        range: 512...max(512, min(hostMemory, Int(profile.maximumMemoryMib))),
                        step: 256,
                        display: { formatGiB(UInt64($0)) }
                    )
                    ResourceControl(
                        title: "Maximum memory",
                        explanation: "Upper RAM limit with host memory kept in reserve.",
                        value: memoryBinding(\.maximumMemoryMib),
                        range: max(512, Int(profile.startingMemoryMib))...hostMemory,
                        step: 256,
                        display: { formatGiB(UInt64($0)) }
                    )
                }
            }

            resourceGroup("STORAGE") {
                LazyVGrid(columns: twoColumns, spacing: 8) {
                    ResourceControl(
                        title: "Workspace disk",
                        explanation: "Ubuntu, installed tools, and checked-out code.",
                        value: memoryBinding(\.rootDiskMib),
                        range: 4_096...262_144,
                        step: 1_024,
                        display: { formatGiB(UInt64($0)) }
                    )
                    ResourceControl(
                        title: "Fast temporary space",
                        explanation: "RAM-backed /tmp for package managers and agents.",
                        value: memoryBinding(\.tmpfsMib),
                        range: 256...16_384,
                        step: 256,
                        display: { formatGiB(UInt64($0)) }
                    )
                    ResourceControl(
                        title: "Docker data disk",
                        explanation: "Dedicated persistent disk for layers and containers.",
                        value: memoryBinding(\.dockerVolumeMib),
                        range: 4_096...524_288,
                        step: 1_024,
                        display: { formatGiB(UInt64($0)) }
                    )
                }
            }

            resourceGroup("NETWORK ACCESS") {
                HStack(spacing: 0) {
                    networkOption("all", title: "Full access")
                    networkOption("public", title: "Internet only")
                    networkOption("none", title: "Offline")
                }
                .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
                Text(networkExplanation(profile.networkProfile))
                    .font(.system(size: 11))
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
        }
    }

    private func resourceGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(SkepUI.eyebrow)
                .tracking(1.0)
                .foregroundStyle(SkepUI.muted(colorScheme))
            content()
        }
    }

    private func networkOption(_ value: String, title: String) -> some View {
        let selected = profile.networkProfile == value
        return Button { profile.networkProfile = value } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? SkepUI.inverseInk(colorScheme) : SkepUI.ink(colorScheme))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
                .background(selected ? SkepUI.ink(colorScheme) : .clear)
        }
            .buttonStyle(.plain)
    }

    private var twoColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    private func cpuBinding(_ keyPath: WritableKeyPath<ResourceProfile, UInt8>) -> Binding<Int> {
        Binding(
            get: { Int(profile[keyPath: keyPath]) },
            set: { profile[keyPath: keyPath] = UInt8(clamping: $0) }
        )
    }

    private func memoryBinding(_ keyPath: WritableKeyPath<ResourceProfile, UInt32>) -> Binding<Int> {
        Binding(
            get: { Int(profile[keyPath: keyPath]) },
            set: { profile[keyPath: keyPath] = UInt32(clamping: $0) }
        )
    }
}

private struct ResourceControl: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let explanation: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let display: (Int) -> String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 7) {
                Text(display(value))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
    }
}

private struct BuilderRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let builder: Workspace

    var body: some View {
        HStack(spacing: 14) {
            Text("BUILDER")
                .font(SkepUI.eyebrow)
                .tracking(0.7)
                .frame(width: 62, alignment: .leading)
                .foregroundStyle(SkepUI.muted(colorScheme))
            VStack(alignment: .leading, spacing: 3) {
                Text(builder.name).font(.system(size: 13, weight: .semibold))
                Text(builder.status.rawValue.uppercased())
                    .font(SkepUI.metadata)
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
            Spacer()
            Button("Open terminal") { model.openTerminal(for: builder) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(builder.status != .running)
        }
        .padding(16)
    }
}

private struct TemplateSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StageHeader(
                number: 2,
                title: "Save a reusable template",
                subtitle: "Customize a builder in Terminal, install the baseline tools, then publish a verified snapshot.",
                status: model.templates.isEmpty ? nil : "Template ready"
            )
            .padding(20)
            sectionRule

            HStack(alignment: .bottom, spacing: 14) {
                FlatPickerLabel(title: "SOURCE BUILDER") {
                    Picker("Source builder", selection: $model.selectedBuilderID) {
                        Text("Choose a builder").tag(String?.none)
                        ForEach(model.builders) { builder in
                            Text(builder.name).tag(Optional(builder.id))
                        }
                    }
                }
                .frame(width: 220)

                ModernTextField(
                    "Template name",
                    help: "Used when creating future workspaces.",
                    prompt: "e.g. development",
                    text: $model.templateName
                )

                Button("Install tools") { model.bootstrapSelectedBuilder() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.selectedBuilderID == nil || model.isBusy)
                Button("Publish template") { model.publishTemplate() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.selectedBuilderID == nil || model.templateName.isEmpty || model.isBusy)
            }
            .padding(20)

            if model.templates.isEmpty {
                sectionRule
                InlineEmptyState(title: "NO TEMPLATES", message: "Finish the builder, then publish the first reusable image.")
            } else {
                ForEach(model.templates) { template in
                    sectionRule
                    HStack(spacing: 14) {
                        Text(template.verified ? "VERIFIED" : "CHECK")
                            .font(SkepUI.eyebrow)
                            .frame(width: 62, alignment: .leading)
                            .foregroundStyle(SkepUI.muted(colorScheme))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(template.name).font(.system(size: 13, weight: .semibold))
                            Text(profileSummary(template.resources))
                                .font(SkepUI.metadata)
                                .foregroundStyle(SkepUI.muted(colorScheme))
                        }
                        Spacer()
                        Button("Export archive") { model.exportTemplate(template) }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.isBusy)
                    }
                    .padding(16)
                }
            }

            if let path = model.lastExportPath {
                sectionRule
                Text("EXPORTED  \(path)")
                    .font(SkepUI.metadata)
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }

    private var sectionRule: some View {
        Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
    }
}

private struct WorkspaceSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel

    private var workspaces: [Workspace] {
        model.workspaces.filter { $0.kind == .workspace }
    }

    var body: some View {
        VStack(spacing: 0) {
            StageHeader(
                number: 3,
                title: "Launch isolated workspaces",
                subtitle: "Each workspace gets a persistent microVM and a dedicated Docker data disk.",
                status: workspaces.isEmpty ? nil : "\(workspaces.count) active"
            )
            .padding(20)
            sectionRule

            HStack(alignment: .bottom, spacing: 14) {
                FlatPickerLabel(title: "TEMPLATE") {
                    Picker("Template", selection: $model.selectedTemplateID) {
                        Text("Choose a template").tag(String?.none)
                        ForEach(model.templates) { template in
                            Text(template.name).tag(Optional(template.id))
                        }
                    }
                }
                .frame(width: 220)

                ModernTextField(
                    "Workspace name",
                    help: "A local name for this persistent environment.",
                    prompt: "e.g. feature-auth",
                    text: $model.workspaceName
                )

                Toggle("Autostart", isOn: $model.workspaceAutostart)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, weight: .medium))

                Button("Create workspace") { model.createWorkspace() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.selectedTemplateID == nil || model.workspaceName.isEmpty || model.isBusy)
            }
            .padding(20)

            if workspaces.isEmpty {
                sectionRule
                InlineEmptyState(title: "NO WORKSPACES", message: "Choose a template and launch an isolated environment.")
            } else {
                ForEach(workspaces) { workspace in
                    sectionRule
                    WorkspaceRow(model: model, workspace: workspace)
                }
            }
        }
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }

    private var sectionRule: some View {
        Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
    }
}

private struct WorkspaceRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 13) {
            Rectangle()
                .fill(workspace.status == .running ? SkepUI.ink(colorScheme) : .clear)
                .frame(width: 8, height: 8)
                .overlay(Rectangle().stroke(SkepUI.ink(colorScheme), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(workspace.name).font(.system(size: 13, weight: .semibold))
                    Text(workspace.status.rawValue.uppercased())
                        .font(SkepUI.eyebrow)
                        .foregroundStyle(SkepUI.muted(colorScheme))
                }
                Text("\(cpuSummary(workspace.resources)) / \(memorySummary(workspace.resources))")
                    .font(SkepUI.metadata)
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
            Spacer()
            Button(workspace.autostart ? "Autostart on" : "Autostart off") { model.toggleAutostart(workspace) }
                .buttonStyle(SecondaryButtonStyle())
            Button("Terminal") { model.openTerminal(for: workspace) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(workspace.status != .running)
            Button(workspace.status == .running ? "Stop" : "Start") {
                model.setRunning(workspace, running: workspace.status != .running)
            }
            .buttonStyle(SecondaryButtonStyle())
            Button { model.pendingDeletion = workspace } label: {
                Text("Destroy")
                    .padding(.horizontal, 6)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .font(SkepUI.eyebrow)
                .foregroundStyle(SkepUI.muted(colorScheme))
        }
        .disabled(model.isBusy)
        .padding(16)
    }
}

private struct LockedStage: View {
    @Environment(\.colorScheme) private var colorScheme
    let number: Int
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 16) {
            Text(String(format: "%02d", number))
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(SkepUI.muted(colorScheme))
            }
            Spacer()
            Text("LOCKED")
                .font(SkepUI.eyebrow)
                .tracking(0.8)
        }
        .foregroundStyle(SkepUI.muted(colorScheme))
        .padding(19)
        .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
    }
}

private struct InlineEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let message: String

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(SkepUI.eyebrow)
                .tracking(0.7)
                .frame(width: 96, alignment: .leading)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(SkepUI.muted(colorScheme))
            Spacer()
        }
        .padding(16)
    }
}

private struct FlatPickerLabel<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(SkepUI.eyebrow)
                .tracking(0.8)
            content()
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, minHeight: 36)
                .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
        }
    }
}

private struct FlatSelectionOption: Identifiable {
    let id: String
    let label: String
}

private struct FlatSelectionMenu: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingOptions = false
    let title: String
    let placeholder: String
    @Binding var selection: String?
    let options: [FlatSelectionOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(SkepUI.eyebrow)
                .tracking(0.8)

            Button { showingOptions.toggle() } label: {
                HStack(spacing: 0) {
                    Text(selectedLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == nil ? SkepUI.muted(colorScheme) : SkepUI.ink(colorScheme))
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(SkepUI.inverseInk(colorScheme))
                        .frame(width: 36)
                        .frame(maxHeight: .infinity)
                        .background(SkepUI.ink(colorScheme))
                }
                .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
                .contentShape(Rectangle())
                .background(SkepUI.canvas(colorScheme))
                .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .disabled(options.isEmpty)
            .popover(isPresented: $showingOptions, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        let selected = selection == option.id
                        Button {
                            selection = option.id
                            showingOptions = false
                        } label: {
                            HStack(spacing: 10) {
                                Text(option.label)
                                    .lineLimit(1)
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(selected ? SkepUI.inverseInk(colorScheme) : SkepUI.ink(colorScheme))
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .contentShape(Rectangle())
                            .background(selected ? SkepUI.ink(colorScheme) : SkepUI.canvas(colorScheme))
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)
                    }
                }
                .frame(width: 240)
                .background(SkepUI.canvas(colorScheme))
            }
        }
    }

    private var selectedLabel: String {
        options.first(where: { $0.id == selection })?.label ?? placeholder
    }
}

private struct AddHostView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var host = SSHHost()
    @State private var gcloudCommand = ""
    @State private var gcloudImportMessage: String?
    let onAdd: (SSHHost) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("NEW CONNECTION")
                        .font(SkepUI.eyebrow)
                        .tracking(1.1)
                        .foregroundStyle(SkepUI.muted(colorScheme))
                    Text("Choose a compute host")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Run locally on this Mac or connect to an existing Linux machine.")
                        .font(.system(size: 12))
                        .foregroundStyle(SkepUI.muted(colorScheme))
                }
                Spacer()
            }
            .padding(24)

            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CONNECTION TYPE")
                            .font(SkepUI.eyebrow)
                            .tracking(1.0)
                            .foregroundStyle(SkepUI.muted(colorScheme))
                        HStack(spacing: 0) {
                            connectionOption(.local, title: "This Mac")
                            connectionOption(.ssh, title: "Regular SSH")
                            connectionOption(.gcloudIAP, title: "Google Cloud IAP")
                        }
                        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
                    }

                    if host.kind == .local {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .top, spacing: 18) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 24, weight: .medium))
                                    .frame(width: 34, alignment: .leading)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("THIS MAC")
                                        .font(SkepUI.eyebrow)
                                        .tracking(0.9)
                                    Text("Use native Apple Silicon microVMs")
                                        .font(.system(size: 18, weight: .semibold))
                                    Text("Skep installs a user-owned local runtime and manages isolated builders and workspaces through a private Unix socket. No SSH, cloud account, or administrator access is required.")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(SkepUI.muted(colorScheme))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            HStack(spacing: 0) {
                                localFact("TRANSPORT", "LOCAL SOCKET")
                                localFact("VIRTUALIZATION", "APPLE SILICON")
                                localFact("CONTROL PLANE", "LOCAL ONLY")
                            }
                            .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
                        }
                        .padding(20)
                        .background(SkepUI.faint(colorScheme))
                        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            ModernTextField("Display name", help: "Shown only inside Skep.", prompt: "e.g. Development VM", text: $host.name)
                            ModernTextField(
                                "Linux username",
                                help: host.kind == .ssh
                                    ? "The remote account used for SSH."
                                    : "Optional. Leave blank to let gcloud choose your OS Login user.",
                                prompt: "e.g. root or ubuntu",
                                text: $host.username
                            )
                        }
                    }

                    if host.kind == .ssh {
                        VStack(alignment: .leading, spacing: 14) {
                            ModernTextField("Hostname or IP address", help: "Must already be reachable from this Mac.", prompt: "e.g. dev.example.com", text: $host.hostname)
                            HStack(alignment: .top, spacing: 14) {
                                LabeledPortField(port: $host.port)
                                ModernTextField("SSH identity file", help: "Optional. Leave blank to use SSH config and ssh-agent.", prompt: "~/.ssh/id_ed25519", text: $host.identityFile)
                            }
                        }
                    } else if host.kind == .gcloudIAP {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("IMPORT GCLOUD COMMAND")
                                    .font(SkepUI.eyebrow)
                                    .tracking(0.8)
                                HStack(spacing: 10) {
                                    TextField("gcloud compute ssh … --zone=… --project=… --tunnel-through-iap", text: $gcloudCommand)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12, design: .monospaced))
                                        .padding(.horizontal, 11)
                                        .frame(height: 38)
                                        .lineLimit(1)
                                        .contentShape(Rectangle())
                                        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
                                        .accessibilityLabel("gcloud compute ssh command")
                                        .onSubmit { importGCloudCommand(reportErrors: true) }
                                        .onChange(of: gcloudCommand) { _, command in
                                            autoImportGCloudCommand(command)
                                        }
                                    Button("Parse command") { importGCloudCommand(reportErrors: true) }
                                        .buttonStyle(SecondaryButtonStyle())
                                }
                                Text(gcloudImportMessage ?? "Paste a complete gcloud compute ssh command; valid commands fill the fields automatically.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(SkepUI.muted(colorScheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            HStack(alignment: .top, spacing: 14) {
                                ModernTextField("Instance name", help: "The Compute Engine VM name.", prompt: "e.g. skep-dev-01", text: $host.gcloudInstance)
                                ModernTextField("GCP project ID", help: "The project that owns the VM.", prompt: "e.g. my-project", text: $host.gcloudProject)
                            }
                            ModernTextField("GCP zone", help: "Skep connects with --tunnel-through-iap; no public IP is required.", prompt: "e.g. us-central1-a", text: $host.gcloudZone)
                        }
                    }

                    if host.kind != .local {
                        HStack(alignment: .top, spacing: 12) {
                            Text("AUTH")
                                .font(SkepUI.eyebrow)
                                .frame(width: 44, alignment: .leading)
                            Text("Configure SSH keys, ssh-agent, or gcloud login before connecting. Passwords and private keys are never stored by Skep.")
                                .font(.system(size: 11))
                                .foregroundStyle(SkepUI.muted(colorScheme))
                        }
                        .padding(14)
                        .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
                    }
                }
                .padding(24)
            }

            Rectangle().fill(SkepUI.rule(colorScheme)).frame(height: 1)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(submitTitle) { onAdd(host.kind == .local ? .local : host) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSubmit)
            }
            .padding(20)
        }
        .frame(width: 700, height: modalHeight)
        .background(SkepUI.canvas(colorScheme))
    }

    private func connectionOption(_ kind: HostConnectionKind, title: String) -> some View {
        let selected = host.kind == kind
        return Button { host.kind = kind } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? SkepUI.inverseInk(colorScheme) : SkepUI.ink(colorScheme))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
                .background(selected ? SkepUI.ink(colorScheme) : .clear)
        }
            .buttonStyle(.plain)
    }

    private var canSubmit: Bool {
        guard !host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch host.kind {
        case .local:
            return true
        case .ssh:
            return !host.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !host.hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .gcloudIAP:
            return !host.gcloudInstance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !host.gcloudProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !host.gcloudZone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var submitTitle: String {
        host.kind == .local ? "Open This Mac" : "Add and inspect host"
    }

    private var modalHeight: CGFloat {
        switch host.kind {
        case .local: 530
        case .ssh: 620
        case .gcloudIAP: 720
        }
    }

    private func localFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(SkepUI.eyebrow)
                .tracking(0.6)
                .foregroundStyle(SkepUI.muted(colorScheme))
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SkepUI.rule(colorScheme)).frame(width: 1)
        }
    }

    private func autoImportGCloudCommand(_ command: String) {
        let hasStandaloneLineContinuation = command
            .split(whereSeparator: \.isWhitespace)
            .contains { $0 == "\\" }
        if command.contains(where: { $0.isNewline || $0 == "\t" }) || hasStandaloneLineContinuation {
            let normalized = GCloudSSHCommand.normalizedPastedInput(command)
            if normalized != command {
                gcloudCommand = normalized
                return
            }
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            gcloudImportMessage = nil
            return
        }
        guard let parsed = try? GCloudSSHCommand.parse(command) else { return }
        apply(parsed)
    }

    private func importGCloudCommand(reportErrors: Bool) {
        do {
            apply(try GCloudSSHCommand.parse(gcloudCommand))
        } catch {
            if reportErrors {
                gcloudImportMessage = "ERROR — \(error.localizedDescription)"
            }
        }
    }

    private func apply(_ command: GCloudSSHCommand) {
        host.kind = .gcloudIAP
        host.gcloudInstance = command.instance
        host.gcloudProject = command.project
        host.gcloudZone = command.zone
        host.username = command.username ?? ""
        if host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host.name == "Linux host" {
            host.name = command.instance
        }
        gcloudImportMessage = "IMPORTED — \(command.instance) / \(command.zone) / \(command.project)"
    }
}

private struct LabeledPortField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var port: UInt16

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("SSH PORT")
                .font(SkepUI.eyebrow)
                .tracking(0.8)
            TextField("Port", value: $port, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .padding(.horizontal, 11)
                .frame(height: 38)
                .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
            Text("Usually 22.")
                .font(.system(size: 11))
                .foregroundStyle(SkepUI.muted(colorScheme))
        }
        .frame(width: 120)
    }
}

private func formatGiB(_ mib: UInt64) -> String {
    let value = Double(mib) / 1024
    if value >= 10 || value.rounded() == value {
        return String(format: "%.0f GB", value)
    }
    return String(format: "%.1f GB", value)
}

private func cpuSummary(_ profile: ResourceProfile) -> String {
    if profile.startingCpus == profile.maximumCpus {
        return "\(profile.startingCpus) CPU \(profile.startingCpus == 1 ? "core" : "cores")"
    }
    return "\(profile.startingCpus) → \(profile.maximumCpus) CPU cores"
}

private func memorySummary(_ profile: ResourceProfile) -> String {
    let starting = formatGiB(UInt64(profile.startingMemoryMib))
    let maximum = formatGiB(UInt64(profile.maximumMemoryMib))
    return starting == maximum ? "\(starting) memory" : "\(starting) → \(maximum) memory"
}

private func storageSummary(_ profile: ResourceProfile) -> String {
    "\(formatGiB(UInt64(profile.rootDiskMib))) + \(formatGiB(UInt64(profile.dockerVolumeMib)))"
}

private func profileSummary(_ profile: ResourceProfile) -> String {
    "\(cpuSummary(profile)), \(memorySummary(profile)), \(storageSummary(profile)) storage"
}

private func networkLabel(_ profile: String) -> String {
    switch profile {
    case "none": "Offline"
    case "public": "Internet only"
    default: "Full access"
    }
}

private func networkExplanation(_ profile: String) -> String {
    switch profile {
    case "none":
        "No network access. Use this for deterministic or untrusted workloads."
    case "public":
        "Allows public internet destinations while blocking private and host networks."
    default:
        "Allows public, private, and host-network destinations. Recommended for development."
    }
}
