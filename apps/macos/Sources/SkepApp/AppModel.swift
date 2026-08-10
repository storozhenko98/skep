import Foundation
import SkepCore
import SkepTerminal

enum HostSection: String, CaseIterable, Identifiable {
    case overview
    case builders
    case templates
    case workspaces

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

enum ResourceOperation: Equatable {
    case creatingBuilder
    case preparingBuilder(String)
    case publishingTemplate(String)
    case exportingTemplate(String)
    case deletingTemplate(String)
    case creatingWorkspace
    case changingWorkspace(String)
    case deletingWorkspace(String)

    var title: String {
        switch self {
        case .creatingBuilder: "Creating builder"
        case .preparingBuilder: "Installing Docker and tools"
        case .publishingTemplate: "Publishing template"
        case .exportingTemplate: "Exporting template"
        case .deletingTemplate: "Deleting template"
        case .creatingWorkspace: "Creating workspace"
        case .changingWorkspace: "Updating machine"
        case .deletingWorkspace: "Deleting machine"
        }
    }

    func targets(_ id: String) -> Bool {
        switch self {
        case .preparingBuilder(let target), .publishingTemplate(let target),
             .exportingTemplate(let target), .deletingTemplate(let target),
             .changingWorkspace(let target), .deletingWorkspace(let target):
            target == id
        case .creatingBuilder, .creatingWorkspace:
            false
        }
    }
}

struct OperationNotice: Equatable {
    enum Kind: Equatable {
        case success
        case error
    }

    let kind: Kind
    let title: String
    let message: String
}

struct WorkspaceDestination: Hashable, Sendable {
    let hostID: UUID
    let workspaceID: String
}

enum TerminalConnectionState: Equatable {
    case connected
    case reconnecting
    case disconnected
}

@MainActor
final class AppModel: ObservableObject {
    @Published var hosts: [SSHHost]
    @Published var selectedHostID: UUID?
    @Published var hostPreflight: HostPreflight?
    @Published var hostServiceUpdateRequired = false
    @Published var localRuntimeStatus: LocalRuntimeStatus?
    @Published var hostInfo: HostInfo?
    @Published var workspaces: [Workspace] = []
    @Published var templates: [Template] = []
    @Published var isBusy = false
    @Published var statusMessage = "Select a host to begin."
    @Published var errorMessage: String?
    @Published var showingAddHost = false
    @Published var showingInstallHostServiceConfirmation = false
    @Published var showingRemoveHostServiceConfirmation = false
    @Published var pendingDeletion: Workspace?
    @Published var pendingTemplateDeletion: Template?
    @Published var activeTerminal: TerminalSession?
    @Published var selectedWorkspace: WorkspaceDestination?
    @Published private(set) var expandedHostIDs: Set<UUID> = [SSHHost.localID]
    @Published private(set) var readyHostIDs: Set<UUID> = []
    @Published private(set) var workspaceCache: [UUID: [Workspace]] = [:]
    @Published private(set) var workspaceTerminalSessions: [TerminalSession] = []
    @Published private(set) var disconnectedWorkspaceIDs: Set<WorkspaceDestination> = []
    @Published private(set) var reconnectingWorkspaceIDs: Set<WorkspaceDestination> = []
    @Published private(set) var hostConnectionIssues: [UUID: HostConnectionIssue] = [:]
    @Published private(set) var terminalConnectionIssues: [WorkspaceDestination: HostConnectionIssue] = [:]
    @Published private(set) var reauthenticatingHostIDs: Set<UUID> = []
    @Published var lastExportPath: String?
    @Published var selectedSection: HostSection = .overview
    @Published var activeResourceOperation: ResourceOperation?
    @Published var operationNotice: OperationNotice?
    @Published var showingBuilderCreator = false
    @Published var showingTemplateCreator = false
    @Published var showingWorkspaceCreator = false

    @Published var builderName = "base"
    @Published var builderImage = "ubuntu:24.04"
    @Published var templateName = "development"
    @Published var selectedBuilderID: String?
    @Published var workspaceName = "workspace"
    @Published var selectedTemplateID: String?
    @Published var workspaceAutostart = false
    @Published var draftProfile = ResourceProfile()
    @Published var activityLabel: String?

    private let repository: HostRepository
    private var profileWasSeededForHost: UUID?
    private var activeRefreshID: UUID?
    private var automaticReconnectUntil: Date?
    private var automaticReconnectAttempts: [WorkspaceDestination: Int] = [:]
    private var automaticReconnectPending: Set<WorkspaceDestination> = []

    init(repository: HostRepository = .live) {
        self.repository = repository
        let loaded = ((try? repository.load()) ?? []).filter { !$0.isLocal }
        hosts = [.local] + loaded
        selectedHostID = SSHHost.localID
        isBusy = true
        activityLabel = "Checking this Mac"
        statusMessage = "Checking this Mac…"
    }

    var selectedHost: SSHHost? {
        hosts.first { $0.id == selectedHostID }
    }

    var builders: [Workspace] {
        workspaces.filter { $0.kind == .builder }
    }

    var managedWorkspaces: [Workspace] {
        workspaces.filter { $0.kind == .workspace }
    }

    var resourceOperationInProgress: Bool {
        activeResourceOperation != nil
    }

