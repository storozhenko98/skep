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

@MainActor
final class AppModel: ObservableObject {
    @Published var hosts: [SSHHost]
    @Published var selectedHostID: UUID?
    @Published var hostPreflight: HostPreflight?
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
        guard let host = selectedHost, hostInfo != nil else { return false }
        return host.isLocal
            ? localRuntimeStatus?.state == .ready
            : hostPreflight?.serviceState == .ready
    }

    func selectHost(_ id: UUID?) {
        guard selectedHostID != id else { return }
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
            let preflight = try await lifecycle.inspect()
            guard selectedHostID == hostID, activeRefreshID == refreshID else { return }
            hostPreflight = preflight

            switch preflight.serviceState {
            case .notInstalled:
                statusMessage = "SSH connected. Install Skep to continue."
                return
            case .incomplete:
                statusMessage = "SSH connected. The Skep installation is incomplete."
                return
            case .stopped:
                statusMessage = "SSH connected. The Skep daemon is not running."
                return
            case .ready:
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
            errorMessage = error.localizedDescription
            if host.isLocal {
                statusMessage = "The local Skep runtime could not respond."
            } else {
                statusMessage = hostPreflight == nil
                    ? "Could not connect to this host."
                    : "The Skep host service could not respond."
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
        selectedSection = section
        operationNotice = nil
    }

    func beginNewBuilder() {
        selectedSection = .builders
        builderName = uniqueName("base", among: builders.map(\.name))
        builderImage = "ubuntu:24.04"
        showingBuilderCreator = true
        operationNotice = nil
    }

    func beginTemplate(from builder: Workspace? = nil) {
        selectedSection = .templates
        selectedBuilderID = builder?.id ?? selectedBuilderID ?? builders.first?.id
        templateName = uniqueName("development", among: templates.map(\.name))
        showingTemplateCreator = true
        operationNotice = nil
    }

    func beginWorkspace(from template: Template? = nil) {
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
        repairSelections()
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
            statusMessage = "Local workspaces require Apple Silicon."
            return
        case .notInstalled:
            statusMessage = "Install the local Skep runtime to continue."
            return
        case .incomplete:
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
