import Foundation

public enum GitHubFileSystemError: LocalizedError, Sendable {
    case cliUnavailable
    case missingAuthority
    case invalidLocation
    case invalidResponse(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cliUnavailable:
            return "GitHub CLI is unavailable. Install gh and run gh auth login."
        case .missingAuthority:
            return "The GitHub location does not specify an authority."
        case .invalidLocation:
            return "Invalid GitHub filesystem location."
        case .invalidResponse(let authority):
            return "\(authority) returned an invalid GitHub response."
        case .commandFailed(let message):
            return message
        }
    }
}

public struct GitHubFileSystemProvider: FileSystemProvider {
    private struct ContentPayload: Decodable {
        let name: String
        let path: String
        let type: String
        let size: Int64?
    }

    public let kind: FileSystemKind = .github
    private let ghPath: String?

    public init(ghPath: String? = nil) {
        self.ghPath = ghPath ?? Self.defaultGitHubCLIPath()
    }

    public func repositories() throws -> [GitHubRepository] {
        let endpoint = "/user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=updated"
        let data = try run(arguments: ["api", "--paginate", "--slurp", endpoint])
        guard let pages = try? JSONDecoder().decode([[GitHubRepository]].self, from: data) else {
            throw GitHubFileSystemError.invalidResponse("github.com")
        }
        return pages.flatMap { $0 }
    }

    public func info(at location: FileSystemLocation) throws -> FileInfo {
        let authority = try requireGitHub(location)
        if location.path == "/" {
            return FileInfo(
                url: location.url,
                name: authority,
                isDirectory: true,
                isPackage: false,
                size: nil,
                modifiedAt: nil,
                isHidden: false
            )
        }
        let parent = location.parent
        guard let item = try children(of: parent, includeHidden: true).first(where: { $0.location == location }) else {
            throw GitHubFileSystemError.invalidResponse(authority)
        }
        return item
    }

    public func children(of location: FileSystemLocation, includeHidden: Bool = false) throws -> [FileInfo] {
        let authority = try requireGitHub(location)
        let components = location.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let ownerScope = ownerScope(for: authority)

        if components.isEmpty, let ownerScope {
            return try repositories()
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
                .sorted(by: FileInfo.navigationSort)
        }

        if components.isEmpty {
            let grouped = Dictionary(grouping: try repositories()) { repository in
                repository.fullName.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            }
            return grouped.compactMap { owner, repositories -> FileInfo? in
                guard !owner.isEmpty else { return nil }
                return FileInfo(
                    url: location.appending(owner).url,
                    name: owner,
                    isDirectory: true,
                    isPackage: false,
                    size: nil,
                    modifiedAt: repositories.compactMap { parseGitHubDate($0.updatedAt) }.max(),
                    isHidden: owner.hasPrefix(".")
                )
            }
            .filter { includeHidden || !$0.isHidden }
            .sorted(by: FileInfo.navigationSort)
        }

        if let ownerScope {
            let repository = components[0]
            let repositoryPath = components.dropFirst().joined(separator: "/")
            return try repositoryContents(
                location: location,
                owner: ownerScope,
                repository: repository,
                repositoryPath: repositoryPath,
                virtualBaseComponents: [repository],
                includeHidden: includeHidden
            )
        }

        if components.count == 1 {
            let owner = components[0]
            return try repositories()
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
                .sorted(by: FileInfo.navigationSort)
        }

        let owner = components[0]
        let repository = components[1]
        let repositoryPath = components.dropFirst(2).joined(separator: "/")
        return try repositoryContents(
            location: location,
            owner: owner,
            repository: repository,
            repositoryPath: repositoryPath,
            virtualBaseComponents: [owner, repository],
            includeHidden: includeHidden
        )
    }

