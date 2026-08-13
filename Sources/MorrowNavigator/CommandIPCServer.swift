import Foundation
import MorrowNavigatorCore

@MainActor
final class CommandIPCServer: NSObject {
    private let handler: ([String]) -> NavigatorCommandResult

    init(handler: @escaping ([String]) -> NavigatorCommandResult) {
        self.handler = handler
        super.init()
        try? NavigatorIPC.ensureDirectory()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleRequest(_:)),
            name: NavigatorIPC.requestNotification,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func handleRequest(_ notification: Notification) {
        guard let path = notification.object as? String else { return }
        let requestURL = URL(fileURLWithPath: path)
        guard NavigatorIPC.isValidRequestURL(requestURL),
              let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(NavigatorIPCRequest.self, from: data) else {
            return
        }

        let result = handler(request.arguments)
        let response = NavigatorIPCResponse(id: request.id, result: result)
        guard let responseData = try? JSONEncoder().encode(response) else { return }
        let responseURL = NavigatorIPC.responseURL(id: request.id)
        try? responseData.write(to: responseURL, options: .atomic)
    }
}
