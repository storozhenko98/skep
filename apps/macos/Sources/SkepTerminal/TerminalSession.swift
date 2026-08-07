import Foundation
import SkepCore

public struct TerminalSession: Identifiable, Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case host
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
        case let .workspace(_, name): "\(name) — workspace terminal"
        }
    }

    public func invocation() throws -> ProcessInvocation {
        switch target {
        case .host:
            try host.interactiveSSHArguments()
        case let .workspace(id, _):
            try host.workspaceShellInvocation(workspaceID: id)
        }
    }
}