    var remoteHosts: [SSHHost] {
        hosts.filter { !$0.isLocal }
    }

    var canRemoveSelectedHost: Bool {
        selectedHost?.isLocal == false
    }

    var selectedHostIsReady: Bool {
        guard let host = selectedHost,
              hostInfo != nil,
              hostConnectionIssues[host.id] == nil else { return false }
        return host.isLocal
            ? localRuntimeStatus?.state == .ready
            : hostPreflight?.serviceState == .ready
    }

    var selectedWorkspaceItem: Workspace? {
        guard let selectedWorkspace else { return nil }
        return workspaceCache[selectedWorkspace.hostID]?.first {
            $0.id == selectedWorkspace.workspaceID
        }
    }

    func cachedWorkspaces(for hostID: UUID) -> [Workspace] {
        workspaceCache[hostID] ?? []
    }

    func hasLoadedWorkspaces(for hostID: UUID) -> Bool {
        workspaceCache[hostID] != nil
    }

    func isHostExpanded(_ hostID: UUID) -> Bool {
        expandedHostIDs.contains(hostID)
    }

    func isHostReady(_ hostID: UUID) -> Bool {
        readyHostIDs.contains(hostID) && hostConnectionIssues[hostID] == nil
    }

    func hostConnectionIssue(for hostID: UUID) -> HostConnectionIssue? {
        hostConnectionIssues[hostID]
    }

    func isReauthenticatingGoogleCloud(hostID: UUID) -> Bool {
        reauthenticatingHostIDs.contains(hostID)
    }

    func isWorkspaceSelected(hostID: UUID, workspaceID: String) -> Bool {
        selectedWorkspace == WorkspaceDestination(hostID: hostID, workspaceID: workspaceID)
    }

    func isWorkspaceSessionActive(_ session: TerminalSession) -> Bool {
        guard let selectedWorkspace else { return false }
        return session.matches(
            hostID: selectedWorkspace.hostID,
            workspaceID: selectedWorkspace.workspaceID
        )
    }

    func terminalConnectionState(for session: TerminalSession) -> TerminalConnectionState {
        guard let workspaceID = session.workspaceID else { return .connected }
        let destination = WorkspaceDestination(hostID: session.host.id, workspaceID: workspaceID)
        if terminalConnectionIssues[destination] != nil || hostConnectionIssues[session.host.id] != nil {
            return .disconnected
        }
        if disconnectedWorkspaceIDs.contains(destination) { return .disconnected }
        if reconnectingWorkspaceIDs.contains(destination) { return .reconnecting }
        return .connected
    }

    func terminalConnectionIssue(for session: TerminalSession) -> HostConnectionIssue? {
        guard let workspaceID = session.workspaceID else { return nil }
        let destination = WorkspaceDestination(hostID: session.host.id, workspaceID: workspaceID)
        return terminalConnectionIssues[destination] ?? hostConnectionIssues[session.host.id]
    }

    func workspaceTerminalConnectionState(
        hostID: UUID,
        workspaceID: String
    ) -> TerminalConnectionState? {
        guard let session = workspaceTerminalSessions.first(where: {
            $0.matches(hostID: hostID, workspaceID: workspaceID)
        }) else { return nil }
        return terminalConnectionState(for: session)
    }

    func workspaceConnectionIssue(hostID: UUID, workspaceID: String) -> HostConnectionIssue? {
        let destination = WorkspaceDestination(hostID: hostID, workspaceID: workspaceID)
        return terminalConnectionIssues[destination] ?? hostConnectionIssues[hostID]
    }

    func workspaceTerminalDidExit(sessionID: UUID) {
        guard let session = workspaceTerminalSessions.first(where: { $0.id == sessionID }),
              let workspaceID = session.workspaceID else { return }
        let destination = WorkspaceDestination(hostID: session.host.id, workspaceID: workspaceID)
        reconnectingWorkspaceIDs.remove(destination)
        disconnectedWorkspaceIDs.insert(destination)

        if !session.host.isLocal {
            Task { [weak self] in
                await self?.diagnoseWorkspaceTerminalDisconnect(destination, host: session.host)
            }
        }

        if let automaticReconnectUntil, Date() <= automaticReconnectUntil {
            scheduleAutomaticReconnect(destination)
        }
    }

    func reconnectWorkspaceTerminal(hostID: UUID, workspaceID: String) {
        let destination = WorkspaceDestination(hostID: hostID, workspaceID: workspaceID)
        hostConnectionIssues.removeValue(forKey: hostID)
        terminalConnectionIssues.removeValue(forKey: destination)
        automaticReconnectAttempts[destination] = 0
        automaticReconnectPending.remove(destination)
        reconnectTerminal(destination)
    }

