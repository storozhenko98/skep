@preconcurrency import Foundation
import CryptoKit

public enum LocalRuntimeState: String, Sendable {
    case unsupported
    case notInstalled
    case incomplete
    case stopped
    case ready
}

public struct LocalRuntimeStatus: Equatable, Sendable {
    public let state: LocalRuntimeState
    public let architecture: String
    public let skepctlInstalled: Bool
    public let skepdInstalled: Bool
    public let microsandboxInstalled: Bool
    public let daemonSocket: Bool
    public let microsandboxVersion: String?
    public let configurationUsable: Bool
    public let configurationIssue: String?

    public var supported: Bool { state != .unsupported }
}

public struct LocalRuntimePaths: Sendable, Equatable {
    public let root: URL
    private let configuredMicrosandboxHome: URL?

    public init(root: URL, microsandboxHome: URL? = nil) {
        self.root = root
        configuredMicrosandboxHome = microsandboxHome
    }

    public static var live: LocalRuntimePaths {
        if let override = ProcessInfo.processInfo.environment["SKEP_LOCAL_ROOT"], !override.isEmpty {
            let microsandboxHome = ProcessInfo.processInfo.environment["SKEP_LOCAL_MSB_HOME"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            return LocalRuntimePaths(
                root: URL(fileURLWithPath: override, isDirectory: true),
                microsandboxHome: microsandboxHome
            )
        }
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let microsandboxHome = ProcessInfo.processInfo.environment["SKEP_LOCAL_MSB_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".skep/msb", isDirectory: true)
        return LocalRuntimePaths(
            root: applicationSupport.appendingPathComponent("Skep/Local", isDirectory: true),
            microsandboxHome: microsandboxHome
        )
    }

    public var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var runtimeDirectory: URL { root.appendingPathComponent("microsandbox", isDirectory: true) }
    public var runDirectory: URL { root.appendingPathComponent("run", isDirectory: true) }
    public var stateDirectory: URL { root.appendingPathComponent("state", isDirectory: true) }
    public var legacyMicrosandboxHome: URL { stateDirectory.appendingPathComponent("microsandbox", isDirectory: true) }
    public var microsandboxHome: URL { configuredMicrosandboxHome ?? legacyMicrosandboxHome }
    public var skepctl: URL { binDirectory.appendingPathComponent("skepctl") }
    public var skepd: URL { binDirectory.appendingPathComponent("skepd") }
    public var microsandbox: URL { runtimeDirectory.appendingPathComponent("msb") }
    public var microsandboxLibrary: URL { runtimeDirectory.appendingPathComponent("libkrunfw.5.dylib") }
    public var socket: URL { runDirectory.appendingPathComponent("skepd.sock") }
    public var pidFile: URL { runDirectory.appendingPathComponent("skepd.pid") }
    public var daemonConfigurationFile: URL { runDirectory.appendingPathComponent("daemon-config") }
    public var logFile: URL { root.appendingPathComponent("skepd.log") }

    /// Microsandbox 0.6.8 uses `<MSB_HOME>/run/agent/<32 hex chars>.sock`.
    /// Darwin's `sockaddr_un.sun_path` is 104 bytes including its terminator.
    public var agentRelaySocketProbe: URL {
        microsandboxHome
            .appendingPathComponent("run/agent", isDirectory: true)
            .appendingPathComponent(String(repeating: "0", count: 32) + ".sock")
    }

    public var agentRelaySocketPathFits: Bool {
        agentRelaySocketProbe.path.utf8.count < 104
    }

    public var daemonConfiguration: String {
        "msb-home=\(microsandboxHome.standardizedFileURL.path)\n"
    }

    public var bridgeInvocation: ProcessInvocation {
        ProcessInvocation(
            executable: skepctl.path,
            arguments: controlArguments + ["bridge"]
        )
    }

    public func workspaceShellInvocation(workspaceID: String) -> ProcessInvocation {
        ProcessInvocation(
            executable: skepctl.path,
            arguments: controlArguments + ["workspace-shell", workspaceID]
        )
    }

    private var controlArguments: [String] {
        [
            "--socket", socket.path,
            "--microsandbox-bin", microsandbox.path,
            "--microsandbox-home", microsandboxHome.path,
        ]
    }
}

public enum LocalRuntimeError: LocalizedError, Sendable {
    case unsupportedArchitecture(String)
    case missingPayload(String)
    case download(String)
    case checksumMismatch
    case installation(String)
    case launch(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture(let architecture):
            "Local workspaces require an Apple Silicon Mac. This Mac reports \(architecture)."
        case .missingPayload(let message):
            "The local Skep helper payload is unavailable. \(message)"
        case .download(let message):
            "Could not download the pinned Microsandbox runtime: \(message)"
        case .checksumMismatch:
            "The downloaded Microsandbox archive did not match Skep's pinned checksum."
        case .installation(let message):
            "Could not install the local runtime: \(message)"
        case .launch(let message):
            "Could not start the local Skep service: \(message)"
        }
    }
}

public struct LocalHostLifecycleClient: Sendable {
    public static let microsandboxVersion = "0.6.8"
    public static let microsandboxArchiveSHA256 = "f92acaeee1fefd5271997bf0e522600d32b4a372796d1e0f00e229f9a8ff0890"
    public static let microsandboxArchiveURL = URL(
        string: "https://github.com/superradcompany/microsandbox/releases/download/v0.6.8/microsandbox-darwin-aarch64.tar.gz"
    )!

