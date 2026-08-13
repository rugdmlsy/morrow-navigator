import CryptoKit
import Foundation

public struct CachedRemoteDirectory: Sendable, Equatable {
    public let location: RemoteLocation
    public let items: [FileInfo]
    public let savedAt: Date

    public init(location: RemoteLocation, items: [FileInfo], savedAt: Date) {
        self.location = location
        self.items = items
        self.savedAt = savedAt
    }
}

public struct RemoteDirectoryCache: Sendable {
    private struct CachePayload: Codable {
        let version: Int
        let host: String
        let path: String
        let savedAt: Date
        let items: [CacheItem]
    }

    private struct CacheItem: Codable {
        let name: String
        let path: String
        let isDirectory: Bool
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
                .appendingPathComponent("RemoteDirectories", isDirectory: true)
        }
    }

    public func cachedDirectory(_ location: RemoteLocation) -> CachedRemoteDirectory? {
        let url = cacheURL(for: location)
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              payload.version == 1,
              payload.host == location.host,
              payload.path == location.path else {
            return nil
        }

        let items = payload.items.map { item in
            FileInfo(
                url: RemoteLocation(host: location.host, path: item.path).url,
                name: item.name,
                isDirectory: item.isDirectory,
                isPackage: false,
                size: item.size,
                modifiedAt: item.modifiedAt,
                isHidden: item.isHidden
            )
        }
        return CachedRemoteDirectory(location: location, items: items, savedAt: payload.savedAt)
    }

    public func store(_ items: [FileInfo], for location: RemoteLocation, savedAt: Date = Date()) throws {
        let payload = CachePayload(
            version: 1,
            host: location.host,
            path: location.path,
            savedAt: savedAt,
            items: items.compactMap { info in
                guard let remote = RemoteLocation(url: info.url), remote.host == location.host else { return nil }
                return CacheItem(
                    name: info.name,
                    path: remote.path,
                    isDirectory: info.isDirectory,
                    size: info.size,
                    modifiedAt: info.modifiedAt,
                    isHidden: info.isHidden
                )
            }
        )

        let hostDirectory = hostCacheDirectory(location.host)
        try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: cacheURL(for: location), options: .atomic)
    }

    public func removeHost(_ host: String) {
        try? FileManager.default.removeItem(at: hostCacheDirectory(host))
    }

    public func cacheURL(for location: RemoteLocation) -> URL {
        let locationDigest = digest(location.path)
        return hostCacheDirectory(location.host).appendingPathComponent("\(locationDigest).json")
    }

    private func hostCacheDirectory(_ host: String) -> URL {
        rootDirectory.appendingPathComponent(digest(host), isDirectory: true)
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