    func reauthenticateGoogleCloud(hostID: UUID) {
        guard let host = hosts.first(where: { $0.id == hostID }),
              host.kind == .gcloudIAP,
              !reauthenticatingHostIDs.contains(hostID) else { return }

        reauthenticatingHostIDs.insert(hostID)
        statusMessage = "Opening Google Cloud authentication…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.reauthenticatingHostIDs.remove(hostID) }
            do {
                try await GCloudCLI.authenticate()
                self.hostConnectionIssues.removeValue(forKey: hostID)
                self.errorMessage = nil
                self.statusMessage = "Google Cloud authentication restored. Reconnecting…"
                await self.refresh(hostID: hostID)
                guard self.hostConnectionIssues[hostID] == nil else { return }
                let destinations = self.disconnectedWorkspaceIDs.filter { $0.hostID == hostID }
                for destination in destinations {
                    self.reconnectWorkspaceTerminal(
                        hostID: destination.hostID,
                        workspaceID: destination.workspaceID
                    )
                }
            } catch {
                let classified = HostConnectionIssue.classify(
                    host: host,
                    diagnostic: error.localizedDescription
                )
                let issue = classified.kind == .googleCloudCLIUnavailable
                    ? classified
                    : HostConnectionIssue(
                        kind: .googleCloudAuthentication,
                        diagnostic: error.localizedDescription
                    )
                self.hostConnectionIssues[hostID] = issue
                self.readyHostIDs.remove(hostID)
                self.errorMessage = error.localizedDescription
                self.statusMessage = "Google Cloud authentication is still required."
            }
        }
    }

    func beginAutomaticTerminalReconnectWindow() {
        automaticReconnectUntil = Date().addingTimeInterval(30)
        automaticReconnectAttempts.removeAll()
        for destination in disconnectedWorkspaceIDs {
            scheduleAutomaticReconnect(destination, immediate: true)
        }
    }

    func toggleHostExpansion(_ hostID: UUID) {
        if expandedHostIDs.contains(hostID) {
            expandedHostIDs.remove(hostID)
        } else {
            expandedHostIDs.insert(hostID)
        }
    }

    func selectHost(_ id: UUID?) {
        selectedWorkspace = nil
        if let id { expandedHostIDs.insert(id) }
        guard selectedHostID != id else { return }
        changeSelectedHost(to: id)
    }

    func selectWorkspace(hostID: UUID, workspace: Workspace) {
        guard workspace.kind == .workspace,
              hosts.contains(where: { $0.id == hostID }) else { return }
        expandedHostIDs.insert(hostID)
        if selectedHostID != hostID {
            changeSelectedHost(to: hostID)
        }
        selectedWorkspace = WorkspaceDestination(hostID: hostID, workspaceID: workspace.id)
        operationNotice = nil
        if workspace.status == .running,
           let host = hosts.first(where: { $0.id == hostID }) {
            ensureWorkspaceTerminal(host: host, workspace: workspace)
        }
    }

    func showSelectedHostManagement() {
        selectedWorkspace = nil
    }

    func openSelectedWorkspaceTerminal() {
        guard let selectedWorkspace,
              let host = hosts.first(where: { $0.id == selectedWorkspace.hostID }),
              let workspace = workspaceCache[selectedWorkspace.hostID]?.first(where: {
                  $0.id == selectedWorkspace.workspaceID
              }),
              workspace.status == .running else { return }
        ensureWorkspaceTerminal(host: host, workspace: workspace)
    }

    private func changeSelectedHost(to id: UUID?) {
        selectedHostID = id
        resetSelectedHostState()
        if id == nil {
            statusMessage = "Select a host to begin."
        } else {
            isBusy = true
            activityLabel = selectedHost?.isLocal == true ? "Checking this Mac" : "Checking host"
            statusMessage = selectedHost?.isLocal == true ? "Checking this Mac…" : "Checking host…"
        }
    }

    func addHost(_ host: SSHHost) {
        if host.isLocal {
            showingAddHost = false
            if selectedHostID == SSHHost.localID {
                refreshSelectedHost()
            } else {
                selectHost(SSHHost.localID)
            }
            return
        }
        hosts.append(host)
        persistHosts()
        showingAddHost = false
        selectHost(host.id)
    }

    func removeSelectedHost() {
        guard let id = selectedHostID, id != SSHHost.localID else { return }
        hosts.removeAll { $0.id == id }
        expandedHostIDs.remove(id)
        readyHostIDs.remove(id)
        hostConnectionIssues.removeValue(forKey: id)
        workspaceCache.removeValue(forKey: id)
        workspaceTerminalSessions.removeAll { $0.host.id == id }
        disconnectedWorkspaceIDs = Set(disconnectedWorkspaceIDs.filter { $0.hostID != id })
        reconnectingWorkspaceIDs = Set(reconnectingWorkspaceIDs.filter { $0.hostID != id })
        terminalConnectionIssues = terminalConnectionIssues.filter { $0.key.hostID != id }
        reauthenticatingHostIDs.remove(id)
        automaticReconnectAttempts = automaticReconnectAttempts.filter { $0.key.hostID != id }
        automaticReconnectPending = Set(automaticReconnectPending.filter { $0.hostID != id })
        if selectedWorkspace?.hostID == id { selectedWorkspace = nil }
        persistHosts()
        selectHost(hosts.first?.id)
    }

    func refreshSelectedHost() {
        guard let id = selectedHostID else { return }
        operationNotice = nil
        Task { await refresh(hostID: id) }
    }

    func openHostTerminal() {
        guard let host = selectedHost else { return }
        activeTerminal = TerminalSession(host: host, target: .host)
    }