    public let paths: LocalRuntimePaths

    public init(paths: LocalRuntimePaths = .live) {
        self.paths = paths
    }

    public func inspect() async -> LocalRuntimeStatus {
        await Task.detached(priority: .userInitiated) {
            let architecture = Self.architecture()
            let fileManager = FileManager.default
            let skepctlInstalled = fileManager.isExecutableFile(atPath: paths.skepctl.path)
            let skepdInstalled = fileManager.isExecutableFile(atPath: paths.skepd.path)
            let microsandboxInstalled = fileManager.isExecutableFile(atPath: paths.microsandbox.path)
                && fileManager.fileExists(atPath: paths.microsandboxLibrary.path)
            let daemonSocket = Self.daemonAvailable(paths)
            let configurationUsable = paths.agentRelaySocketPathFits
            let configurationIssue = configurationUsable ? nil :
                "Microsandbox would create a \(paths.agentRelaySocketProbe.path.utf8.count)-byte agent socket path, but macOS requires fewer than 104 bytes."
            let version = microsandboxInstalled
                ? try? Self.run(
                    ProcessInvocation(executable: paths.microsandbox.path, arguments: ["--version"]),
                    environment: ["DYLD_LIBRARY_PATH": paths.runtimeDirectory.path]
                )
                : nil

            let state: LocalRuntimeState
            if architecture != "arm64" {
                state = .unsupported
            } else if !skepctlInstalled && !skepdInstalled && !microsandboxInstalled {
                state = .notInstalled
            } else if !skepctlInstalled || !skepdInstalled || !microsandboxInstalled {
                state = .incomplete
            } else if !configurationUsable {
                state = .incomplete
            } else if !daemonSocket {
                state = .stopped
            } else {
                state = .ready
            }
            return LocalRuntimeStatus(
                state: state,
                architecture: architecture,
                skepctlInstalled: skepctlInstalled,
                skepdInstalled: skepdInstalled,
                microsandboxInstalled: microsandboxInstalled,
                daemonSocket: daemonSocket,
                microsandboxVersion: version?.trimmingCharacters(in: .whitespacesAndNewlines),
                configurationUsable: configurationUsable,
                configurationIssue: configurationIssue
            )
        }.value
    }

    public func install() async throws {
        let architecture = Self.architecture()
        guard architecture == "arm64" else {
            throw LocalRuntimeError.unsupportedArchitecture(architecture)
        }
        let payload = try Self.payloadDirectory()
        let paths = paths
        let archiveURL = Self.microsandboxArchiveURL

        do {
            let (downloadedURL, response) = try await URLSession.shared.download(from: archiveURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LocalRuntimeError.download("The server returned HTTP \(http.statusCode).")
            }
            let digest = try Self.sha256(downloadedURL)
            guard digest == Self.microsandboxArchiveSHA256 else {
                throw LocalRuntimeError.checksumMismatch
            }

            try await Task.detached(priority: .userInitiated) {
                let fileManager = FileManager.default
                let staging = fileManager.temporaryDirectory
                    .appendingPathComponent("skep-local-\(UUID().uuidString)", isDirectory: true)
                defer { try? fileManager.removeItem(at: staging) }
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
                _ = try Self.run(ProcessInvocation(
                    executable: "/usr/bin/tar",
                    arguments: ["-xzf", downloadedURL.path, "-C", staging.path]
                ))

                let stagedMSB = staging.appendingPathComponent("msb")
                let stagedLibrary = staging.appendingPathComponent("libkrunfw.5.dylib")
                for required in [payload.appendingPathComponent("skepctl"), payload.appendingPathComponent("skepd"), stagedMSB, stagedLibrary] {
                    guard fileManager.fileExists(atPath: required.path) else {
                        throw LocalRuntimeError.installation("Missing \(required.lastPathComponent) from the signed or downloaded payload.")
                    }
                }

                Self.stopDaemon(paths)
                try fileManager.createDirectory(at: paths.binDirectory, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: paths.runtimeDirectory, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: paths.runDirectory, withIntermediateDirectories: true)
                try Self.prepareMicrosandboxStorage(paths)
                try Self.replace(payload.appendingPathComponent("skepctl"), at: paths.skepctl)
                try Self.replace(payload.appendingPathComponent("skepd"), at: paths.skepd)
                try Self.replace(stagedMSB, at: paths.microsandbox)
                try Self.replace(stagedLibrary, at: paths.microsandboxLibrary)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.skepctl.path)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.skepd.path)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.microsandbox.path)
                try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.microsandboxLibrary.path)

