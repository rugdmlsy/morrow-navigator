import Foundation

public enum NavigatorIPC {
    public static let requestNotification = Notification.Name("com.xycdev.morrow-navigator.command-request")
    public static let bundleIdentifier = "com.xycdev.morrow-navigator"

    public static func requestURL(id: UUID) -> URL {
        ipcDirectory.appendingPathComponent("\(id.uuidString).request.json")
    }

    public static func responseURL(id: UUID) -> URL {
        ipcDirectory.appendingPathComponent("\(id.uuidString).response.json")
    }

    public static var ipcDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-navigator-ipc", isDirectory: true)
            .appendingPathComponent(NSUserName(), isDirectory: true)
    }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: ipcDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: ipcDirectory.path
        )
    }

    public static func isValidRequestURL(_ url: URL) -> Bool {
        let directory = ipcDirectory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(directory + "/") && candidate.hasSuffix(".request.json")
    }
}

public struct NavigatorIPCRequest: Codable, Sendable {
    public let id: UUID
    public let arguments: [String]

    public init(id: UUID = UUID(), arguments: [String]) {
        self.id = id
        self.arguments = arguments
    }
}

public struct NavigatorIPCResponse: Codable, Sendable {
    public let id: UUID
    public let result: NavigatorCommandResult

    public init(id: UUID, result: NavigatorCommandResult) {
        self.id = id
        self.result = result
    }
}
