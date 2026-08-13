import Foundation
import MorrowNavigatorCore

@MainActor
final class RemoteFileNode: NSObject {
    let info: FileInfo
    weak var parent: RemoteFileNode?

    private let cache: RemoteDirectoryCache
    private var cachedChildren: [RemoteFileNode]?

    init(info: FileInfo, parent: RemoteFileNode? = nil, cache: RemoteDirectoryCache) {
        self.info = info
        self.parent = parent
        self.cache = cache
    }

    var location: RemoteLocation? {
        RemoteLocation(url: info.url)
    }

    var isExpandable: Bool {
        info.isNavigableDirectory
    }

    func children(forceReload: Bool = false) -> [RemoteFileNode] {
        guard isExpandable, let location else { return [] }
        if !forceReload, let cachedChildren {
            return cachedChildren
        }
        let loaded = cache.cachedDirectory(location)?.items ?? []
        let nodes = loaded.map { RemoteFileNode(info: $0, parent: self, cache: cache) }
        cachedChildren = nodes
        return nodes
    }

    func replaceChildren(with items: [FileInfo]) {
        cachedChildren = items.map { RemoteFileNode(info: $0, parent: self, cache: cache) }
    }

    func child(named name: String) -> RemoteFileNode? {
        children().first { $0.info.name == name }
    }

    func invalidateChildren(recursively: Bool = false) {
        if recursively {
            cachedChildren?.forEach { $0.invalidateChildren(recursively: true) }
        }
        cachedChildren = nil
    }
}
