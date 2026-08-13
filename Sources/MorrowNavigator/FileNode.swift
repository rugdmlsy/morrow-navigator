import Foundation
import MorrowNavigatorCore

@MainActor
final class FileNode: NSObject {
    let info: FileInfo
    weak var parent: FileNode?

    private let fileSystem: FileSystemService
    private var cachedChildren: [FileNode]?

    init(info: FileInfo, parent: FileNode? = nil, fileSystem: FileSystemService) {
        self.info = info
        self.parent = parent
        self.fileSystem = fileSystem
    }

    var isExpandable: Bool {
        info.isNavigableDirectory
    }

    func children(forceReload: Bool = false) -> [FileNode] {
        guard isExpandable else { return [] }
        if !forceReload, let cachedChildren {
            return cachedChildren
        }

        let loaded = (try? fileSystem.children(of: info.url)) ?? []
        let nodes = loaded.map { FileNode(info: $0, parent: self, fileSystem: fileSystem) }
        cachedChildren = nodes
        return nodes
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
