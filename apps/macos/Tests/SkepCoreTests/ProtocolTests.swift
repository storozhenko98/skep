import Foundation
import Testing
@testable import SkepCore

@Test func decodesLiveHostInfoShape() throws {
    let json = #"{"daemonVersion":"0.1.0","protocolVersion":1,"hostname":"host","operatingSystem":"ubuntu","operatingSystemVersion":"24.04","kernel":"Linux","architecture":"x86_64","cpuCount":2,"totalMemoryMib":3915,"availableMemoryMib":3400,"rootDiskTotalMib":80033,"rootDiskAvailableMib":66000,"systemd":true,"ipv4":true,"ipv6":false,"virtualization":{"provider":"kvm","cpuVirtualization":false,"kvmDevice":false,"kvmUsable":false,"kvmApiVersion":null,"reason":"nested virtualization required"},"microsandbox":{"installed":true,"path":"/var/lib/skep/microsandbox/bin/msb","version":"msb 0.6.8"},"suggestedProfile":{"startingCpus":1,"maximumCpus":2,"startingMemoryMib":2048,"maximumMemoryMib":2937,"rootDiskMib":16384,"tmpfsMib":1024,"dockerVolumeMib":20480,"networkProfile":"all","dnsServers":[]}}"#
    let info = try JSONDecoder().decode(HostInfo.self, from: Data(json.utf8))
    #expect(info.microsandbox.installed)
    #expect(!info.virtualization.kvmUsable)
    #expect(info.suggestedProfile.tmpfsMib == 1024)
}

@Test func directSSHInvocationUsesBatchModeAndBridge() throws {
    let host = SSHHost(name: "test", hostname: "example.test", username: "root", port: 2222)
    let invocation = try host.bridgeInvocation()
    #expect(invocation.executable == "/usr/bin/ssh")
    #expect(invocation.arguments.contains("BatchMode=yes"))
    #expect(invocation.arguments.contains("/usr/bin/sudo"))
    #expect(invocation.arguments.contains("-n"))
    #expect(invocation.arguments.suffix(2) == ["/usr/local/bin/skepctl", "bridge"])
}

@Test func localHostUsesStableIdentityAndLocalBridge() throws {
    let host = SSHHost.local
    #expect(host.id == SSHHost.localID)
    #expect(host.kind == .local)
    let invocation = try host.bridgeInvocation()
    #expect(invocation.executable.hasSuffix("/Skep/Local/bin/skepctl"))
    #expect(invocation.arguments.contains("--socket"))
    #expect(invocation.arguments.last == "bridge")
}

@Test func freshLocalRuntimeReportsSetupRequired() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skep-local-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let status = await LocalHostLifecycleClient(paths: LocalRuntimePaths(root: root)).inspect()
    #expect(status.state == .notInstalled)
    #expect(!status.microsandboxInstalled)
    #expect(!status.daemonSocket)
}

@Test func localRuntimeRejectsMicrosandboxHomeThatCannotFitAgentSocket() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skep-local-test-\(UUID().uuidString)", isDirectory: true)
    let longHome = root.appendingPathComponent(String(repeating: "deep-path-", count: 12), isDirectory: true)
    let paths = LocalRuntimePaths(root: root, microsandboxHome: longHome)
    #expect(!paths.agentRelaySocketPathFits)
    #expect(paths.agentRelaySocketProbe.path.utf8.count >= 104)
}

@Test func localRuntimeAcceptsShortMicrosandboxHome() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("skep-local-test-\(UUID().uuidString)", isDirectory: true)
    let paths = LocalRuntimePaths(
        root: root,
        microsandboxHome: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".skep/msb", isDirectory: true)
    )
    #expect(paths.agentRelaySocketPathFits)
    #expect(paths.agentRelaySocketProbe.path.utf8.count < 104)
}

@Test func liveLocalRuntimeInstallerWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rootPath = environment["SKEP_INTEGRATION_LOCAL_ROOT"], !rootPath.isEmpty else {
        return
    }
    let paths = LocalRuntimePaths(root: URL(fileURLWithPath: rootPath, isDirectory: true))
    let lifecycle = LocalHostLifecycleClient(paths: paths)
    try await lifecycle.install()
    let installed = await lifecycle.inspect()
    #expect(installed.state == .ready)
    #expect(installed.microsandboxVersion == "msb 0.6.8")

    let client = SSHClient(host: .local)
    let info: HostInfo = try await client.call(SkepMethod.hostInfo, params: EmptyParameters())
    #expect(info.operatingSystem == "macOS")
    #expect(info.architecture == "arm64")
    #expect(info.virtualization.kvmUsable)

    try await lifecycle.install()
    let repaired = await lifecycle.inspect()
    #expect(repaired.state == .ready)

    try await lifecycle.remove()
    let removed = await lifecycle.inspect()
    #expect(removed.state == .notInstalled)
}

