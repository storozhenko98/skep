import Foundation

public enum HostConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case ssh
    case gcloudIAP

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .local: "This Mac"
        case .ssh: "SSH"
        case .gcloudIAP: "Google Cloud IAP"
        }
    }
}

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public static let localID = UUID(uuidString: "20B21469-C57A-4F6C-9D8C-54C97375616C")!

    public var id: UUID
    public var name: String
    public var kind: HostConnectionKind
    public var hostname: String
    public var username: String
    public var port: UInt16
    public var identityFile: String
    public var gcloudInstance: String
    public var gcloudProject: String
    public var gcloudZone: String

    public init(
        id: UUID = UUID(),
        name: String = "Linux host",
        kind: HostConnectionKind = .ssh,
        hostname: String = "",
        username: String = "root",
        port: UInt16 = 22,
        identityFile: String = "",
        gcloudInstance: String = "",
        gcloudProject: String = "",
        gcloudZone: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.hostname = hostname
        self.username = username
        self.port = port
        self.identityFile = identityFile
        self.gcloudInstance = gcloudInstance
        self.gcloudProject = gcloudProject
        self.gcloudZone = gcloudZone
    }

    public var destination: String {
        username.isEmpty ? hostname : "\(username)@\(hostname)"
    }

    public static var local: SSHHost {
        SSHHost(
            id: localID,
            name: "This Mac",
            kind: .local,
            hostname: "localhost",
            username: NSUserName()
        )
    }

    public var isLocal: Bool {
        kind == .local
    }

    public func bridgeInvocation() throws -> ProcessInvocation {
        switch kind {
        case .local:
            return LocalRuntimePaths.live.bridgeInvocation
        case .ssh:
            guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SkepClientError.invalidHost("Enter an SSH hostname or IP address.")
            }
            var arguments = [
                "-T",
                "-p", String(port),
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=12",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=2",
            ]
            if !identityFile.isEmpty {
                arguments.append(contentsOf: ["-i", NSString(string: identityFile).expandingTildeInPath])
            }
            arguments.append(destination)
            arguments.append("/usr/bin/sudo")
            arguments.append("-n")
            arguments.append("/usr/local/bin/skepctl")
            arguments.append("bridge")
            return ProcessInvocation(executable: "/usr/bin/ssh", arguments: arguments)
        case .gcloudIAP:
            guard !gcloudInstance.isEmpty, !gcloudProject.isEmpty, !gcloudZone.isEmpty else {
                throw SkepClientError.invalidHost("Instance, project, and zone are required for Google Cloud IAP.")
            }
            let arguments = [
                "compute", "ssh", gcloudInstance,
                "--project", gcloudProject,
                "--zone", gcloudZone,
                "--tunnel-through-iap",
                "--command", "/usr/bin/sudo -n /usr/local/bin/skepctl bridge",
            ]
            var invocation = GCloudCLI.invocation(arguments)
            if !username.isEmpty {
                invocation.arguments.append("--ssh-flag=-l\(username)")
            }
            invocation.arguments.append("--ssh-flag=-T")
            return invocation
        }
    }

    public func noninteractiveCommandInvocation(_ remoteCommand: String) throws -> ProcessInvocation {
        switch kind {
        case .local:
            throw SkepClientError.invalidHost("Local setup commands do not use the remote SSH transport.")
        case .ssh:
            guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SkepClientError.invalidHost("Enter an SSH hostname or IP address.")
            }
            var arguments = [
                "-T",
                "-p", String(port),
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=12",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=2",
            ]
            if !identityFile.isEmpty {
                arguments.append(contentsOf: ["-i", NSString(string: identityFile).expandingTildeInPath])
            }
            arguments.append(destination)
            arguments.append(remoteCommand)
            return ProcessInvocation(executable: "/usr/bin/ssh", arguments: arguments)
        case .gcloudIAP:
            guard !gcloudInstance.isEmpty, !gcloudProject.isEmpty, !gcloudZone.isEmpty else {
                throw SkepClientError.invalidHost("Instance, project, and zone are required for Google Cloud IAP.")
            }
            let arguments = [
                "compute", "ssh", gcloudInstance,
                "--project", gcloudProject,
                "--zone", gcloudZone,
                "--tunnel-through-iap",
                "--command", remoteCommand,
            ]
            var invocation = GCloudCLI.invocation(arguments)
            if !username.isEmpty {
                invocation.arguments.append("--ssh-flag=-l\(username)")
            }
            invocation.arguments.append("--ssh-flag=-T")
            return invocation
        }
    }

    public func interactiveSSHArguments(remoteCommand: [String] = []) throws -> ProcessInvocation {
        switch kind {
        case .local:
            guard remoteCommand.isEmpty else {
                throw SkepClientError.invalidHost("Use workspaceShellInvocation for a local workspace terminal.")
            }
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return ProcessInvocation(executable: shell, arguments: ["-l"])
        case .ssh:
            guard !hostname.isEmpty else {
                throw SkepClientError.invalidHost("Enter an SSH hostname or IP address.")
            }
            var arguments = ["-p", String(port), "-o", "ServerAliveInterval=15"]
            if !remoteCommand.isEmpty {
                arguments.append("-tt")
            }
            if !identityFile.isEmpty {
                arguments.append(contentsOf: ["-i", NSString(string: identityFile).expandingTildeInPath])
            }
            arguments.append(destination)
            arguments.append(contentsOf: remoteCommand)
            return ProcessInvocation(executable: "/usr/bin/ssh", arguments: arguments)
        case .gcloudIAP:
            guard !gcloudInstance.isEmpty, !gcloudProject.isEmpty, !gcloudZone.isEmpty else {
                throw SkepClientError.invalidHost("Instance, project, and zone are required for Google Cloud IAP.")
            }
            let arguments = [
                "compute", "ssh", gcloudInstance,
                "--project", gcloudProject,
                "--zone", gcloudZone,
                "--tunnel-through-iap",
            ]
            var invocation = GCloudCLI.invocation(arguments)
            if !username.isEmpty {
                invocation.arguments.append("--ssh-flag=-l\(username)")
            }
            if !remoteCommand.isEmpty {
                invocation.arguments.append("--ssh-flag=-tt")
                invocation.arguments.append(contentsOf: ["--command", shellJoin(remoteCommand)])
            }
            return invocation
        }
    }


    public func workspaceShellInvocation(workspaceID: String) throws -> ProcessInvocation {
        if kind == .local {
            return LocalRuntimePaths.live.workspaceShellInvocation(workspaceID: workspaceID)
        }
        return try interactiveSSHArguments(
            remoteCommand: [
                "/usr/bin/sudo", "-n", "/usr/local/bin/skepctl", "workspace-shell", workspaceID,
            ]
        )
    }
}