    func openTerminal(for workspace: Workspace) {
        guard let host = selectedHost else { return }
        if workspace.kind == .workspace {
            selectWorkspace(hostID: host.id, workspace: workspace)
            return
        }
        activeTerminal = TerminalSession(
            host: host,
            target: .workspace(id: workspace.id, name: workspace.name)
        )
    }

    func refresh(hostID: UUID) async {
        guard let host = hosts.first(where: { $0.id == hostID }) else { return }
        let refreshID = UUID()
        activeRefreshID = refreshID
        isBusy = true
        activityLabel = host.isLocal ? "Checking this Mac" : "Checking host"
        errorMessage = nil
        statusMessage = host.isLocal ? "Checking the local runtime…" : "Checking \(host.name)…"
        defer {
            if activeRefreshID == refreshID {
                isBusy = false
                activityLabel = nil
            }
        }
        do {
            if host.isLocal {
                try await refreshLocalHost(host: host, refreshID: refreshID)
                return
            }
            let lifecycle = HostLifecycleClient(host: host)
            var preflight = try await lifecycle.inspect()
            guard selectedHostID == hostID, activeRefreshID == refreshID else { return }
            hostPreflight = preflight
            hostServiceUpdateRequired = false
            hostConnectionIssues.removeValue(forKey: hostID)

            switch preflight.serviceState {
            case .notInstalled:
                readyHostIDs.remove(hostID)
                statusMessage = "SSH connected. Install Skep to continue."
                return
            case .incomplete:
                readyHostIDs.remove(hostID)
                statusMessage = "SSH connected. The Skep installation is incomplete."
                return
            case .stopped:
                readyHostIDs.remove(hostID)
                statusMessage = "SSH connected. The Skep daemon is not running."
                return
            case .ready:
                let payload = try HostInstallerPayload.directory()
                if try lifecycle.updateRequired(preflight: preflight, payloadDirectory: payload) {
                    hostServiceUpdateRequired = true
                    guard preflight.supportsAutomaticUpdate else {
                        readyHostIDs.remove(hostID)
                        statusMessage = "SSH connected. Update the Skep host service to continue."
                        return
                    }
                    activityLabel = "Updating host service"
                    statusMessage = "Updating the Skep host service…"
                    try await lifecycle.update(payloadDirectory: payload)
                    preflight = try await lifecycle.inspect()
                    guard selectedHostID == hostID, activeRefreshID == refreshID else { return }
                    hostPreflight = preflight
                    hostServiceUpdateRequired = false
                    guard preflight.serviceState == .ready else {
                        readyHostIDs.remove(hostID)
                        statusMessage = "The updated Skep host service did not become ready."
                        return
                    }
                }
                activityLabel = "Loading host"
            }

            let client = SSHClient(host: host)
            async let info: HostInfo = client.call(SkepMethod.hostInfo, params: EmptyParameters())
            async let remoteWorkspaces: [Workspace] = client.call(SkepMethod.listWorkspaces, params: EmptyParameters())
            async let remoteTemplates: [Template] = client.call(SkepMethod.listTemplates, params: EmptyParameters())
            let snapshot = try await (info, remoteWorkspaces, remoteTemplates)
            guard selectedHostID == hostID, activeRefreshID == refreshID else { return }
            hostInfo = snapshot.0
            workspaces = snapshot.1
            templates = snapshot.2
            rememberWorkspaceSnapshot(snapshot.1, for: host)
            hostConnectionIssues.removeValue(forKey: hostID)
            if profileWasSeededForHost != hostID {
                draftProfile = snapshot.0.suggestedProfile
                profileWasSeededForHost = hostID
            }
            repairSelections()
            statusMessage = snapshot.0.virtualization.kvmUsable
                ? "Connected. Host is ready for microVMs."
                : "Connected. This host needs nested KVM."
        } catch {
            guard selectedHostID == hostID, activeRefreshID == refreshID else { return }
            hostInfo = nil
            workspaces = []
            templates = []
            readyHostIDs.remove(hostID)
            errorMessage = error.localizedDescription
            if host.isLocal {
                statusMessage = "The local Skep runtime could not respond."
            } else {
                let issue = HostConnectionIssue.classify(
                    host: host,
                    diagnostic: error.localizedDescription
                )
                hostConnectionIssues[hostID] = issue
                statusMessage = issue.requiresGoogleCloudAuthentication
                    ? "Google Cloud authentication is required."
                    : "Could not connect to this host."
            }
        }
    }

    func installHostService() {
        guard let host = selectedHost else { return }
        showingInstallHostServiceConfirmation = false
        Task {
            let operationID = UUID()
            activeRefreshID = operationID
            isBusy = true
            activityLabel = "Installing Skep"
            errorMessage = nil
            statusMessage = "Installing the Skep host service…"
            do {
                if host.isLocal {
                    statusMessage = "Installing the local Skep runtime…"
                    try await LocalHostLifecycleClient().install()
                } else {
                    let payload = try HostInstallerPayload.directory()
                    try await HostLifecycleClient(host: host).install(payloadDirectory: payload)
                }
                guard selectedHostID == host.id, activeRefreshID == operationID else { return }
                isBusy = false
                activityLabel = nil
                statusMessage = host.isLocal
                    ? "Local runtime installed. Verifying this Mac…"
                    : "Skep installed. Verifying the host…"
                await refresh(hostID: host.id)
            } catch {
                guard selectedHostID == host.id, activeRefreshID == operationID else { return }
                isBusy = false
                activityLabel = nil
                errorMessage = error.localizedDescription
                statusMessage = "Skep installation failed."
            }
        }
    }

