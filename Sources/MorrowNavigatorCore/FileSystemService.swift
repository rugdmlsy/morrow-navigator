import Foundation

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

    public var isNavigableDirectory: Bool {
        isDirectory && !isPackage
    }

    public var fileExtension: String {
        url.pathExtension.lowercased()
    }
}

public struct FileSystemService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func info(for url: URL) throws -> FileInfo {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isHiddenKey
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

    public func children(of directory: URL, includeHidden: Bool = false) throws -> [FileInfo] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isHiddenKey
        ]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includeHidden {
            options.insert(.skipsHiddenFiles)
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: options
        )

        let items = urls.compactMap { url -> FileInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                return nil
            }
            let hidden = values.isHidden ?? url.lastPathComponent.hasPrefix(".")
            if hidden && !includeHidden {
                return nil
            }
            return FileInfo(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                isPackage: values.isPackage ?? false,
                size: values.fileSize.map(Int64.init),
                modifiedAt: values.contentModificationDate,
                isHidden: hidden
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.isNavigableDirectory != rhs.isNavigableDirectory {
                return lhs.isNavigableDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
