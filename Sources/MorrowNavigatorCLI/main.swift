import AppKit
import Foundation
import MorrowNavigatorCore

private let arguments = Array(CommandLine.arguments.dropFirst())
private let jsonOutput = arguments.first == "--json"
private let commandArguments = jsonOutput ? Array(arguments.dropFirst()) : arguments

if commandArguments.isEmpty {
    print(NavigatorCommandEngine().helpText)
    exit(0)
}

let result: NavigatorCommandResult
if isNavigatorRunning(), let ipcResult = sendToRunningNavigator(arguments: commandArguments) {
    result = ipcResult
} else {
    let engine = NavigatorCommandEngine()
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let standalone = engine.execute(arguments: commandArguments, baseDirectory: base, workspaceRoot: nil)
    result = applyStandaloneEffect(standalone)
}

if jsonOutput {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(result), let string = String(data: data, encoding: .utf8) {
        print(string)
    }
} else if !result.output.isEmpty {
    let stream = result.success ? FileHandle.standardOutput : FileHandle.standardError
    stream.write(Data((result.output + "\n").utf8))
}
exit(result.success ? 0 : 1)

private func isNavigatorRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: NavigatorIPC.bundleIdentifier).isEmpty
}

private func sendToRunningNavigator(arguments: [String]) -> NavigatorCommandResult? {
    do {
        try NavigatorIPC.ensureDirectory()
        let request = NavigatorIPCRequest(arguments: arguments)
        let requestURL = NavigatorIPC.requestURL(id: request.id)
        let responseURL = NavigatorIPC.responseURL(id: request.id)
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }

        let data = try JSONEncoder().encode(request)
        try data.write(to: requestURL, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(
            NavigatorIPC.requestNotification,
            object: requestURL.path,
            userInfo: nil,
            deliverImmediately: true
        )

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let responseData = try? Data(contentsOf: responseURL),
               let response = try? JSONDecoder().decode(NavigatorIPCResponse.self, from: responseData),
               response.id == request.id {
                return response.result
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return .failure("Morrow Navigator is running but did not respond to the command.")
    } catch {
        return .failure("IPC error: \(error.localizedDescription)")
    }
}

private func applyStandaloneEffect(_ result: NavigatorCommandResult) -> NavigatorCommandResult {
    guard result.success else { return result }

    switch result.effect {
    case .none, .refresh, .refreshAndSelect:
        return result
    case .open(let path):
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return result
    case .reveal(let path):
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return result
    case .navigate, .workspace, .select, .back, .forward, .uiFocusCommand, .uiShow, .uiState:
        return .failure("This command controls Navigator state; launch Morrow Navigator first.")
    }
}