@Test func gcloudInvocationEnablesIAP() throws {
    let host = SSHHost(
        name: "gce",
        kind: .gcloudIAP,
        username: "ubuntu",
        gcloudInstance: "skep-vm",
        gcloudProject: "demo",
        gcloudZone: "us-central1-a"
    )
    let invocation = try host.bridgeInvocation()
    #expect(invocation.executable == "/usr/bin/env" || invocation.executable.hasSuffix("/gcloud"))
    #expect(invocation.arguments.contains("--tunnel-through-iap"))
    #expect(invocation.arguments.contains("/usr/bin/sudo -n /usr/local/bin/skepctl bridge"))
    #expect(invocation.arguments.contains("--ssh-flag=-lubuntu"))
    #expect(invocation.arguments.contains("--ssh-flag=-T"))
    #expect(!invocation.arguments.contains("--ssh-flag"))
}

@Test func gcloudNoninteractiveCommandUsesAssignedSSHFlags() throws {
    let host = SSHHost(
        name: "gce",
        kind: .gcloudIAP,
        username: "ubuntu",
        gcloudInstance: "skep-vm",
        gcloudProject: "demo",
        gcloudZone: "us-central1-a"
    )
    let invocation = try host.noninteractiveCommandInvocation("printf ready")
    #expect(invocation.arguments.contains("--command"))
    #expect(invocation.arguments.contains("printf ready"))
    #expect(invocation.arguments.contains("--ssh-flag=-lubuntu"))
    #expect(invocation.arguments.contains("--ssh-flag=-T"))
}

@Test func gcloudInteractiveTerminalUsesAssignedUsernameFlag() throws {
    let host = SSHHost(
        name: "gce",
        kind: .gcloudIAP,
        username: "ubuntu",
        gcloudInstance: "skep-vm",
        gcloudProject: "demo",
        gcloudZone: "us-central1-a"
    )
    let invocation = try host.interactiveSSHArguments()
    #expect(invocation.arguments.contains("--ssh-flag=-lubuntu"))
    #expect(!invocation.arguments.contains("--ssh-flag"))
}

@Test func directSSHNoninteractiveCommandUsesBatchMode() throws {
    let host = SSHHost(name: "test", hostname: "example.test", username: "root", port: 2222)
    let invocation = try host.noninteractiveCommandInvocation("printf ready")
    #expect(invocation.executable == "/usr/bin/ssh")
    #expect(invocation.arguments.contains("BatchMode=yes"))
    #expect(invocation.arguments.contains("printf ready"))
    #expect(invocation.arguments.last == "printf ready")
}

@Test func parsesFreshHostPreflight() throws {
    let output = """
    skep_preflight=1
    hostname=dev
    os_id=ubuntu
    os_version=24.04
    architecture=x86_64
    systemd=1
    skepctl=0
    skepd=0
    daemon_active=0
    daemon_socket=0
    microsandbox=0
    cpu_virtualization=0
    kvm_device=0
    passwordless_sudo=1
    """
    let preflight = try HostPreflight.parse(Data(output.utf8))
    #expect(preflight.serviceState == .notInstalled)
    #expect(preflight.supportsAutomaticInstall)
    #expect(!preflight.kvmDevice)
}

@Test func parsesReadyHostPreflight() throws {
    let output = """
    skep_preflight=1
    hostname=dev
    os_id=ubuntu
    os_version=24.04
    architecture=x86_64
    systemd=1
    skepctl=1
    skepd=1
    daemon_active=1
    daemon_socket=1
    microsandbox=1
    cpu_virtualization=1
    kvm_device=1
    passwordless_sudo=1
    """
    let preflight = try HostPreflight.parse(Data(output.utf8))
    #expect(preflight.serviceState == .ready)
    #expect(preflight.microsandboxInstalled)
    #expect(preflight.kvmDevice)
}

