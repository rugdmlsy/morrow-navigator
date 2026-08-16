import Foundation

public enum FileSystemKind: String, Sendable, Codable, CaseIterable {
    case local
    case sftp
    case github

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .sftp: "SFTP"
        case .github: "GitHub"
        }
    }
}

public struct FileSystemLocation: Sendable, Equatable, Hashable {
    public let kind: FileSystemKind
    public let authority: String?
    public let path: String

    public init(localURL: URL) {
        self.kind = .local
        self.authority = nil
        self.path = localURL.standardizedFileURL.path
    }

    public init(kind: FileSystemKind, authority: String? = nil, path: String) {
        self.kind = kind
        self.authority = kind == .local ? nil : authority
        self.path = kind == .local
            ? URL(fileURLWithPath: path).standardizedFileURL.path
            : Self.normalizedRemotePath(path)
    }

    public init?(url: URL) {
        let scheme = url.scheme?.lowercased()
        if url.isFileURL || scheme == "file" || scheme == nil {
            self.init(localURL: url)
            return
        }

        let kind: FileSystemKind
        switch scheme {
        case "sftp", "ssh":
            // ssh:// was used by Navigator before the remote filesystem moved to SFTP.
            kind = .sftp
        case "github":
            kind = .github
        default:
            return nil
        }
        guard let host = url.host, !host.isEmpty else { return nil }
        self.init(kind: kind, authority: host, path: url.path.isEmpty ? "/" : url.path)
    }

    public var url: URL {
        switch kind {
        case .local:
            return URL(fileURLWithPath: path)
        case .sftp, .github:
            var components = URLComponents()
            components.scheme = kind == .sftp ? "sftp" : "github"
            components.host = authority
            components.path = path
            return components.url ?? URL(string: "\(kind == .sftp ? "sftp" : "github")://invalid/")!
        }
    }

    public var displayPath: String {
        switch kind {
        case .local:
            return path
        case .sftp:
            return "\(authority ?? "remote"):\(path)"
        case .github:
            return "github:\(authority ?? "github.com"):\(path)"
        }
    }

    public var name: String {
        if path == "/" {
            return authority ?? "/"
        }
        return (path as NSString).lastPathComponent
    }

    public var parent: FileSystemLocation {
        guard path != "/" else { return self }
        let parentPath = (path as NSString).deletingLastPathComponent
        return FileSystemLocation(
            kind: kind,
            authority: authority,
            path: parentPath.isEmpty ? "/" : parentPath
        )
    }

    public func appending(_ component: String) -> FileSystemLocation {
        if kind == .local {
            return FileSystemLocation(localURL: url.appendingPathComponent(component))
        }
        let base = path == "/" ? "" : path
        return FileSystemLocation(kind: kind, authority: authority, path: base + "/" + component)
    }

    public func isDescendant(of root: FileSystemLocation) -> Bool {
        guard kind == root.kind, authority == root.authority else { return false }
        if path == root.path { return true }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        return path.hasPrefix(prefix)
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        var value = path.isEmpty ? "/" : path
        if !value.hasPrefix("/") { value = "/" + value }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        var normalized: [Substring] = []
        for part in parts {
            if part == "." { continue }
            if part == ".." {
                if !normalized.isEmpty { normalized.removeLast() }
                continue
            }
            normalized.append(part)
        }
        return "/" + normalized.joined(separator: "/")
    }
}

public struct FileInfo: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let size: Int64?
    public let modifiedAt: Date?
    public let isHidden: Bool

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isPackage: Bool,
        size: Int64?,
        modifiedAt: Date?,
        isHidden: Bool
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.modifiedAt = modifiedAt
        self.isHidden = isHidden
    }

    public var location: FileSystemLocation? { FileSystemLocation(url: url) }

    public var isNavigableDirectory: Bool { isDirectory && !isPackage }

    public var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}

public protocol FileSystemProvider: Sendable {
    var kind: FileSystemKind { get }
    func info(at location: FileSystemLocation) throws -> FileInfo
    func children(of location: FileSystemLocation, includeHidden: Bool) throws -> [FileInfo]
    func fileContents(of location: FileSystemLocation, maxBytes: Int) throws -> Data
}

public enum FileSystemError: LocalizedError, Sendable {
    case unsupportedLocation
    case wrongProvider(expected: FileSystemKind, actual: FileSystemKind)
    case fileTooLarge(maxBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocation:
            return "Unsupported filesystem location."
        case .wrongProvider(let expected, let actual):
            return "\(expected.displayName) provider cannot handle a \(actual.displayName) location."
        case .fileTooLarge(let maxBytes):
            return "File is too large to preview (limit: \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)))."
        }
    }
}

public struct LocalFileSystemProvider: FileSystemProvider, @unchecked Sendable {
    public let kind: FileSystemKind = .local
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func info(at location: FileSystemLocation) throws -> FileInfo {
        try requireLocal(location)
        let url = location.url
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        return FileInfo(
            url: url,
            name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false,
            size: values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate,
            isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix(".")
        )
    }

    public func children(of location: FileSystemLocation, includeHidden: Bool = false) throws -> [FileInfo] {
        try requireLocal(location)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey
        ]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }

        let urls = try fileManager.contentsOfDirectory(
            at: location.url,
            includingPropertiesForKeys: keys,
            options: options
        )
        return urls.compactMap { url -> FileInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let hidden = values.isHidden ?? url.lastPathComponent.hasPrefix(".")
            if hidden && !includeHidden { return nil }
            return FileInfo(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                isPackage: values.isPackage ?? false,
                size: values.fileSize.map(Int64.init),
                modifiedAt: values.contentModificationDate,
                isHidden: hidden
            )
        }.sorted(by: FileInfo.navigationSort)
    }

    public func fileContents(of location: FileSystemLocation, maxBytes: Int = 8 * 1024 * 1024) throws -> Data {
        try requireLocal(location)
        guard maxBytes > 0 else { return Data() }
        let values = try location.url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maxBytes {
            throw FileSystemError.fileTooLarge(maxBytes: maxBytes)
        }
        let data = try Data(contentsOf: location.url)
        guard data.count <= maxBytes else { throw FileSystemError.fileTooLarge(maxBytes: maxBytes) }
        return data
    }

    private func requireLocal(_ location: FileSystemLocation) throws {
        guard location.kind == .local else {
            throw FileSystemError.wrongProvider(expected: .local, actual: location.kind)
        }
    }
}

public extension FileInfo {
    static func navigationSort(_ lhs: FileInfo, _ rhs: FileInfo) -> Bool {
        if lhs.isNavigableDirectory != rhs.isNavigableDirectory {
            return lhs.isNavigableDirectory
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

// Compatibility wrapper for command code that only operates on the local filesystem.
public struct FileSystemService {
    private let provider: LocalFileSystemProvider

    public init(fileManager: FileManager = .default) {
        self.provider = LocalFileSystemProvider(fileManager: fileManager)
    }

    public func info(for url: URL) throws -> FileInfo {
        try provider.info(at: FileSystemLocation(localURL: url))
    }

    public func children(of directory: URL, includeHidden: Bool = false) throws -> [FileInfo] {
        try provider.children(of: FileSystemLocation(localURL: directory), includeHidden: includeHidden)
    }

    public func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        FileSystemLocation(localURL: candidate).isDescendant(of: FileSystemLocation(localURL: root))
    }
}
