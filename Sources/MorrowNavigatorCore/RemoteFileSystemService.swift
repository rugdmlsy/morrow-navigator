import Foundation

public struct RemoteHost: Sendable, Equatable, Hashable {
    public let alias: String

    public init(alias: String) {
        self.alias = alias
    }
}

public struct RemoteLocation: Sendable, Equatable, Hashable {
    public static let scheme = "ssh"

    public let host: String
    public let path: String

    public init(host: String, path: String) {
        self.host = host
        self.path = Self.normalizedPath(path)
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        self.init(host: host, path: url.path.isEmpty ? "/" : url.path)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        components.path = path
        return components.url ?? URL(string: "ssh://\(host)/")!
    }

    public var displayPath: String {
        "\(host):\(path)"
    }

    public func appending(_ component: String) -> RemoteLocation {
        let base = path == "/" ? "" : path
        return RemoteLocation(host: host, path: base + "/" + component)
    }

    public var parent: RemoteLocation {
        guard path != "/" else { return self }
        let parentPath = (path as NSString).deletingLastPathComponent
        return RemoteLocation(host: host, path: parentPath.isEmpty ? "/" : parentPath)
    }

    private static func normalizedPath(_ path: String) -> String {
        var value = path.isEmpty ? "/" : path
        if !value.hasPrefix("/") {
            value = "/" + value
        }
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

public struct SSHConfigDiscovery: Sendable {
    public init() {}

    public func hosts(configURL: URL? = nil) -> [RemoteHost] {
        let url = configURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        var seen = Set<String>()
        var result: [RemoteHost] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[0].lowercased() == "host" else { continue }

            for alias in fields.dropFirst() {
                guard !alias.contains("*"),
                      !alias.contains("?"),
                      !alias.hasPrefix("!"),
                      !alias.isEmpty,
                      seen.insert(alias).inserted else {
                    continue
                }
                result.append(RemoteHost(alias: alias))
            }
        }

        return result.sorted {
            $0.alias.localizedStandardCompare($1.alias) == .orderedAscending
        }
    }
}

public enum RemoteFileSystemError: LocalizedError, Sendable {
    case invalidLocation
    case sshUnavailable
    case githubCLIUnavailable
    case commandFailed(host: String, message: String)
    case invalidResponse(host: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLocation:
            return "Invalid remote location."
        case .sshUnavailable:
            return "The system SSH client is unavailable."
        case .githubCLIUnavailable:
            return "GitHub CLI is unavailable. Install gh and run gh auth login."
        case .commandFailed(let host, let message):
            return message.isEmpty ? "Unable to connect to \(host)." : "\(host): \(message)"
        case .invalidResponse(let host):
            return "\(host) returned an invalid directory response."
        }
    }
}

public struct RemoteFileSystemService: Sendable {
    private struct EntryPayload: Decodable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64?
        let modifiedAt: Double?
        let isHidden: Bool
    }

    private struct GitHubRepositoryPayload: Decodable {
        let name: String
        let fullName: String
        let updatedAt: String?

        enum CodingKeys: String, CodingKey {
            case name
            case fullName = "full_name"
            case updatedAt = "updated_at"
        }
    }

    private struct GitHubContentPayload: Decodable {
        let name: String
        let path: String
        let type: String
        let size: Int64?
    }

    private static let homeScript = #"""
import base64, json, os
print(json.dumps({"path": os.path.expanduser("~")}))
"""#

    private static let childrenScript = #"""
import base64, json, os, sys
path = base64.b64decode(sys.argv[1]).decode("utf-8")
items = []
with os.scandir(path) as entries:
    for entry in entries:
        try:
            is_dir = entry.is_dir(follow_symlinks=True)
            stat = entry.stat(follow_symlinks=False)
            items.append({
                "name": entry.name,
                "path": os.path.join(path, entry.name),
                "isDirectory": is_dir,
                "size": None if is_dir else stat.st_size,
                "modifiedAt": stat.st_mtime,
                "isHidden": entry.name.startswith(".")
            })
        except OSError:
            continue