public struct ProcessInvocation: Sendable, Equatable {
    public let executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public var shellCommand: String {
        shellJoin([executable] + arguments)
    }
}

public enum GCloudCLI {
    public static func invocation(_ arguments: [String]) -> ProcessInvocation {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/gcloud",
            "/usr/local/bin/gcloud",
            "\(home)/google-cloud-sdk/bin/gcloud",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/gcloud" })
        }
        if let executable = candidates.first(where: fileManager.isExecutableFile(atPath:)) {
            return ProcessInvocation(executable: executable, arguments: arguments)
        }
        return ProcessInvocation(executable: "/usr/bin/env", arguments: ["gcloud"] + arguments)
    }

    public static func authenticate() async throws {
        let command = authenticationInvocation()
        try await Task.detached(priority: .userInitiated) {
            try run(command)
        }.value
    }

    public static func authenticationInvocation() -> ProcessInvocation {
        invocation(["auth", "login", "--quiet", "--launch-browser"])
    }

    private static func run(_ invocation: ProcessInvocation) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        do {
            try process.run()
        } catch {
            throw SkepClientError.launchFailed(
                "Could not start Google Cloud authentication: \(error.localizedDescription)"
            )
        }
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = String(
            decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw SkepClientError.transportFailed(
                status: process.terminationStatus,
                message: diagnostic.isEmpty ? "Google Cloud authentication did not complete." : diagnostic
            )
        }
    }
}

private func shellJoin(_ arguments: [String]) -> String {
    arguments
        .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        .joined(separator: " ")
}