    func removeHostService() {
        guard let host = selectedHost else { return }
        showingRemoveHostServiceConfirmation = false
        Task {
            let operationID = UUID()
            activeRefreshID = operationID
            isBusy = true
            activityLabel = "Removing Skep"
            errorMessage = nil
            statusMessage = "Removing the Skep host service…"
            do {
                if host.isLocal {
                    statusMessage = "Removing the local Skep runtime…"
                    try await LocalHostLifecycleClient().remove()
                } else {
                    let payload = try HostInstallerPayload.directory()
                    try await HostLifecycleClient(host: host).remove(payloadDirectory: payload)
                }
                guard selectedHostID == host.id, activeRefreshID == operationID else { return }
                isBusy = false
                activityLabel = nil
                statusMessage = host.isLocal
                    ? "Local runtime removed. Workspace state was preserved."
                    : "Skep removed. Host data was preserved."
                await refresh(hostID: host.id)
            } catch {
                guard selectedHostID == host.id, activeRefreshID == operationID else { return }
                isBusy = false
                activityLabel = nil
                errorMessage = error.localizedDescription
                statusMessage = "Could not remove the Skep host service."
            }
        }
    }

    func selectSection(_ section: HostSection) {
        selectedWorkspace = nil
        selectedSection = section
        operationNotice = nil
    }

    func beginNewBuilder() {
        selectedWorkspace = nil
        selectedSection = .builders
        builderName = uniqueName("base", among: builders.map(\.name))
        builderImage = "ubuntu:24.04"
        showingBuilderCreator = true
        operationNotice = nil
    }

    func beginTemplate(from builder: Workspace? = nil) {
        selectedWorkspace = nil
        selectedSection = .templates
        selectedBuilderID = builder?.id ?? selectedBuilderID ?? builders.first?.id
        templateName = uniqueName("development", among: templates.map(\.name))
        showingTemplateCreator = true
        operationNotice = nil
    }

    func beginWorkspace(from template: Template? = nil) {
        selectedWorkspace = nil
        selectedSection = .workspaces
        selectedTemplateID = template?.id ?? selectedTemplateID ?? templates.first?.id
        workspaceName = uniqueName("workspace", among: managedWorkspaces.map(\.name))
        showingWorkspaceCreator = true
        operationNotice = nil
    }

    func createBuilder() {
        guard let host = selectedHost else { return }
        let name = builderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = builderImage.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = CreateBuilderParameters(name: name, image: image, resources: draftProfile)
        Task {
            let succeeded = await performResource(
                host: host,
                operation: .creatingBuilder,
                successTitle: "Builder created",
                successMessage: "\(name) is running as an independent editable microVM."
            ) {
                let client = SSHClient(host: host)
                let _: Workspace = try await client.call(SkepMethod.createBuilder, params: params)
            }
            if succeeded { showingBuilderCreator = false }
        }
    }

    func bootstrap(_ builder: Workspace) {
        guard let host = selectedHost else { return }
        let params = WorkspaceIDParameters(workspaceId: builder.id, expectedGeneration: builder.generation)
        Task {
            _ = await performResource(
                host: host,
                operation: .preparingBuilder(builder.id),
                successTitle: "Builder tools installed",
                successMessage: "\(builder.name) now has Git, curl, Git LFS, Docker, and tmux. Docker is running."
            ) {
                let client = SSHClient(host: host)
                let _: Workspace = try await client.call(SkepMethod.bootstrapBuilder, params: params)
            }
        }
    }

    func bootstrapSelectedBuilder() {
        guard let builder = builders.first(where: { $0.id == selectedBuilderID }) else { return }
        bootstrap(builder)
    }

    func publishTemplate() {
        guard let host = selectedHost,
              let builder = builders.first(where: { $0.id == selectedBuilderID }) else { return }
        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = PublishTemplateParameters(
            workspaceId: builder.id,
            name: name,
            expectedGeneration: builder.generation
        )
        Task {
            let succeeded = await performResource(
                host: host,
                operation: .publishingTemplate(builder.id),
                successTitle: "Template published",
                successMessage: "\(name) is a verified snapshot. \(builder.name) was stopped to capture it consistently and remains available in Builders."
            ) {
                let client = SSHClient(host: host)
                let _: Template = try await client.call(SkepMethod.publishTemplate, params: params)
            }
            if succeeded { showingTemplateCreator = false }
        }
    }

    func exportTemplate(_ template: Template) {
        guard let host = selectedHost else { return }
        let params = ExportTemplateParameters(templateId: template.id, outputName: template.name)
        Task {
            let succeeded = await performResource(
                host: host,
                operation: .exportingTemplate(template.id),
                successTitle: "Template exported",
                successMessage: "The archive for \(template.name) is ready."
            ) {
                let client = SSHClient(host: host)
                let result: ExportResult = try await client.call(SkepMethod.exportTemplate, params: params)
                await MainActor.run { self.lastExportPath = result.path }
            }
            if !succeeded { lastExportPath = nil }
        }
    }

