import Foundation

public let skepProtocolVersion = 1

public enum SkepMethod {
    public static let ping = "ping"
    public static let hostInfo = "host.info"
    public static let listWorkspaces = "workspace.list"
    public static let getWorkspace = "workspace.get"
    public static let createWorkspace = "workspace.create"
    public static let startWorkspace = "workspace.start"
    public static let stopWorkspace = "workspace.stop"
    public static let deleteWorkspace = "workspace.delete"
    public static let setAutostart = "workspace.setAutostart"
    public static let createBuilder = "builder.create"
    public static let bootstrapBuilder = "builder.bootstrap"
    public static let publishTemplate = "template.publish"
    public static let listTemplates = "template.list"
    public static let exportTemplate = "template.export"
    public static let deleteTemplate = "template.delete"
}

public struct EmptyParameters: Codable, Sendable {
    public init() {}
}

public struct RPCRequest<Parameters: Encodable & Sendable>: Encodable, Sendable {
    public let id: String
    public let version: Int
    public let method: String
    public let params: Parameters

    public init(id: String = UUID().uuidString, method: String, params: Parameters) {
        self.id = id
        self.version = skepProtocolVersion
        self.method = method
        self.params = params
    }
}

public struct RPCResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    public let id: String
    public let version: Int
    public let result: Result?
    public let error: RPCErrorPayload?
}

public struct RPCErrorPayload: Codable, Sendable, Equatable {
    public let code: String
    public let message: String
}

public enum SkepClientError: LocalizedError, Sendable {
    case invalidHost(String)
    case launchFailed(String)
    case transportFailed(status: Int32, message: String)
    case emptyResponse
    case invalidResponse(String)
    case protocolMismatch(Int)
    case remote(RPCErrorPayload)

    public var errorDescription: String? {
        switch self {
        case let .invalidHost(message), let .launchFailed(message), let .invalidResponse(message):
            message
        case let .transportFailed(status, message):
            "The Skep transport exited with status \(status): \(message)"
        case .emptyResponse:
            "The Skep service returned no response."
        case let .protocolMismatch(version):
            "The host uses Skep protocol \(version), but this app requires protocol \(skepProtocolVersion)."
        case let .remote(error):
            error.message
        }
    }

    public var remoteCode: String? {
        guard case let .remote(error) = self else { return nil }
        return error.code
    }
}

public struct ToolInfo: Codable, Sendable, Equatable {
    public let installed: Bool
    public let path: String?
    public let version: String?
}

public struct VirtualizationInfo: Codable, Sendable, Equatable {
    public let provider: String?
    public let cpuVirtualization: Bool
    public let kvmDevice: Bool
    public let kvmUsable: Bool
    public let kvmApiVersion: Int?
    public let reason: String?
}

public struct ResourceProfile: Codable, Sendable, Equatable {
    public var startingCpus: UInt8
    public var maximumCpus: UInt8
    public var startingMemoryMib: UInt32
    public var maximumMemoryMib: UInt32
    public var rootDiskMib: UInt32
    public var tmpfsMib: UInt32
    public var dockerVolumeMib: UInt32
    public var networkProfile: String
    public var dnsServers: [String]

    public init(
        startingCpus: UInt8 = 1,
        maximumCpus: UInt8 = 2,
        startingMemoryMib: UInt32 = 2048,
        maximumMemoryMib: UInt32 = 4096,
        rootDiskMib: UInt32 = 16_384,
        tmpfsMib: UInt32 = 1024,
        dockerVolumeMib: UInt32 = 20_480,
        networkProfile: String = "all",
        dnsServers: [String] = []
    ) {
        self.startingCpus = startingCpus
        self.maximumCpus = maximumCpus
        self.startingMemoryMib = startingMemoryMib
        self.maximumMemoryMib = maximumMemoryMib
        self.rootDiskMib = rootDiskMib
        self.tmpfsMib = tmpfsMib
        self.dockerVolumeMib = dockerVolumeMib
        self.networkProfile = networkProfile
        self.dnsServers = dnsServers
    }
}

