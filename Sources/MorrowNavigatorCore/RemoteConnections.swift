import Foundation

public enum RemoteHostKind: String, Sendable, CaseIterable {
    case sftp
    case github

    public var displayName: String {
        switch self {
        case .sftp: "SFTP"
        case .github: "GitHub"
        }
    }
}

extension RemoteHostKind: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self).lowercased()
        switch value {
        case "sftp", "ssh": self = .sftp
        case "github": self = .github
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown remote host kind: \(value)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RemoteHost: Sendable, Equatable, Hashable, Codable {
    public let alias: String
    public let hostname: String?
    public let user: String?
    public let port: Int?
    public let identityFile: String?
    public let kind: RemoteHostKind
    public let displayName: String?
    public let rootPath: String

    public init(
        alias: String,
        hostname: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        kind: RemoteHostKind = .sftp,
        displayName: String? = nil,
        rootPath: String = "/"
    ) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.kind = kind
        self.displayName = displayName
        self.rootPath = FileSystemLocation(kind: kind.fileSystemKind, authority: alias, path: rootPath).path
    }

    public var id: String { "\(kind.rawValue)|\(alias)|\(rootPath)|\(displayName ?? "")" }

    public var navigationLocation: FileSystemLocation {
        FileSystemLocation(kind: kind.fileSystemKind, authority: alias, path: rootPath)
    }

    public var endpointDescription: String {
        if kind == .github, rootPath != "/" {
            return "github.com\(rootPath)"
        }
        let host = hostname ?? alias
        let userPrefix = user.map { "\($0)@" } ?? ""
        let portSuffix = port.map { $0 == 22 ? "" : ":\($0)" } ?? ""
        return userPrefix + host + portSuffix
    }
}

public extension RemoteHostKind {
    var fileSystemKind: FileSystemKind {
        switch self {
        case .sftp: .sftp
        case .github: .github
        }
    }
}

public struct GitHubRepository: Sendable, Equatable, Codable {
    public let name: String
    public let fullName: String
    public let updatedAt: String?

    public init(name: String, fullName: String, updatedAt: String?) {
        self.name = name
        self.fullName = fullName
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case updatedAt = "updated_at"
    }
}

public struct SSHConfigDiscovery: Sendable {
    public struct NewHost: Sendable, Equatable {
        public let alias: String
        public let hostname: String
        public let user: String?
        public let port: Int?
        public let identityFile: String?

        public init(alias: String, hostname: String, user: String? = nil, port: Int? = nil, identityFile: String? = nil) {
            self.alias = alias
            self.hostname = hostname
            self.user = user
            self.port = port
            self.identityFile = identityFile
        }
    }

    public enum ConfigError: LocalizedError, Sendable {
        case invalidAlias
        case invalidHostname
        case duplicateAlias(String)

        public var errorDescription: String? {
            switch self {
            case .invalidAlias: "SSH alias must contain only letters, numbers, '.', '_', or '-'."
            case .invalidHostname: "SSH hostname cannot be empty or contain whitespace."
            case .duplicateAlias(let alias): "SSH alias '\(alias)' already exists in ~/.ssh/config."
            }
        }
    }

    public init() {}

    public func hosts(configURL: URL? = nil) -> [RemoteHost] {
        let url = configURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        var visited = Set<URL>()
        guard let text = expandedConfigText(at: url, visited: &visited) else { return [] }

        struct HostBlock {
            var aliases: [String]
            var hostname: String?
            var user: String?
            var port: Int?
            var identityFile: String?
        }

        var blocks: [HostBlock] = []
        var current: HostBlock?
        func finishCurrent() {
            if let current { blocks.append(current) }
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { continue }
            let key = fields[0].lowercased()
            if key == "host" {
                finishCurrent()
                current = HostBlock(
                    aliases: fields.dropFirst().filter {
                        !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") && !$0.isEmpty
                    },
                    hostname: nil,
                    user: nil,
                    port: nil,
                    identityFile: nil
                )
                continue
            }
            guard current != nil else { continue }
            let value = fields.dropFirst().joined(separator: " ")
            switch key {
            case "hostname": current?.hostname = value
            case "user": current?.user = value
            case "port": current?.port = Int(value)
            case "identityfile": current?.identityFile = value
            default: break
            }
        }
        finishCurrent()

        var seen = Set<String>()
        var result: [RemoteHost] = []
        for block in blocks {
            for alias in block.aliases where seen.insert(alias).inserted {
                let effectiveHostname = (block.hostname ?? alias).lowercased()
                let kind: RemoteHostKind = (effectiveHostname == "github.com" || effectiveHostname == "ssh.github.com")
                    ? .github
                    : .sftp
                result.append(RemoteHost(
                    alias: alias,
                    hostname: block.hostname,
                    user: block.user,
                    port: block.port,
                    identityFile: block.identityFile,
                    kind: kind
                ))
            }
        }
        return result.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    @discardableResult
    public func appendHost(_ host: NewHost, configURL: URL? = nil) throws -> RemoteHost {
        let aliasPattern = /^[A-Za-z0-9._-]+$/
        guard host.alias.wholeMatch(of: aliasPattern) != nil else { throw ConfigError.invalidAlias }
        guard !host.hostname.isEmpty, !host.hostname.contains(where: \.isWhitespace) else { throw ConfigError.invalidHostname }

        let url = configURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        if hosts(configURL: url).contains(where: { $0.alias == host.alias }) {
            throw ConfigError.duplicateAlias(host.alias)
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        if !existing.isEmpty { existing += "\n" }

        var lines = ["Host \(host.alias)", "    HostName \(host.hostname)"]
        if let user = host.user?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            lines.append("    User \(user)")
        }
        if let port = host.port { lines.append("    Port \(port)") }
        if let identityFile = host.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines), !identityFile.isEmpty {
            lines.append("    IdentityFile \(identityFile)")
            lines.append("    IdentitiesOnly yes")
        }
        existing += lines.joined(separator: "\n") + "\n"
        try existing.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        return RemoteHost(
            alias: host.alias,
            hostname: host.hostname,
            user: host.user,
            port: host.port,
            identityFile: host.identityFile,
            kind: .sftp
        )
    }

    private func expandedConfigText(at url: URL, visited: inout Set<URL>) -> String? {
        let standardized = url.standardizedFileURL
        guard visited.insert(standardized).inserted,
              let text = try? String(contentsOf: standardized, encoding: .utf8) else { return nil }

        var output: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.count >= 2, fields[0].lowercased() == "include" {
                for rawPath in fields.dropFirst() {
                    let unquoted = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    guard !unquoted.contains("*"), !unquoted.contains("?"), !unquoted.contains("[") else { continue }
                    let expanded = (unquoted as NSString).expandingTildeInPath
                    let includeURL: URL
                    if expanded.hasPrefix("/") {
                        includeURL = URL(fileURLWithPath: expanded)
                    } else {
                        includeURL = standardized.deletingLastPathComponent().appendingPathComponent(expanded)
                    }
                    if let includedText = expandedConfigText(at: includeURL, visited: &visited) {
                        output.append(includedText)
                    }
                }
            } else {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }
}
