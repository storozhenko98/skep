@preconcurrency import Foundation

public struct SSHClient: Sendable {
    public let host: SSHHost

    public init(host: SSHHost) {
        self.host = host
    }

    public func call<Parameters, Result>(
        _ method: String,
        params: Parameters,
        result: Result.Type = Result.self
    ) async throws -> Result
    where Parameters: Encodable & Sendable, Result: Decodable & Sendable {
        let request = RPCRequest(method: method, params: params)
        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        let invocation = try host.bridgeInvocation()
        let output = try await Task.detached(priority: .userInitiated) {
            try Self.run(invocation: invocation, input: payload)
        }.value
        guard let line = output.split(separator: 0x0A).first, !line.isEmpty else {
            throw SkepClientError.emptyResponse
        }
        let response: RPCResponse<Result>
        do {
            response = try JSONDecoder().decode(RPCResponse<Result>.self, from: Data(line))
        } catch {
            let text = String(decoding: line, as: UTF8.self)
            throw SkepClientError.invalidResponse("Invalid response from \(host.name): \(text)")
        }
        guard response.version == skepProtocolVersion else {
            throw SkepClientError.protocolMismatch(response.version)
        }
        if let error = response.error {
            throw SkepClientError.remote(error)
        }
        guard let result = response.result else {
            throw SkepClientError.invalidResponse("The daemon response did not contain a result.")
        }
        return result
    }

    private static func run(invocation: ProcessInvocation, input: Data) throws -> Data {
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
            throw SkepClientError.launchFailed("Could not start the SSH client: \(error.localizedDescription)")
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SkepClientError.transportFailed(status: process.terminationStatus, message: message)
        }
        return output
    }
}