public struct HostInfo: Codable, Sendable, Equatable {
    public let daemonVersion: String
    public let protocolVersion: Int
    public let hostname: String
    public let operatingSystem: String
    public let operatingSystemVersion: String
    public let kernel: String
    public let architecture: String
    public let cpuCount: UInt32
    public let totalMemoryMib: UInt64
    public let availableMemoryMib: UInt64
    public let rootDiskTotalMib: UInt64
    public let rootDiskAvailableMib: UInt64
    public let systemd: Bool
    public let ipv4: Bool
    public let ipv6: Bool
    public let virtualization: VirtualizationInfo
    public let microsandbox: ToolInfo
    public let suggestedProfile: ResourceProfile
}

public enum WorkspaceKind: String, Codable, Sendable {
    case builder
    case workspace
}

public enum WorkspaceStatus: String, Codable, Sendable {
    case creating
    case running
    case stopped
    case error
}

public struct Workspace: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let generation: UInt64
    public let name: String
    public let runtimeName: String
    public let kind: WorkspaceKind
    public let status: WorkspaceStatus
    public let desiredStatus: WorkspaceStatus
    public let templateId: String?
    public let image: String?
    public let dockerVolume: String
    public let resources: ResourceProfile
    public let autostart: Bool
    public let createdAt: UInt64
    public let updatedAt: UInt64
    public let lastError: String?
    public let toolsInstalled: Bool?
}

public struct Template: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let generation: UInt64
    public let name: String
    public let snapshotName: String
    public let sourceWorkspaceId: String
    public let resources: ResourceProfile
    public let createdAt: UInt64
    public let updatedAt: UInt64
    public let verified: Bool
}

public struct PingResult: Codable, Sendable {
    public let ok: Bool
    public let daemonVersion: String
    public let protocolVersion: Int
}

public struct DeleteResult: Codable, Sendable {
    public let deleted: Bool
}

public struct CreateBuilderParameters: Codable, Sendable {
    public let name: String
    public let image: String
    public let resources: ResourceProfile

    public init(name: String, image: String, resources: ResourceProfile) {
        self.name = name
        self.image = image
        self.resources = resources
    }
}

public struct WorkspaceIDParameters: Codable, Sendable {
    public let workspaceId: String
    public let expectedGeneration: UInt64?

    public init(workspaceId: String, expectedGeneration: UInt64? = nil) {
        self.workspaceId = workspaceId
        self.expectedGeneration = expectedGeneration
    }
}

public struct PublishTemplateParameters: Codable, Sendable {
    public let workspaceId: String
    public let name: String
    public let expectedGeneration: UInt64?

    public init(workspaceId: String, name: String, expectedGeneration: UInt64? = nil) {
        self.workspaceId = workspaceId
        self.name = name
        self.expectedGeneration = expectedGeneration
    }
}

public struct CreateWorkspaceParameters: Codable, Sendable {
    public let templateId: String
    public let name: String
    public let resources: ResourceProfile?
    public let autostart: Bool

    public init(templateId: String, name: String, resources: ResourceProfile? = nil, autostart: Bool) {
        self.templateId = templateId
        self.name = name
        self.resources = resources
        self.autostart = autostart
    }
}

public struct DeleteWorkspaceParameters: Codable, Sendable {
    public let workspaceId: String
    public let expectedGeneration: UInt64?
    public let deleteVolumes: Bool

    public init(workspaceId: String, expectedGeneration: UInt64? = nil, deleteVolumes: Bool = true) {
        self.workspaceId = workspaceId
        self.expectedGeneration = expectedGeneration
        self.deleteVolumes = deleteVolumes
    }
}

public struct SetAutostartParameters: Codable, Sendable {
    public let workspaceId: String
    public let autostart: Bool
    public let expectedGeneration: UInt64?

    public init(workspaceId: String, autostart: Bool, expectedGeneration: UInt64? = nil) {
        self.workspaceId = workspaceId
        self.autostart = autostart
        self.expectedGeneration = expectedGeneration
    }
}

public struct ExportTemplateParameters: Codable, Sendable {
    public let templateId: String
    public let outputName: String?

    public init(templateId: String, outputName: String? = nil) {
        self.templateId = templateId
        self.outputName = outputName
    }
}

public struct DeleteTemplateParameters: Codable, Sendable {
    public let templateId: String
    public let expectedGeneration: UInt64?

    public init(templateId: String, expectedGeneration: UInt64? = nil) {
        self.templateId = templateId
        self.expectedGeneration = expectedGeneration
    }
}

public struct ExportResult: Codable, Sendable {
    public let path: String
    public let templateId: String
}
