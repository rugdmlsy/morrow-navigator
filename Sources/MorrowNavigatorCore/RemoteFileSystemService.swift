import Foundation

public struct RemoteHost: Sendable, Equatable, Hashable {
    public let alias: String

    public init(alias: String) {
        self.alias = alias
    }
}

public struct RemoteLocation: Sendable, Equatable, Hashable {
    public static let scheme = "ssh"

    public let host: String
    public let path: String

    public init(host: String, path: String) {
        self.host = host
        self.path = Self.normalizedPath(path)
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        self.init(host: host, path: url.path.isEmpty ? "/" : url.path)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        components.path = path
        return components.url ?? URL(string: "ssh://\(host)/")!
    }

    public var displayPath: String {
        "\(host):\(path)"
    }

    public func appending(_ component: String) -> RemoteLocation {
        let base = path == "/" ? "" : path
        return RemoteLocation(host: host, path: base + "/" + component)
    }

    public var parent: RemoteLocation {
        guard path != "/" else { return self }
        let parentPath = (path as NSString).deletingLastPathComponent
        return RemoteLocation(host: host, path: parentPath.isEmpty ? "/" : parentPath)
    }

    private static func normalizedPath(_ path: String) -> String {
        var value = path.isEmpty ? "/" : path
        if !value.hasPrefix("/") {
            value = "/" + value
        }
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

public struct SSHConfigDiscovery: Sendable {
    public init() {}

    public func hosts(configURL: URL? = nil) -> [RemoteHost] {
        let url = configURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        var seen = Set<String>()
        var result: [RemoteHost] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[0].lowercased() == "host" else { continue }

            for alias in fields.dropFirst() {
                guard !alias.contains("*"),
                      !alias.contains("?"),
                      !alias.hasPrefix("!"),
                      !alias.isEmpty,
                      seen.insert(alias).inserted else {
                    continue
                }
                result.append(RemoteHost(alias: alias))
            }
        }

        return result.sorted {
            $0.alias.localizedStandardCompare($1.alias) == .orderedAscending
        }
    }
}

public enum RemoteFileSystemError: LocalizedError, Sendable {
    case invalidLocation
    case sshUnavailable
    case commandFailed(host: String, message: String)
    case invalidResponse(host: String)

    public var errorDescription: String? {
        switch self {
        case .invalidLocation:
            return "Invalid remote location."
        case .sshUnavailable:
            return "The system SSH client is unavailable."
        case .commandFailed(let host, let message):
            return message.isEmpty ? "Unable to connect to \(host)." : "\(host): \(message)"
        case .invalidResponse(let host):
            return "\(host) returned an invalid directory response."
        }
    }
}

public struct RemoteFileSystemService: Sendable {
    private struct EntryPayload: Decodable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64?
        let modifiedAt: Double?
        let isHidden: Bool
    }

    private static let homeScript = #"""
import base64, json, os
print(json.dumps({"path": os.path.expanduser("~")}))
"""#

    private static let childrenScript = #"""
import base64, json, os, sys
path = base64.b64decode(sys.argv[1]).decode("utf-8")
items = []
with os.scandir(path) as entries:
    for entry in entries:
        try:
            is_dir = entry.is_dir(follow_symlinks=True)
            stat = entry.stat(follow_symlinks=False)
            items.append({
                "name": entry.name,
                "path": os.path.join(path, entry.name),
                "isDirectory": is_dir,
                "size": None if is_dir else stat.st_size,
                "modifiedAt": stat.st_mtime,
                "isHidden": entry.name.startswith(".")
            })
        except OSError:
            continue
print(json.dumps(items, ensure_ascii=False))
"""#

    private let sshPath: String

    public init(sshPath: String = "/usr/bin/ssh") {
        self.sshPath = sshPath
    }

    public func homeDirectory(host: String) throws -> RemoteLocation {
        struct HomePayload: Decodable { let path: String }
        let data = try runPython(host: host, script: Self.homeScript, arguments: [])
        guard let payload = try? JSONDecoder().decode(HomePayload.self, from: data) else {
            throw RemoteFileSystemError.invalidResponse(host: host)
        }
        return RemoteLocation(host: host, path: payload.path)
    }

    public func children(of location: RemoteLocation, includeHidden: Bool = false) throws -> [FileInfo] {
        let pathData = Data(location.path.utf8).base64EncodedString()
        let data = try runPython(host: location.host, script: Self.childrenScript, arguments: [pathData])
        guard let payloads = try? JSONDecoder().decode([EntryPayload].self, from: data) else {
            throw RemoteFileSystemError.invalidResponse(host: location.host)
        }

        return payloads.compactMap { payload in
            if payload.isHidden && !includeHidden { return nil }
            let itemLocation = RemoteLocation(host: location.host, path: payload.path)
            return FileInfo(
                url: itemLocation.url,
                name: payload.name,
                isDirectory: payload.isDirectory,
                isPackage: false,
                size: payload.size,
                modifiedAt: payload.modifiedAt.map { Date(timeIntervalSince1970: $0) },
                isHidden: payload.isHidden
            )
        }.sorted { lhs, rhs in
            if lhs.isNavigableDirectory != rhs.isNavigableDirectory {
                return lhs.isNavigableDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func runPython(host: String, script: String, arguments: [String]) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            throw RemoteFileSystemError.sshUnavailable
        }

        let scriptData = Data(script.utf8).base64EncodedString()
        let pythonCommand = "python3 -c 'import base64;exec(base64.b64decode(\"\(scriptData)\"))'"
        let remoteCommand = ([pythonCommand] + arguments.map { "'\($0)'" }).joined(separator: " ")

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-navigator-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "NumberOfPasswordPrompts=0",
            host,
            remoteCommand
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw RemoteFileSystemError.commandFailed(host: host, message: error.localizedDescription)
        }
        process.waitUntilExit()
        try? stdout.synchronize()
        try? stderr.synchronize()

        let output = (try? Data(contentsOf: stdoutURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RemoteFileSystemError.commandFailed(host: host, message: message)
        }
        return output
    }
}
