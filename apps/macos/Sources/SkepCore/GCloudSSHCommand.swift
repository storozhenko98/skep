import Foundation

public struct GCloudSSHCommand: Equatable, Sendable {
    public let instance: String
    public let project: String
    public let zone: String
    public let username: String?

    public init(instance: String, project: String, zone: String, username: String? = nil) {
        self.instance = instance
        self.project = project
        self.zone = zone
        self.username = username
    }

    public static func normalizedPastedInput(_ command: String) -> String {
        let withoutLineContinuations = command
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\\\r", with: " ")

        return withoutLineContinuations
            .split(whereSeparator: \.isWhitespace)
            .filter { $0 != "\\" }
            .map(String.init)
            .joined(separator: " ")
    }

    public static func parse(_ command: String) throws -> GCloudSSHCommand {
        var tokens = try shellTokens(command)
        if tokens.first == "$" {
            tokens.removeFirst()
        }

        guard !tokens.isEmpty else {
            throw GCloudSSHCommandError.empty
        }
        guard tokens.count >= 4,
              NSString(string: tokens[0]).lastPathComponent == "gcloud",
              tokens[1] == "compute",
              tokens[2] == "ssh" else {
            throw GCloudSSHCommandError.unsupportedCommand
        }

        let target = tokens[3]
        guard !target.isEmpty, !target.hasPrefix("-") else {
            throw GCloudSSHCommandError.missingInstance
        }

        guard tokens.dropFirst(4).contains("--tunnel-through-iap") else {
            throw GCloudSSHCommandError.missingIAPFlag
        }

        guard let project = flagValue("--project", in: tokens), !project.isEmpty else {
            throw GCloudSSHCommandError.missingFlag("--project")
        }
        guard let zone = flagValue("--zone", in: tokens), !zone.isEmpty else {
            throw GCloudSSHCommandError.missingFlag("--zone")
        }

        let username: String?
        let instance: String
        if let separator = target.firstIndex(of: "@") {
            let user = String(target[..<separator])
            let name = String(target[target.index(after: separator)...])
            guard !user.isEmpty, !name.isEmpty else {
                throw GCloudSSHCommandError.missingInstance
            }
            username = user
            instance = name
        } else {
            username = nil
            instance = target
        }

        return GCloudSSHCommand(instance: instance, project: project, zone: zone, username: username)
    }
}

public enum GCloudSSHCommandError: LocalizedError, Equatable, Sendable {
    case empty
    case malformedQuotes
    case unsupportedCommand
    case missingInstance
    case missingFlag(String)
    case missingIAPFlag

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Paste a gcloud compute ssh command."
        case .malformedQuotes:
            "The command contains an unfinished quote or escape."
        case .unsupportedCommand:
            "This does not look like a gcloud compute ssh command."
        case .missingInstance:
            "The command is missing its VM instance name."
        case .missingFlag(let flag):
            "The command is missing \(flag)."
        case .missingIAPFlag:
            "The command must include --tunnel-through-iap."
        }
    }
}

private func flagValue(_ flag: String, in tokens: [String]) -> String? {
    let prefix = "\(flag)="
    for index in tokens.indices {
        let token = tokens[index]
        if token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        if token == flag {
            let valueIndex = tokens.index(after: index)
            if valueIndex < tokens.endIndex, !tokens[valueIndex].hasPrefix("-") {
                return tokens[valueIndex]
            }
        }
    }
    return nil
}

private func shellTokens(_ command: String) throws -> [String] {
    enum Quote {
        case none
        case single
        case double
    }

    var tokens: [String] = []
    var current = ""
    var quote = Quote.none
    var escaping = false
    var tokenStarted = false

    func appendCurrent() {
        guard tokenStarted else { return }
        tokens.append(current)
        current = ""
        tokenStarted = false
    }

    for character in command {
        if escaping {
            if character != "\n" && character != "\r" {
                current.append(character)
                tokenStarted = true
            }
            escaping = false
            continue
        }

        switch quote {
        case .none:
            if character == "\\" {
                escaping = true
                tokenStarted = true
            } else if character == "'" {
                quote = .single
                tokenStarted = true
            } else if character == "\"" {
                quote = .double
                tokenStarted = true
            } else if character.isWhitespace {
                appendCurrent()
            } else {
                current.append(character)
                tokenStarted = true
            }
        case .single:
            if character == "'" {
                quote = .none
            } else {
                current.append(character)
            }
        case .double:
            if character == "\"" {
                quote = .none
            } else if character == "\\" {
                escaping = true
            } else {
                current.append(character)
            }
        }
    }

    guard quote == .none, !escaping else {
        throw GCloudSSHCommandError.malformedQuotes
    }
    appendCurrent()
    return tokens
}
