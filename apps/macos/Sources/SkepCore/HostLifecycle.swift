@preconcurrency import Foundation

public enum HostServiceState: String, Sendable {
    case notInstalled
    case incomplete
    case stopped
    case ready
}

public struct HostPreflight: Equatable, Sendable {
    public let hostname: String
    public let operatingSystem: String
    public let operatingSystemVersion: String
    public let architecture: String
    public let systemd: Bool
    public let skepctlInstalled: Bool
    public let skepdInstalled: Bool
    public let skepctlSHA256: String?
    public let skepdSHA256: String?
    public let daemonActive: Bool
    public let daemonSocket: Bool
    public let microsandboxInstalled: Bool
    public let cpuVirtualization: Bool
    public let kvmDevice: Bool
    public let passwordlessSudo: Bool

    public var serviceState: HostServiceState {
        if !skepctlInstalled && !skepdInstalled {
            return .notInstalled
        }
        if !skepctlInstalled || !skepdInstalled {
            return .incomplete
        }
        if daemonActive && daemonSocket {
            return .ready
        }
        return .stopped
    }

    public var supportsAutomaticInstall: Bool {
        operatingSystem == "ubuntu"
            && operatingSystemVersion == "24.04"
            && architecture == "x86_64"
            && systemd
            && passwordlessSudo
    }

    public var supportsAutomaticUpdate: Bool {
        architecture == "x86_64"
            && systemd
            && passwordlessSudo
    }

    static func parse(_ data: Data) throws -> HostPreflight {
        let output = String(decoding: data, as: UTF8.self)
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \Character.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        guard fields["skep_preflight"] == "1" else {
            throw HostLifecycleError.invalidPreflight(output)
        }

        func flag(_ name: String) -> Bool {
            fields[name] == "1"
        }

        return HostPreflight(
            hostname: fields["hostname"] ?? "unknown",
            operatingSystem: fields["os_id"] ?? "unknown",
            operatingSystemVersion: fields["os_version"] ?? "unknown",
            architecture: fields["architecture"] ?? "unknown",
            systemd: flag("systemd"),
            skepctlInstalled: flag("skepctl"),
            skepdInstalled: flag("skepd"),
            skepctlSHA256: fields["skepctl_sha256"].flatMap { $0.isEmpty ? nil : $0 },
            skepdSHA256: fields["skepd_sha256"].flatMap { $0.isEmpty ? nil : $0 },
            daemonActive: flag("daemon_active"),
            daemonSocket: flag("daemon_socket"),
            microsandboxInstalled: flag("microsandbox"),
            cpuVirtualization: flag("cpu_virtualization"),
            kvmDevice: flag("kvm_device"),
            passwordlessSudo: flag("passwordless_sudo")
        )
    }
}

public enum HostLifecycleError: LocalizedError, Sendable {
    case invalidPreflight(String)
    case missingPayload(String)
    case payloadArchive(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPreflight(let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "The host did not return a valid Skep preflight response."
                : "The host returned an invalid Skep preflight response: \(detail)"
        case .missingPayload(let detail):
            return "The Skep Linux installer payload is unavailable. \(detail)"
        case .payloadArchive(let detail):
            return "Could not prepare the Skep Linux installer: \(detail)"
        }
    }
}

public struct HostLifecycleClient: Sendable {
    public let host: SSHHost

    public init(host: SSHHost) {
        self.host = host
    }

    public func inspect() async throws -> HostPreflight {
        let invocation = try host.noninteractiveCommandInvocation(Self.preflightCommand)
        let output = try await Task.detached(priority: .userInitiated) {
            try Self.run(invocation: invocation)
        }.value
        return try HostPreflight.parse(output)
    }

    public func install(payloadDirectory: URL) async throws {
        let invocation = try host.noninteractiveCommandInvocation(Self.installCommand)
        try await Task.detached(priority: .userInitiated) {
            let archive = try Self.makePayloadArchive(from: payloadDirectory)
            _ = try Self.run(invocation: invocation, input: archive)
        }.value
    }

    public func update(payloadDirectory: URL) async throws {
        let invocation = try host.noninteractiveCommandInvocation(Self.updateCommand)
        try await Task.detached(priority: .userInitiated) {
            let archive = try Self.makePayloadArchive(from: payloadDirectory)
            _ = try Self.run(invocation: invocation, input: archive)
        }.value
    }

    public func updateRequired(
        preflight: HostPreflight,
        payloadDirectory: URL
    ) throws -> Bool {
        let identity = try Self.payloadIdentity(from: payloadDirectory)
        return preflight.skepctlSHA256 != identity.skepctl
            || preflight.skepdSHA256 != identity.skepd
    }

    public func remove(payloadDirectory: URL) async throws {
        let invocation = try host.noninteractiveCommandInvocation(Self.removeCommand)
        try await Task.detached(priority: .userInitiated) {
            let archive = try Self.makePayloadArchive(from: payloadDirectory)
            _ = try Self.run(invocation: invocation, input: archive)
        }.value
    }

    static let payloadFiles = [
        "skepd",
        "skepctl",
        "skepd.service",
        "install.sh",
        "install-microsandbox.sh",
        "uninstall.sh",
        "SHA256SUMS",
    ]

