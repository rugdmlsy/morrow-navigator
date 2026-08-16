import CryptoKit
import Foundation

public struct CachedFileSystemDirectory: Sendable, Equatable {
    public let location: FileSystemLocation
    public let items: [FileInfo]
    public let savedAt: Date

    public init(location: FileSystemLocation, items: [FileInfo], savedAt: Date) {
        self.location = location
        self.items = items
        self.savedAt = savedAt
    }
}

public struct FileSystemDirectoryCache: Sendable {
    private struct CachePayload: Codable {
        let version: Int
        let kind: FileSystemKind
        let authority: String?
        let path: String
        let savedAt: Date
        let items: [CacheItem]
    }

    private struct CacheItem: Codable {
        let name: String
        let path: String
        let isDirectory: Bool
        let isPackage: Bool
        let size: Int64?
        let modifiedAt: Date?
        let isHidden: Bool
    }

    private let rootDirectory: URL

    public init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootDirectory = caches
                .appendingPathComponent("MorrowNavigator", isDirectory: true)
                .appendingPathComponent("FileSystemDirectories", isDirectory: true)
        }
    }

    public func cachedDirectory(_ location: FileSystemLocation) -> CachedFileSystemDirectory? {
        guard location.kind != .local else { return nil }
        let url = cacheURL(for: location)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              payload.version == 2,
              payload.kind == location.kind,
              payload.authority == location.authority,
              payload.path == location.path else {
            return nil
        }

        let items = payload.items.map { item in
            let itemLocation = FileSystemLocation(kind: location.kind, authority: location.authority, path: item.path)
            return FileInfo(
                url: itemLocation.url,
                name: item.name,
                isDirectory: item.isDirectory,
                isPackage: item.isPackage,
                size: item.size,
                modifiedAt: item.modifiedAt,
                isHidden: item.isHidden
            )
        }
        return CachedFileSystemDirectory(location: location, items: items, savedAt: payload.savedAt)
    }

    public func store(_ items: [FileInfo], for location: FileSystemLocation, savedAt: Date = Date()) throws {
        guard location.kind != .local else { return }
        let payload = CachePayload(
            version: 2,
            kind: location.kind,
            authority: location.authority,
            path: location.path,
            savedAt: savedAt,
            items: items.compactMap { info in
                guard let itemLocation = info.location,
                      itemLocation.kind == location.kind,
                      itemLocation.authority == location.authority else { return nil }
                return CacheItem(
                    name: info.name,
                    path: itemLocation.path,
                    isDirectory: info.isDirectory,
                    isPackage: info.isPackage,
                    size: info.size,
                    modifiedAt: info.modifiedAt,
                    isHidden: info.isHidden
                )
            }
        )

        let providerDirectory = providerCacheDirectory(location)
        try FileManager.default.createDirectory(at: providerDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: cacheURL(for: location), options: .atomic)
    }

    public func removeProvider(kind: FileSystemKind, authority: String?) {
        let location = FileSystemLocation(kind: kind, authority: authority, path: "/")
        try? FileManager.default.removeItem(at: providerCacheDirectory(location))
    }

    public func cacheURL(for location: FileSystemLocation) -> URL {
        providerCacheDirectory(location).appendingPathComponent("\(digest(location.path)).json")
    }

    private func providerCacheDirectory(_ location: FileSystemLocation) -> URL {
        let identity = "\(location.kind.rawValue)|\(location.authority ?? "local")"
        return rootDirectory.appendingPathComponent(digest(identity), isDirectory: true)
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
