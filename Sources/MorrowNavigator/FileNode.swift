import Foundation
import MorrowNavigatorCore

@MainActor
final class FileNode: NSObject {
    private(set) var info: FileInfo
    weak var parent: FileNode?

    private let fileSystem: UnifiedFileSystemService
    private let cache: FileSystemDirectoryCache
    private var cachedChildren: [FileNode]?

    init(
        info: FileInfo,
        parent: FileNode? = nil,
        fileSystem: UnifiedFileSystemService,
        cache: FileSystemDirectoryCache
    ) {
        self.info = info
        self.parent = parent
        self.fileSystem = fileSystem
        self.cache = cache
    }

    var location: FileSystemLocation? { info.location }

    var isExpandable: Bool { info.isNavigableDirectory }

    func children(forceReload: Bool = false) -> [FileNode] {
        guard isExpandable, let location else { return [] }
        if !forceReload, let cachedChildren { return cachedChildren }

        let loaded: [FileInfo]
        if location.kind == .local {
            loaded = (try? fileSystem.children(of: location)) ?? []
        } else {
            loaded = cache.cachedDirectory(location)?.items ?? []
        }
        let nodes = loaded.map {
            FileNode(info: $0, parent: self, fileSystem: fileSystem, cache: cache)
        }
        cachedChildren = nodes
        return nodes
    }

    func replaceChildren(with items: [FileInfo]) {
        let existingByLocation = Dictionary(
            uniqueKeysWithValues: (cachedChildren ?? []).compactMap { child in
                child.location.map { ($0, child) }
            }
        )
        cachedChildren = items.map { item in
            if let location = item.location,
               let existing = existingByLocation[location] {
                existing.info = item
                existing.parent = self
                return existing
            }
            return FileNode(info: item, parent: self, fileSystem: fileSystem, cache: cache)
        }
    }

    func child(named name: String) -> FileNode? {
        children().first { $0.info.name == name }
    }

    func invalidateChildren(recursively: Bool = false) {
        if recursively {
            cachedChildren?.forEach { $0.invalidateChildren(recursively: true) }
        }
        cachedChildren = nil
    }
}
