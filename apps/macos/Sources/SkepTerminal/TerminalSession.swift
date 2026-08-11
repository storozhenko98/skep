import Foundation
import SkepCore

public struct TerminalSession: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case host
        case builder(id: String, name: String)
        case workspace(id: String, name: String)
    }

    public let id: UUID
    public let host: SSHHost
    public let target: Target

    public init(id: UUID = UUID(), host: SSHHost, target: Target) {
        self.id = id
        self.host = host
        self.target = target
    }

    public var title: String {
        switch target {
        case .host: "\(host.name) — host terminal"
        case let .builder(_, name): "\(name) — builder terminal"
        case let .workspace(_, name): "\(name) — workspace terminal"
        }
    }

    public var contextLabel: String {
        switch target {
        case .host: "HOST SHELL"
        case .builder: "BUILDER SHELL"
        case .workspace: "WORKSPACE SHELL"
        }
    }

    public var workspaceID: String? {
        switch target {
        case .host: nil
        case let .builder(id, _), let .workspace(id, _): id
        }
    }

    public func matches(hostID: UUID, workspaceID: String) -> Bool {
        host.id == hostID && self.workspaceID == workspaceID
    }

    public func restarted() -> TerminalSession {
        TerminalSession(host: host, target: target)
    }

    public func invocation() throws -> ProcessInvocation {
        switch target {
        case .host:
            try host.interactiveSSHArguments()
        case let .builder(id, _), let .workspace(id, _):
            try host.workspaceShellInvocation(workspaceID: id)
        }
    }
}