                let version = try Self.run(
                    ProcessInvocation(executable: paths.microsandbox.path, arguments: ["--version"]),
                    environment: ["DYLD_LIBRARY_PATH": paths.runtimeDirectory.path]
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard version == "msb \(Self.microsandboxVersion)" else {
                    throw LocalRuntimeError.installation("Expected msb \(Self.microsandboxVersion), received \(version).")
                }
            }.value
            try await ensureRunning()
        } catch let error as LocalRuntimeError {
            throw error
        } catch {
            throw LocalRuntimeError.installation(error.localizedDescription)
        }
    }

    public func ensureRunning() async throws {
        let status = await inspect()
        guard status.supported else {
            throw LocalRuntimeError.unsupportedArchitecture(status.architecture)
        }
        guard status.skepctlInstalled, status.skepdInstalled, status.microsandboxInstalled else {
            throw LocalRuntimeError.installation("Install the local runtime before starting it.")
        }
        if status.daemonSocket { return }

        let paths = paths
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            Self.stopDaemon(paths)
            try fileManager.createDirectory(at: paths.runDirectory, withIntermediateDirectories: true)
            try Self.prepareMicrosandboxStorage(paths)
            if fileManager.fileExists(atPath: paths.socket.path) {
                try fileManager.removeItem(at: paths.socket)
            }
            if !fileManager.fileExists(atPath: paths.logFile.path) {
                fileManager.createFile(atPath: paths.logFile.path, contents: nil)
            }
            let logHandle = try FileHandle(forWritingTo: paths.logFile)
            try logHandle.seekToEnd()

            let process = Process()
            process.executableURL = paths.skepd
            process.arguments = [
                "--socket", paths.socket.path,
                "--state-dir", paths.stateDirectory.path,
                "--microsandbox-bin", paths.microsandbox.path,
                "--allow-native-virtualization",
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["MSB_HOME"] = paths.microsandboxHome.path
            environment["DYLD_LIBRARY_PATH"] = paths.runtimeDirectory.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = logHandle
            process.standardError = logHandle
            do {
                try process.run()
            } catch {
                throw LocalRuntimeError.launch(error.localizedDescription)
            }
            try String(process.processIdentifier).write(to: paths.pidFile, atomically: true, encoding: .utf8)
            try paths.daemonConfiguration.write(
                to: paths.daemonConfigurationFile,
                atomically: true,
                encoding: .utf8
            )
        }.value

        for _ in 0..<50 {
            if Self.daemonAvailable(paths) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let detail = (try? String(contentsOf: paths.logFile, encoding: .utf8))?
            .split(separator: "\n").suffix(4).joined(separator: "\n")
        throw LocalRuntimeError.launch(detail ?? "The control socket did not appear within five seconds.")
    }

    /// Keeps an already-installed local control plane aligned with the app bundle.
    /// Runtime data and Microsandbox itself are left untouched.
    public func updateBundledHelpersIfNeeded() async throws -> Bool {
        let status = await inspect()
        guard status.skepctlInstalled, status.skepdInstalled,
              let payload = try? Self.payloadDirectory() else {
            return false
        }

        let bundledSkepctl = payload.appendingPathComponent("skepctl")
        let bundledSkepd = payload.appendingPathComponent("skepd")
        let paths = paths
        let needsUpdate = try await Task.detached(priority: .userInitiated) {
            try Self.sha256(bundledSkepctl) != Self.sha256(paths.skepctl)
                || Self.sha256(bundledSkepd) != Self.sha256(paths.skepd)
        }.value
        guard needsUpdate else { return false }

        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            Self.stopDaemon(paths)
            try Self.replace(bundledSkepctl, at: paths.skepctl)
            try Self.replace(bundledSkepd, at: paths.skepd)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.skepctl.path)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.skepd.path)
        }.value
        try await ensureRunning()
        return true
    }

    public func remove() async throws {
        let paths = paths
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            Self.stopDaemon(paths)
            for target in [paths.binDirectory, paths.runtimeDirectory, paths.runDirectory] {
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
            }
        }.value
    }

    private static func payloadDirectory() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SKEP_LOCAL_HOST_PAYLOAD_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("LocalHostInstaller", isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("../../artifacts/local-host-installer", isDirectory: true)
                .standardizedFileURL
        )
        guard let payload = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.appendingPathComponent("skepd").path)
                && fileManager.isExecutableFile(atPath: $0.appendingPathComponent("skepctl").path)
        }) else {
            throw LocalRuntimeError.missingPayload(
                "Package Skep.app with scripts/package-macos.sh, or set SKEP_LOCAL_HOST_PAYLOAD_DIR for development."
            )
        }
        return payload
    }

    private static func architecture() -> String {
        (try? run(ProcessInvocation(executable: "/usr/bin/uname", arguments: ["-m"])))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    private static func sha256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func replace(_ source: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func isSocket(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeSocket
    }

    private static func daemonAvailable(_ paths: LocalRuntimePaths) -> Bool {
        guard isSocket(paths.socket),
              let daemonConfiguration = try? String(contentsOf: paths.daemonConfigurationFile, encoding: .utf8),
              daemonConfiguration == paths.daemonConfiguration,
              let pidText = try? String(contentsOf: paths.pidFile, encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              let command = try? run(ProcessInvocation(
                executable: "/bin/ps",
                arguments: ["-p", String(pid), "-o", "command="]
              )) else {
            return false
        }
        return command.contains(paths.skepd.path)
    }

    private static func prepareMicrosandboxStorage(_ paths: LocalRuntimePaths) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.stateDirectory, withIntermediateDirectories: true)

        let legacy = paths.legacyMicrosandboxHome.standardizedFileURL
        let destination = paths.microsandboxHome.standardizedFileURL
        guard legacy != destination else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyExists = fileManager.fileExists(atPath: legacy.path)
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        if legacyExists && !destinationExists {
            try fileManager.moveItem(at: legacy, to: destination)
        } else if legacyExists && destinationExists {
            let legacyEmpty = try fileManager.contentsOfDirectory(atPath: legacy.path).isEmpty
            let destinationEmpty = try fileManager.contentsOfDirectory(atPath: destination.path).isEmpty
            if legacyEmpty {
                try fileManager.removeItem(at: legacy)
            } else if destinationEmpty {
                try fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: legacy, to: destination)
            } else {
                throw LocalRuntimeError.installation(
                    "Both \(legacy.path) and \(destination.path) contain Microsandbox data. Skep will not merge them automatically."
                )
            }
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    private static func stopDaemon(_ paths: LocalRuntimePaths) {
        let fileManager = FileManager.default
        defer {
            try? fileManager.removeItem(at: paths.pidFile)
            try? fileManager.removeItem(at: paths.socket)
        }
        guard let pidText = try? String(contentsOf: paths.pidFile, encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              let command = try? run(ProcessInvocation(
                executable: "/bin/ps",
                arguments: ["-p", String(pid), "-o", "command="]
              )),
              command.contains(paths.skepd.path) else {
            return
        }
        _ = try? run(ProcessInvocation(executable: "/bin/kill", arguments: [String(pid)]))
        for _ in 0..<20 {
            let stillRunning = (try? run(ProcessInvocation(
                executable: "/bin/ps",
                arguments: ["-p", String(pid), "-o", "command="]
            )))?.contains(paths.skepd.path) == true
            if !stillRunning { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func run(
        _ invocation: ProcessInvocation,
        environment additions: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.standardOutput = stdout
        process.standardError = stderr
        if !additions.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }
        }
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalRuntimeError.installation(message.isEmpty ? "Process exited with status \(process.terminationStatus)." : message)
        }
        return String(decoding: output, as: UTF8.self)
    }
}
