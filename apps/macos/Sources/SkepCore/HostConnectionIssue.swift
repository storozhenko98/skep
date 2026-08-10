import Foundation

public enum HostConnectionIssueKind: String, Sendable, Equatable {
    case googleCloudAuthentication
    case googleCloudCLIUnavailable
    case permissionDenied
    case networkUnavailable
    case hostUnavailable
    case transportFailed
}
public struct HostConnectionIssue: Sendable, Equatable {
    public let kind: HostConnectionIssueKind
    public let diagnostic: String

    public init(kind: HostConnectionIssueKind, diagnostic: String) {
        self.kind = kind
        self.diagnostic = diagnostic
    }

    public var requiresGoogleCloudAuthentication: Bool {
        kind == .googleCloudAuthentication
    }

    public static func classify(host: SSHHost, diagnostic: String) -> HostConnectionIssue {
        let normalized = diagnostic.lowercased()

        if host.kind == .gcloudIAP {
            let authenticationMarkers = [
                "gcloud auth login",
                "reauthentication failed",
                "refreshing your current auth tokens",
                "cannot prompt during non-interactive execution",
                "credentials have expired",
                "invalid_grant",
                "login required",
            ]
            if authenticationMarkers.contains(where: normalized.contains) {
                return HostConnectionIssue(kind: .googleCloudAuthentication, diagnostic: diagnostic)
            }

            let missingCLIMarkers = [
                "gcloud: no such file",
                "gcloud: command not found",
                "unable to find executable gcloud",
            ]
            if missingCLIMarkers.contains(where: normalized.contains) {
                return HostConnectionIssue(kind: .googleCloudCLIUnavailable, diagnostic: diagnostic)
            }
        }

        let permissionMarkers = [
            "permission denied",
            "access denied",
            "not authorized",
            "accessviaiap",
            "error 403",
            "status 403",
        ]
        if permissionMarkers.contains(where: normalized.contains) {
            return HostConnectionIssue(kind: .permissionDenied, diagnostic: diagnostic)
        }

        let networkMarkers = [
            "network is unreachable",
            "no route to host",
            "could not resolve hostname",
            "temporary failure in name resolution",
            "connection timed out",
            "operation timed out",
        ]
        if networkMarkers.contains(where: normalized.contains) {
            return HostConnectionIssue(kind: .networkUnavailable, diagnostic: diagnostic)
        }

        let unavailableMarkers = [
            "connection refused",
            "connection closed",
            "connection reset",
            "failed to connect",
            "could not connect",
        ]
        if unavailableMarkers.contains(where: normalized.contains) {
            return HostConnectionIssue(kind: .hostUnavailable, diagnostic: diagnostic)
        }

        return HostConnectionIssue(kind: .transportFailed, diagnostic: diagnostic)
    }
}