    func createWorkspace() {
        guard let host = selectedHost, let templateID = selectedTemplateID else { return }
        let name = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = CreateWorkspaceParameters(
            templateId: templateID,
            name: name,
            autostart: workspaceAutostart
        )
        Task {
            let succeeded = await performResource(
                host: host,
                operation: .creatingWorkspace,
                successTitle: "Workspace created",
                successMessage: "\(name) is running in its own persistent microVM with a dedicated Docker disk."
            ) {
                let client = SSHClient(host: host)
                let _: Workspace = try await client.call(SkepMethod.createWorkspace, params: params)
            }
            if succeeded { showingWorkspaceCreator = false }
        }
    }

    func setRunning(_ workspace: Workspace, running: Bool) {
        guard let host = selectedHost else { return }
        let params = WorkspaceIDParameters(workspaceId: workspace.id, expectedGeneration: workspace.generation)
        let noun = workspace.kind == .builder ? "Builder" : "Workspace"
        Task {
            _ = await performResource(
                host: host,
                operation: .changingWorkspace(workspace.id),
                successTitle: "\(noun) \(running ? "started" : "stopped")",
                successMessage: "\(workspace.name) is now \(running ? "running" : "stopped")."
            ) {
                let client = SSHClient(host: host)
                let _: Workspace = try await client.call(
                    running ? SkepMethod.startWorkspace : SkepMethod.stopWorkspace,
                    params: params
                )
            }
        }
    }

    func toggleAutostart(_ workspace: Workspace) {
        guard let host = selectedHost else { return }
        let enabled = !workspace.autostart
        let params = SetAutostartParameters(
            workspaceId: workspace.id,
            autostart: enabled,
            expectedGeneration: workspace.generation
        )
        Task {
            _ = await performResource(
                host: host,
                operation: .changingWorkspace(workspace.id),
                successTitle: "Autostart \(enabled ? "enabled" : "disabled")",
                successMessage: "\(workspace.name) \(enabled ? "will start with the Skep service" : "will remain stopped after a host restart")."
            ) {
                let client = SSHClient(host: host)
                let _: Workspace = try await client.call(SkepMethod.setAutostart, params: params)
            }
        }
    }

    func confirmDeletion() {
        guard let host = selectedHost, let workspace = pendingDeletion else { return }
        pendingDeletion = nil
        let params = DeleteWorkspaceParameters(
            workspaceId: workspace.id,
            expectedGeneration: workspace.generation
        )
        let noun = workspace.kind == .builder ? "Builder" : "Workspace"
        Task {
            _ = await performResource(
                host: host,
                operation: .deletingWorkspace(workspace.id),
                successTitle: "\(noun) deleted",
                successMessage: "\(workspace.name) and its dedicated Docker disk were removed."
            ) {
                let client = SSHClient(host: host)
                let _: DeleteResult = try await client.call(SkepMethod.deleteWorkspace, params: params)
            }
        }
    }

    func confirmTemplateDeletion() {
        guard let host = selectedHost, let template = pendingTemplateDeletion else { return }
        pendingTemplateDeletion = nil
        let params = DeleteTemplateParameters(
            templateId: template.id,
            expectedGeneration: template.generation
        )
        Task {
            _ = await performResource(
                host: host,
                operation: .deletingTemplate(template.id),
                successTitle: "Template deleted",
                successMessage: "\(template.name) was removed. Existing workspaces created from it are unaffected."
            ) {
                let client = SSHClient(host: host)
                let _: DeleteResult = try await client.call(SkepMethod.deleteTemplate, params: params)
            }
        }
    }

    private func performResource(
        host: SSHHost,
        operation: ResourceOperation,
        successTitle: String,
        successMessage: String,
        action: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        guard activeResourceOperation == nil else { return false }
        activeResourceOperation = operation
        operationNotice = nil
        statusMessage = "\(operation.title)…"
        defer {
            if activeResourceOperation == operation {
                activeResourceOperation = nil
            }
        }
        do {
            try await action()
            guard selectedHostID == host.id else { return false }
            try await reloadResourceSnapshot(for: host)
            operationNotice = OperationNotice(
                kind: .success,
                title: successTitle,
                message: successMessage
            )
            statusMessage = successTitle
            return true
        } catch {
            guard selectedHostID == host.id else { return false }
            operationNotice = OperationNotice(
                kind: .error,
                title: "\(operation.title) failed",
                message: error.localizedDescription
            )
            statusMessage = "\(operation.title) failed."
            return false
        }
    }

    private func reloadResourceSnapshot(for host: SSHHost) async throws {
        let client = SSHClient(host: host)
        async let info: HostInfo = client.call(SkepMethod.hostInfo, params: EmptyParameters())
        async let currentWorkspaces: [Workspace] = client.call(SkepMethod.listWorkspaces, params: EmptyParameters())
        async let currentTemplates: [Template] = client.call(SkepMethod.listTemplates, params: EmptyParameters())
        let snapshot = try await (info, currentWorkspaces, currentTemplates)
        guard selectedHostID == host.id else { return }
        hostInfo = snapshot.0
        workspaces = snapshot.1
        templates = snapshot.2
        rememberWorkspaceSnapshot(snapshot.1, for: host)
        repairSelections()
    }