    public func fileContents(of location: FileSystemLocation, maxBytes: Int = 8 * 1024 * 1024) throws -> Data {
        _ = try requireGitHub(location)
        guard maxBytes > 0 else { return Data() }
        let endpoint = try fileContentsEndpoint(for: location)
        let data = try run(arguments: ["api", "-H", "Accept: application/vnd.github.raw+json", endpoint])
        guard data.count <= maxBytes else { throw FileSystemError.fileTooLarge(maxBytes: maxBytes) }
        return data
    }

    private func repositoryContents(
        location: FileSystemLocation,
        owner: String,
        repository: String,
        repositoryPath: String,
        virtualBaseComponents: [String],
        includeHidden: Bool
    ) throws -> [FileInfo] {
        var endpoint = "/repos/\(encode(owner))/\(encode(repository))/contents"
        if !repositoryPath.isEmpty {
            endpoint += "/" + repositoryPath
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { encode(String($0)) }
                .joined(separator: "/")
        }
        let data = try run(arguments: ["api", endpoint])
        guard let payloads = try? JSONDecoder().decode([ContentPayload].self, from: data) else {
            throw GitHubFileSystemError.invalidResponse(location.authority ?? "github.com")
        }

        let root = FileSystemLocation(kind: .github, authority: location.authority, path: "/")
        return payloads.compactMap { payload in
            let hidden = payload.name.hasPrefix(".")
            if hidden && !includeHidden { return nil }
            let virtualPath = "/" + (virtualBaseComponents + [payload.path]).filter { !$0.isEmpty }.joined(separator: "/")
            let itemLocation = FileSystemLocation(kind: .github, authority: root.authority, path: virtualPath)
            return FileInfo(
                url: itemLocation.url,
                name: payload.name,
                isDirectory: payload.type == "dir",
                isPackage: false,
                size: payload.type == "dir" ? nil : payload.size,
                modifiedAt: nil,
                isHidden: hidden
            )
        }.sorted(by: FileInfo.navigationSort)
    }

    private func fileContentsEndpoint(for location: FileSystemLocation) throws -> String {
        let components = location.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let owner: String
        let repository: String
        let fileComponents: ArraySlice<String>
        if let ownerScope = ownerScope(for: location.authority ?? "") {
            guard components.count >= 2 else { throw GitHubFileSystemError.invalidLocation }
            owner = ownerScope
            repository = components[0]
            fileComponents = components.dropFirst()
        } else {
            guard components.count >= 3 else { throw GitHubFileSystemError.invalidLocation }
            owner = components[0]
            repository = components[1]
            fileComponents = components.dropFirst(2)
        }
        let encodedPath = fileComponents.map(encode).joined(separator: "/")
        guard !encodedPath.isEmpty else { throw GitHubFileSystemError.invalidLocation }
        return "/repos/\(encode(owner))/\(encode(repository))/contents/\(encodedPath)"
    }

    private func ownerScope(for authority: String) -> String? {
        let prefix = "github-"
        guard authority.lowercased().hasPrefix(prefix), authority.count > prefix.count else { return nil }
        return String(authority.dropFirst(prefix.count))
    }

    private func requireGitHub(_ location: FileSystemLocation) throws -> String {
        guard location.kind == .github else {
            throw FileSystemError.wrongProvider(expected: .github, actual: location.kind)
        }
        guard let authority = location.authority, !authority.isEmpty else {
            throw GitHubFileSystemError.missingAuthority
        }
        guard let ghPath, FileManager.default.isExecutableFile(atPath: ghPath) else {
            throw GitHubFileSystemError.cliUnavailable
        }
        return authority
    }

    private func run(arguments: [String]) throws -> Data {
        guard let ghPath, FileManager.default.isExecutableFile(atPath: ghPath) else {
            throw GitHubFileSystemError.cliUnavailable
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-navigator-gh-\(UUID().uuidString)", isDirectory: true)
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
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw GitHubFileSystemError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        try? stdout.synchronize()
        try? stderr.synchronize()
        let output = (try? Data(contentsOf: stdoutURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "GitHub command failed."
            throw GitHubFileSystemError.commandFailed(message)
        }
        return output
    }

    private func parseGitHubDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func defaultGitHubCLIPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