@Test func parsesPastedGCloudIAPCommand() throws {
    let command = "gcloud compute ssh agent-host --zone=us-west1-a --project=example-project --tunnel-through-iap"
    let parsed = try GCloudSSHCommand.parse(command)
    #expect(parsed.instance == "agent-host")
    #expect(parsed.zone == "us-west1-a")
    #expect(parsed.project == "example-project")
    #expect(parsed.username == nil)
}

@Test func normalizesHiddenNewlinesForSingleLineDisplay() throws {
    let pasted = "gcloud compute ssh agent-host --zone=us-west1-a --project=example-project --tunnel-through-iap\n"
    let normalized = GCloudSSHCommand.normalizedPastedInput(pasted)
    #expect(normalized == "gcloud compute ssh agent-host --zone=us-west1-a --project=example-project --tunnel-through-iap")
    #expect(try GCloudSSHCommand.parse(normalized).instance == "agent-host")
}

@Test func normalizesMultilineShellCommandForSingleLineDisplay() throws {
    let pasted = """
    gcloud compute ssh agent-host \\
      --zone=us-west1-a \\
      --project=example-project \\
      --tunnel-through-iap
    """
    let normalized = GCloudSSHCommand.normalizedPastedInput(pasted)
    #expect(!normalized.contains("\n"))
    #expect(!normalized.contains("\\"))
    let parsed = try GCloudSSHCommand.parse(normalized)
    #expect(parsed.project == "example-project")
    #expect(parsed.zone == "us-west1-a")
}

@Test func removesFlattenedShellContinuationMarkers() throws {
    let pasted = "gcloud compute ssh agent-host \\   --zone=us-west1-a \\   --project=example-project \\   --tunnel-through-iap"
    let normalized = GCloudSSHCommand.normalizedPastedInput(pasted)
    #expect(!normalized.contains("\\"))
    #expect(try GCloudSSHCommand.parse(normalized).project == "example-project")
}

@Test func parsesGCloudCommandWithSpacedFlagsAndUsername() throws {
    let command = "$ /opt/homebrew/bin/gcloud compute ssh ubuntu@skep-vm --project demo-project --zone us-central1-a --tunnel-through-iap"
    let parsed = try GCloudSSHCommand.parse(command)
    #expect(parsed.instance == "skep-vm")
    #expect(parsed.project == "demo-project")
    #expect(parsed.zone == "us-central1-a")
    #expect(parsed.username == "ubuntu")
}

@Test func rejectsNonIAPGCloudCommand() {
    #expect(throws: GCloudSSHCommandError.missingIAPFlag) {
        try GCloudSSHCommand.parse("gcloud compute ssh skep-vm --project demo --zone us-central1-a")
    }
}

@Test func liveDaemonOverSSHWhenConfigured() async throws {
    guard let hostname = ProcessInfo.processInfo.environment["SKEP_INTEGRATION_HOST"], !hostname.isEmpty else {
        return
    }
    let username = ProcessInfo.processInfo.environment["SKEP_INTEGRATION_USER"] ?? "root"
    let host = SSHHost(name: "integration", hostname: hostname, username: username)
    let client = SSHClient(host: host)
    let info: HostInfo = try await client.call(SkepMethod.hostInfo, params: EmptyParameters())
    let workspaces: [Workspace] = try await client.call(SkepMethod.listWorkspaces, params: EmptyParameters())
    #expect(info.protocolVersion == skepProtocolVersion)
    #expect(info.microsandbox.installed)
    #expect(workspaces.isEmpty)
}

@Test func liveGCloudPreflightWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let instance = environment["SKEP_INTEGRATION_GCLOUD_INSTANCE"], !instance.isEmpty,
          let project = environment["SKEP_INTEGRATION_GCLOUD_PROJECT"], !project.isEmpty,
          let zone = environment["SKEP_INTEGRATION_GCLOUD_ZONE"], !zone.isEmpty else {
        return
    }
    let host = SSHHost(
        name: "gcloud-integration",
        kind: .gcloudIAP,
        username: environment["SKEP_INTEGRATION_GCLOUD_USER"] ?? "",
        gcloudInstance: instance,
        gcloudProject: project,
        gcloudZone: zone
    )
    let preflight = try await HostLifecycleClient(host: host).inspect()
    #expect(preflight.hostname != "unknown")
    #expect(preflight.architecture == "x86_64")
}