    private func ensureWorkspaceTerminal(host: SSHHost, workspace: Workspace) {
        guard workspace.status == .running,
              !workspaceTerminalSessions.contains(where: {
                  $0.matches(hostID: host.id, workspaceID: workspace.id)
              }) else { return }
        let destination = WorkspaceDestination(hostID: host.id, workspaceID: workspace.id)
        disconnectedWorkspaceIDs.remove(destination)
        reconnectingWorkspaceIDs.remove(destination)
        terminalConnectionIssues.removeValue(forKey: destination)
        workspaceTerminalSessions.append(
            TerminalSession(
                host: host,
                target: .workspace(id: workspace.id, name: workspace.name)
            )
        )
    }

    private func rememberWorkspaceSnapshot(_ snapshot: [Workspace], for host: SSHHost) {
        let current = snapshot.filter { $0.kind == .workspace }
        workspaceCache[host.id] = current
        readyHostIDs.insert(host.id)

        let currentIDs = Set(current.map(\.id))
        workspaceTerminalSessions.removeAll { session in
            guard session.host.id == host.id, let workspaceID = session.workspaceID else {
                return false
            }
            guard currentIDs.contains(workspaceID) else { return true }
            return current.first(where: { $0.id == workspaceID })?.status != .running
        }

        let runningDestinations = Set(current.filter { $0.status == .running }.map {
            WorkspaceDestination(hostID: host.id, workspaceID: $0.id)
        })
        disconnectedWorkspaceIDs = Set(disconnectedWorkspaceIDs.filter {
            $0.hostID != host.id || runningDestinations.contains($0)
        })
        reconnectingWorkspaceIDs = Set(reconnectingWorkspaceIDs.filter {
            $0.hostID != host.id || runningDestinations.contains($0)
        })
        terminalConnectionIssues = terminalConnectionIssues.filter {
            $0.key.hostID != host.id || runningDestinations.contains($0.key)
        }
        automaticReconnectAttempts = automaticReconnectAttempts.filter {
            $0.key.hostID != host.id || runningDestinations.contains($0.key)
        }
        automaticReconnectPending = Set(automaticReconnectPending.filter {
            $0.hostID != host.id || runningDestinations.contains($0)
        })

        guard let destination = selectedWorkspace, destination.hostID == host.id else { return }
        guard let workspace = current.first(where: { $0.id == destination.workspaceID }) else {
            selectedWorkspace = nil
            return
        }
        if workspace.status == .running {
            ensureWorkspaceTerminal(host: host, workspace: workspace)
        }
    }