print(json.dumps(items, ensure_ascii=False))
"""#

    private let sshPath: String
    private let ghPath: String?

    public init(sshPath: String = "/usr/bin/ssh", ghPath: String? = nil) {
        self.sshPath = sshPath
        self.ghPath = ghPath ?? Self.defaultGitHubCLIPath()
    }

    public func homeDirectory(host: String) throws -> RemoteLocation {
        struct HomePayload: Decodable { let path: String }
        let data = try runPython(host: host, script: Self.homeScript, arguments: [])
        guard let payload = try? JSONDecoder().decode(HomePayload.self, from: data) else {
            throw RemoteFileSystemError.invalidResponse(host: host)
        }
        return RemoteLocation(host: host, path: payload.path)
    }

    public func children(of location: RemoteLocation, includeHidden: Bool = false) throws -> [FileInfo] {
        if isGitHubHost(location.host) {
            return try githubChildren(of: location, includeHidden: includeHidden)
        }

        let pathData = Data(location.path.utf8).base64EncodedString()
        let data = try runPython(host: location.host, script: Self.childrenScript, arguments: [pathData])
        guard let payloads = try? JSONDecoder().decode([EntryPayload].self, from: data) else {
            throw RemoteFileSystemError.invalidResponse(host: location.host)
        }

        return payloads.compactMap { payload in
            if payload.isHidden && !includeHidden { return nil }
            let itemLocation = RemoteLocation(host: location.host, path: payload.path)
            return FileInfo(
                url: itemLocation.url,
                name: payload.name,
                isDirectory: payload.isDirectory,
                isPackage: false,
                size: payload.size,
                modifiedAt: payload.modifiedAt.map { Date(timeIntervalSince1970: $0) },
                isHidden: payload.isHidden
            )
        }.sorted { lhs, rhs in
            if lhs.isNavigableDirectory != rhs.isNavigableDirectory {
                return lhs.isNavigableDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func isGitHubHost(_ host: String) -> Bool {
        guard let effectiveHost = effectiveHostname(for: host)?.lowercased() else { return false }
        return effectiveHost == "github.com" || effectiveHost == "ssh.github.com"
    }

    private func githubChildren(of location: RemoteLocation, includeHidden: Bool) throws -> [FileInfo] {
        let components = location.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let ownerScope = githubOwnerScope(for: location.host)

        if components.isEmpty, let ownerScope {
            return try githubRepositories(host: location.host)
                .filter { $0.fullName.hasPrefix(ownerScope + "/") }
                .map { repository in
                    FileInfo(
                        url: location.appending(repository.name).url,
                        name: repository.name,
                        isDirectory: true,
                        isPackage: false,
                        size: nil,
                        modifiedAt: parseGitHubDate(repository.updatedAt),
                        isHidden: repository.name.hasPrefix(".")
                    )
                }
                .filter { includeHidden || !$0.isHidden }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        if components.isEmpty {
            let repositories = try githubRepositories(host: location.host)
            let grouped = Dictionary(grouping: repositories) { repository in
                repository.fullName.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            }
            return grouped.compactMap { owner, repositories -> FileInfo? in
                guard !owner.isEmpty else { return nil }
                let latest = repositories.compactMap { parseGitHubDate($0.updatedAt) }.max()
                return FileInfo(
                    url: location.appending(owner).url,
                    name: owner,
                    isDirectory: true,
                    isPackage: false,
                    size: nil,
                    modifiedAt: latest,
                    isHidden: owner.hasPrefix(".")
                )
            }
            .filter { includeHidden || !$0.isHidden }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        if let ownerScope {
            let repository = components[0]
            let repositoryPath = components.dropFirst().joined(separator: "/")
            return try githubRepositoryContents(
                host: location.host,
                owner: ownerScope,
                repository: repository,
                repositoryPath: repositoryPath,
                virtualBaseComponents: [repository],
                includeHidden: includeHidden
            )
        }

        if components.count == 1 {
            let owner = components[0]
            return try githubRepositories(host: location.host)
                .filter { $0.fullName.hasPrefix(owner + "/") }
                .map { repository in
                    FileInfo(
                        url: location.appending(repository.name).url,
                        name: repository.name,
                        isDirectory: true,
                        isPackage: false,
                        size: nil,
                        modifiedAt: parseGitHubDate(repository.updatedAt),
                        isHidden: repository.name.hasPrefix(".")
                    )
                }
                .filter { includeHidden || !$0.isHidden }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        let owner = components[0]
        let repository = components[1]
        let repositoryPath = components.dropFirst(2).joined(separator: "/")
        return try githubRepositoryContents(
            host: location.host,
            owner: owner,
            repository: repository,
            repositoryPath: repositoryPath,
            virtualBaseComponents: [owner, repository],
            includeHidden: includeHidden
        )
    }

    private func githubRepositoryContents(
        host: String,
        owner: String,
        repository: String,
        repositoryPath: String,
        virtualBaseComponents: [String],
        includeHidden: Bool
    ) throws -> [FileInfo] {
        var endpoint = "/repos/\(encodeGitHubPathComponent(owner))/\(encodeGitHubPathComponent(repository))/contents"
        if !repositoryPath.isEmpty {
            endpoint += "/" + repositoryPath
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { encodeGitHubPathComponent(String($0)) }
                .joined(separator: "/")
        }

        let data = try runGitHub(host: host, arguments: ["api", endpoint])
        guard let payloads = try? JSONDecoder().decode([GitHubContentPayload].self, from: data) else {
            throw RemoteFileSystemError.invalidResponse(host: host)
        }

        return payloads.compactMap { payload in
            let hidden = payload.name.hasPrefix(".")
            if hidden && !includeHidden { return nil }
            let virtualPath = "/" + (virtualBaseComponents + [payload.path]).filter { !$0.isEmpty }.joined(separator: "/")
            let itemLocation = RemoteLocation(host: host, path: virtualPath)
            return FileInfo(
                url: itemLocation.url,
                name: payload.name,
                isDirectory: payload.type == "dir",
                isPackage: false,
                size: payload.type == "dir" ? nil : payload.size,
                modifiedAt: nil,
                isHidden: hidden
            )
        }.sorted { lhs, rhs in
            if lhs.isNavigableDirectory != rhs.isNavigableDirectory {
                return lhs.isNavigableDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func githubOwnerScope(for host: String) -> String? {
        let prefix = "github-"
        guard host.lowercased().hasPrefix(prefix), host.count > prefix.count else { return nil }
        return String(host.dropFirst(prefix.count))
    }

    private func githubRepositories(host: String) throws -> [GitHubRepositoryPayload] {
        let endpoint = "/user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=updated"
        let data = try runGitHub(host: host, arguments: ["api", "--paginate", "--slurp", endpoint])
        guard let pages = try? JSONDecoder().decode([[GitHubRepositoryPayload]].self, from: data) else {
            throw RemoteFileSystemError.invalidResponse(host: host)
        }
        return pages.flatMap { $0 }
    }

    private func runGitHub(host: String, arguments: [String]) throws -> Data {
        guard let ghPath, FileManager.default.isExecutableFile(atPath: ghPath) else {
            throw RemoteFileSystemError.githubCLIUnavailable
        }
        return try runProcess(executablePath: ghPath, arguments: arguments, host: host)
    }

    private func effectiveHostname(for host: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: sshPath),
              let data = try? runProcess(executablePath: sshPath, arguments: ["-G", host], host: host),
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            if fields.count == 2, fields[0].lowercased() == "hostname" {
                return fields[1]
            }
        }
        return nil
    }

    private func runProcess(executablePath: String, arguments: [String], host: String) throws -> Data {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-navigator-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw RemoteFileSystemError.commandFailed(host: host, message: error.localizedDescription)
        }
        process.waitUntilExit()
        try? stdout.synchronize()
        try? stderr.synchronize()

        let output = (try? Data(contentsOf: stdoutURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RemoteFileSystemError.commandFailed(host: host, message: message)
        }
        return output
    }

    private func parseGitHubDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func encodeGitHubPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func defaultGitHubCLIPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runPython(host: String, script: String, arguments: [String]) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            throw RemoteFileSystemError.sshUnavailable
        }

        let scriptData = Data(script.utf8).base64EncodedString()
        let pythonCommand = "python3 -c 'import base64;exec(base64.b64decode(\"\(scriptData)\"))'"
        let remoteCommand = ([pythonCommand] + arguments.map { "'\($0)'" }).joined(separator: " ")

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-navigator-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        let controlPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/morrow-navigator-%C")
            .path
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=120",
            "-o", "ControlPath=\(controlPath)",
            host,
            remoteCommand
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw RemoteFileSystemError.commandFailed(host: host, message: error.localizedDescription)
        }
        process.waitUntilExit()
        try? stdout.synchronize()
        try? stderr.synchronize()

        let output = (try? Data(contentsOf: stdoutURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RemoteFileSystemError.commandFailed(host: host, message: message)
        }
        return output
    }
}
