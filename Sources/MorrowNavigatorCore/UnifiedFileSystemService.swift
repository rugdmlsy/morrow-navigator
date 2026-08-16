import Foundation

public struct UnifiedFileSystemService: Sendable {
    private let local: LocalFileSystemProvider
    private let sftp: SFTPFileSystemProvider
    private let github: GitHubFileSystemProvider

    public init(
        fileManager: FileManager = .default,
        sftpPath: String? = nil,
        ghPath: String? = nil
    ) {
        self.local = LocalFileSystemProvider(fileManager: fileManager)
        self.sftp = SFTPFileSystemProvider(sftpPath: sftpPath)
        self.github = GitHubFileSystemProvider(ghPath: ghPath)
    }

    public func location(for url: URL) throws -> FileSystemLocation {
        guard let location = FileSystemLocation(url: url) else {
            throw FileSystemError.unsupportedLocation
        }
        return location
    }

    public func info(for url: URL) throws -> FileInfo {
        try info(at: location(for: url))
    }

    public func info(at location: FileSystemLocation) throws -> FileInfo {
        switch location.kind {
        case .local: try local.info(at: location)
        case .sftp: try sftp.info(at: location)
        case .github: try github.info(at: location)
        }
    }

    public func children(of url: URL, includeHidden: Bool = false) throws -> [FileInfo] {
        try children(of: location(for: url), includeHidden: includeHidden)
    }

    public func children(of location: FileSystemLocation, includeHidden: Bool = false) throws -> [FileInfo] {
        switch location.kind {
        case .local: try local.children(of: location, includeHidden: includeHidden)
        case .sftp: try sftp.children(of: location, includeHidden: includeHidden)
        case .github: try github.children(of: location, includeHidden: includeHidden)
        }
    }

    public func fileContents(of url: URL, maxBytes: Int = 8 * 1024 * 1024) throws -> Data {
        try fileContents(of: location(for: url), maxBytes: maxBytes)
    }

    public func fileContents(of location: FileSystemLocation, maxBytes: Int = 8 * 1024 * 1024) throws -> Data {
        switch location.kind {
        case .local: try local.fileContents(of: location, maxBytes: maxBytes)
        case .sftp: try sftp.fileContents(of: location, maxBytes: maxBytes)
        case .github: try github.fileContents(of: location, maxBytes: maxBytes)
        }
    }

    public func homeDirectory(authority: String) throws -> FileSystemLocation {
        try sftp.homeDirectory(authority: authority)
    }

    public func githubRepositories() throws -> [GitHubRepository] {
        try github.repositories()
    }

    public func isDescendant(_ candidate: FileSystemLocation, of root: FileSystemLocation) -> Bool {
        candidate.isDescendant(of: root)
    }

    public func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        guard let candidate = FileSystemLocation(url: candidate),
              let root = FileSystemLocation(url: root) else { return false }
        return candidate.isDescendant(of: root)
    }
}