    private func reconnectTerminal(_ destination: WorkspaceDestination) {
        guard let host = hosts.first(where: { $0.id == destination.hostID }),
              let workspace = workspaceCache[destination.hostID]?.first(where: {
                  $0.id == destination.workspaceID
              }),
              workspace.status == .running else { return }

        guard terminalConnectionIssues[destination]?.requiresGoogleCloudAuthentication != true else {
            reconnectingWorkspaceIDs.remove(destination)
            return
        }

        workspaceTerminalSessions.removeAll {
            $0.matches(hostID: destination.hostID, workspaceID: destination.workspaceID)
        }
        disconnectedWorkspaceIDs.remove(destination)
        reconnectingWorkspaceIDs.insert(destination)
        terminalConnectionIssues.removeValue(forKey: destination)

        let replacement = TerminalSession(
            host: host,
            target: .workspace(id: workspace.id, name: workspace.name)
        )
        workspaceTerminalSessions.append(replacement)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                  self.workspaceTerminalSessions.contains(where: { $0.id == replacement.id }),
                  !self.disconnectedWorkspaceIDs.contains(destination) else { return }
            self.reconnectingWorkspaceIDs.remove(destination)
            self.automaticReconnectAttempts.removeValue(forKey: destination)
            self.hostConnectionIssues.removeValue(forKey: destination.hostID)
            self.readyHostIDs.insert(destination.hostID)
        }
    }

    private func diagnoseWorkspaceTerminalDisconnect(
        _ destination: WorkspaceDestination,
        host: SSHHost
    ) async {
        do {
            let client = SSHClient(host: host)
            let _: HostInfo = try await client.call(
                SkepMethod.hostInfo,
                params: EmptyParameters()
            )
            guard disconnectedWorkspaceIDs.contains(destination) else { return }
            terminalConnectionIssues.removeValue(forKey: destination)
        } catch {
            guard disconnectedWorkspaceIDs.contains(destination) else { return }
            let issue = HostConnectionIssue.classify(
                host: host,
                diagnostic: error.localizedDescription
            )
            terminalConnectionIssues[destination] = issue
            hostConnectionIssues[host.id] = issue
            readyHostIDs.remove(host.id)
            if issue.requiresGoogleCloudAuthentication {
                automaticReconnectPending.remove(destination)
                if selectedHostID == host.id {
                    statusMessage = "Google Cloud authentication is required."
                }
            }
        }
    }

    private func scheduleAutomaticReconnect(
        _ destination: WorkspaceDestination,
        immediate: Bool = false
    ) {
        guard disconnectedWorkspaceIDs.contains(destination),
              !automaticReconnectPending.contains(destination),
              terminalConnectionIssues[destination]?.requiresGoogleCloudAuthentication != true,
              let automaticReconnectUntil,
              Date() <= automaticReconnectUntil else { return }

        let attempt = automaticReconnectAttempts[destination, default: 0]
        let delays: [TimeInterval] = [0.5, 1.5, 3, 6]
        guard attempt < delays.count else { return }
        automaticReconnectAttempts[destination] = attempt + 1
        automaticReconnectPending.insert(destination)
        let delay = immediate ? 0.25 : delays[attempt]

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.automaticReconnectPending.remove(destination)
            guard self.disconnectedWorkspaceIDs.contains(destination),
                  let automaticReconnectUntil = self.automaticReconnectUntil,
                  Date() <= automaticReconnectUntil else { return }
            self.reconnectTerminal(destination)
        }
    }

    private func uniqueName(_ base: String, among names: [String]) -> String {
        let occupied = Set(names)
        guard occupied.contains(base) else { return base }
        var suffix = 2
        while occupied.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    private func repairSelections() {
        if !builders.contains(where: { $0.id == selectedBuilderID }) {
            selectedBuilderID = builders.first?.id
        }
        if !templates.contains(where: { $0.id == selectedTemplateID }) {
            selectedTemplateID = templates.first?.id
        }
    }

    private func resetSelectedHostState() {
        activeRefreshID = nil
        hostPreflight = nil
        hostServiceUpdateRequired = false
        localRuntimeStatus = nil
        hostInfo = nil
        workspaces = []
        templates = []
        errorMessage = nil
        lastExportPath = nil
        selectedBuilderID = nil
        selectedTemplateID = nil
        selectedSection = .overview
        activeResourceOperation = nil
        operationNotice = nil
        pendingDeletion = nil
        pendingTemplateDeletion = nil
        showingBuilderCreator = false
        showingTemplateCreator = false
        showingWorkspaceCreator = false
        isBusy = false
        activityLabel = nil
    }

    private func persistHosts() {
        do {
            try repository.save(hosts.filter { !$0.isLocal })
        } catch {
            errorMessage = "Could not save hosts: \(error.localizedDescription)"
        }
    }

    private func refreshLocalHost(host: SSHHost, refreshID: UUID) async throws {
        let lifecycle = LocalHostLifecycleClient()
        var status = await lifecycle.inspect()
        guard selectedHostID == host.id, activeRefreshID == refreshID else { return }
        localRuntimeStatus = status

        if status.skepctlInstalled, status.skepdInstalled {
            activityLabel = "Updating local service"
            if try await lifecycle.updateBundledHelpersIfNeeded() {
                status = await lifecycle.inspect()
                guard selectedHostID == host.id, activeRefreshID == refreshID else { return }
                localRuntimeStatus = status
            }
        }

        switch status.state {
        case .unsupported:
            readyHostIDs.remove(host.id)
            statusMessage = "Local workspaces require Apple Silicon."
            return
        case .notInstalled:
            readyHostIDs.remove(host.id)
            statusMessage = "Install the local Skep runtime to continue."
            return
        case .incomplete:
            readyHostIDs.remove(host.id)
            statusMessage = "The local Skep installation is incomplete."
            return
        case .stopped:
            activityLabel = "Starting local service"
            try await lifecycle.ensureRunning()
            status = await lifecycle.inspect()
            guard selectedHostID == host.id, activeRefreshID == refreshID else { return }
            localRuntimeStatus = status
        case .ready:
            break
        }

        guard status.state == .ready else {
            readyHostIDs.remove(host.id)
            statusMessage = "The local Skep service could not be started."
            return
        }
        activityLabel = "Loading this Mac"
        let client = SSHClient(host: host)
        async let info: HostInfo = client.call(SkepMethod.hostInfo, params: EmptyParameters())
        async let localWorkspaces: [Workspace] = client.call(SkepMethod.listWorkspaces, params: EmptyParameters())
        async let localTemplates: [Template] = client.call(SkepMethod.listTemplates, params: EmptyParameters())
        let snapshot = try await (info, localWorkspaces, localTemplates)
        guard selectedHostID == host.id, activeRefreshID == refreshID else { return }
        hostInfo = snapshot.0
        workspaces = snapshot.1
        templates = snapshot.2
        rememberWorkspaceSnapshot(snapshot.1, for: host)
        if profileWasSeededForHost != host.id {
            draftProfile = snapshot.0.suggestedProfile
            profileWasSeededForHost = host.id
        }
        repairSelections()
        statusMessage = "This Mac is ready for local microVMs."
    }
}

private enum HostInstallerPayload {
    static func directory() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SKEP_HOST_PAYLOAD_DIR"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("HostInstaller", isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("artifacts/host-installer", isDirectory: true)
        )

        if let directory = candidates.first(where: {
            fileManager.fileExists(atPath: $0.appendingPathComponent("SHA256SUMS").path)
        }) {
            return directory
        }
        throw HostLifecycleError.missingPayload(
            "Package Skep.app with scripts/package-macos.sh, or set SKEP_HOST_PAYLOAD_DIR for development."
        )
    }
}