    static let preflightCommand = #"""
    set -u
    os_id=unknown
    os_version=unknown
    if [ -r /etc/os-release ]; then
      . /etc/os-release
      os_id=${ID:-unknown}
      os_version=${VERSION_ID:-unknown}
    fi
    check() { if "$@" >/dev/null 2>&1; then printf '1'; else printf '0'; fi; }
    checksum() {
      if [ -f "$1" ] && command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
      fi
    }
    daemon_socket=0
    microsandbox=0
    if [ -x /usr/local/bin/skepctl ]; then
      bridge_ping=$(printf '%s\n' '{"id":"skep-preflight-ping","version":1,"method":"ping","params":{}}' | sudo -n /usr/local/bin/skepctl bridge 2>/dev/null || true)
      if printf '%s' "$bridge_ping" | grep -q '"ok":true'; then
        daemon_socket=1
      fi
      bridge_info=$(printf '%s\n' '{"id":"skep-preflight-info","version":1,"method":"host.info","params":{}}' | sudo -n /usr/local/bin/skepctl bridge 2>/dev/null || true)
      if printf '%s' "$bridge_info" | grep -q '"microsandbox":{"installed":true'; then
        microsandbox=1
      fi
    fi
    printf 'skep_preflight=1\n'
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || printf unknown)"
    printf 'os_id=%s\n' "$os_id"
    printf 'os_version=%s\n' "$os_version"
    printf 'architecture=%s\n' "$(uname -m 2>/dev/null || printf unknown)"
    printf 'systemd=%s\n' "$(check command -v systemctl)"
    printf 'skepctl=%s\n' "$(check test -x /usr/local/bin/skepctl)"
    printf 'skepd=%s\n' "$(check test -x /usr/local/bin/skepd)"
    printf 'skepctl_sha256=%s\n' "$(checksum /usr/local/bin/skepctl)"
    printf 'skepd_sha256=%s\n' "$(checksum /usr/local/bin/skepd)"
    printf 'daemon_active=%s\n' "$(check systemctl is-active --quiet skepd.service)"
    printf 'daemon_socket=%s\n' "$daemon_socket"
    printf 'microsandbox=%s\n' "$microsandbox"
    printf 'cpu_virtualization=%s\n' "$(check grep -Eq '(^| )(vmx|svm)( |$)' /proc/cpuinfo)"
    printf 'kvm_device=%s\n' "$(check test -c /dev/kvm)"
    printf 'passwordless_sudo=%s\n' "$(check sudo -n true)"
    """#

    static let installCommand = #"""
    set -eu
    umask 077
    install_root=$(mktemp -d /tmp/skep-bootstrap.XXXXXX)
    cleanup() { rm -rf "$install_root"; }
    trap cleanup EXIT HUP INT TERM
    tar -xzf - -C "$install_root"
    (cd "$install_root" && sha256sum -c SHA256SUMS)
    operator_name=$(id -un)
    if ! command -v curl >/dev/null 2>&1; then
      sudo -n apt-get update
      sudo -n apt-get install -y curl ca-certificates
    fi
    sudo -n "$install_root/install-microsandbox.sh"
    sudo -n env SKEP_OPERATOR="$operator_name" "$install_root/install.sh" "$install_root"
    """#

    static let updateCommand = #"""
    set -eu
    umask 077
    install_root=$(mktemp -d /tmp/skep-update.XXXXXX)
    cleanup() { rm -rf "$install_root"; }
    trap cleanup EXIT HUP INT TERM
    tar -xzf - -C "$install_root"
    (cd "$install_root" && sha256sum -c SHA256SUMS)
    operator_name=$(id -un)
    sudo -n env SKEP_OPERATOR="$operator_name" "$install_root/install.sh" "$install_root"
    """#

    static let removeCommand = #"""
    set -eu
    umask 077
    install_root=$(mktemp -d /tmp/skep-bootstrap.XXXXXX)
    cleanup() { rm -rf "$install_root"; }
    trap cleanup EXIT HUP INT TERM
    tar -xzf - -C "$install_root"
    (cd "$install_root" && sha256sum -c SHA256SUMS)
    sudo -n "$install_root/uninstall.sh"
    """#

    private static func makePayloadArchive(from directory: URL) throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw HostLifecycleError.missingPayload("Expected a directory at \(directory.path).")
        }
        for file in payloadFiles where !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(file).path
        ) {
            throw HostLifecycleError.missingPayload("Missing \(file) in \(directory.path).")
        }

        let invocation = ProcessInvocation(
            executable: "/usr/bin/tar",
            arguments: ["-czf", "-", "-C", directory.path] + payloadFiles
        )
        do {
            return try run(invocation: invocation)
        } catch {
            throw HostLifecycleError.payloadArchive(error.localizedDescription)
        }
    }

    private struct PayloadIdentity {
        let skepctl: String
        let skepd: String
    }

    private static func payloadIdentity(from directory: URL) throws -> PayloadIdentity {
        let manifestURL = directory.appendingPathComponent("SHA256SUMS")
        guard let contents = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw HostLifecycleError.missingPayload("Could not read \(manifestURL.path).")
        }
        var checksums: [String: String] = [:]
        for line in contents.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2 else { continue }
            checksums[String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))] = String(fields[0])
        }
        guard let skepctl = checksums["skepctl"], let skepd = checksums["skepd"] else {
            throw HostLifecycleError.missingPayload("SHA256SUMS does not identify skepctl and skepd.")
        }
        return PayloadIdentity(skepctl: skepctl, skepd: skepd)
    }

    private static func run(invocation: ProcessInvocation, input: Data = Data()) throws -> Data {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw SkepClientError.launchFailed("Could not start \(invocation.executable): \(error.localizedDescription)")
        }
        if !input.isEmpty {
            stdin.fileHandleForWriting.write(input)
        }
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SkepClientError.transportFailed(status: process.terminationStatus, message: message)
        }
        return output
    }
}
