import Darwin
import Dispatch
import Foundation

@MainActor
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var callback: (() -> Void)?

    func watch(_ url: URL?, onChange: @escaping () -> Void) {
        stop()
        guard let url else { return }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        descriptor = fd
        callback = onChange

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.callback?()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
        callback = nil
    }

    deinit {
        source?.cancel()
    }
}
