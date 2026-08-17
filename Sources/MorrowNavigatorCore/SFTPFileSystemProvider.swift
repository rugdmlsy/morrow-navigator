import Foundation

public enum SFTPFileSystemError: LocalizedError, Sendable {
    case unavailable
    case missingAuthority
    case invalidResponse(String)
    case commandFailed(host: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The system SFTP client is unavailable."
        case .missingAuthority:
            return "The SFTP location does not specify a host."
        case .invalidResponse(let host):
            return "\(host) returned an invalid SFTP response."
        case .commandFailed(let host, let message):
            return message.isEmpty ? "Unable to connect to \(host) over SFTP." : "\(host): \(message)"
        }
    }
}

public struct SFTPFileSystemProvider: FileSystemProvider {
    public let kind: FileSystemKind = .sftp
    private let sftpPath: String

    public init(sftpPath: String? = nil) {
        self.sftpPath = sftpPath ?? Self.defaultSFTPPath()
    }

    public func homeDirectory(authority: String) throws -> FileSystemLocation {
        let output = try runSFTP(authority: authority, commands: ["pwd"])
        guard let line = output.split(whereSeparator: \.isNewline).map(String.init).first(where: {
            $0.hasPrefix("Remote working directory:")
        }) else {
            throw SFTPFileSystemError.invalidResponse(authority)
        }
        let path = line.dropFirst("Remote working directory:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { throw SFTPFileSystemError.invalidResponse(authority) }
        return FileSystemLocation(kind: .sftp, authority: authority, path: path)
    }

    public func info(at location: FileSystemLocation) throws -> FileInfo {
        let authority = try requireSFTP(location)
        if location.path == "/" {
            return FileInfo(
                url: location.url,
                name: location.name,
                isDirectory: true,
                isPackage: false,
                size: nil,
                modifiedAt: nil,
                isHidden: false
            )
        }
        guard let item = try children(of: location.parent, includeHidden: true)
            .first(where: { $0.location == location }) else {
            throw SFTPFileSystemError.invalidResponse(authority)
        }
        return item
    }

    public func children(of location: FileSystemLocation, includeHidden: Bool = false) throws -> [FileInfo] {
        let authority = try requireSFTP(location)
        let output = try runSFTP(
            authority: authority,
            commands: ["ls -la \(quoteSFTP(location.path))"]
        )
        return parseLongListing(output, base: location)
            .filter { $0.name != "." && $0.name != ".." }
            .filter { includeHidden || !$0.isHidden }
            .sorted(by: FileInfo.navigationSort)
    }

    public func fileContents(of location: FileSystemLocation, maxBytes: Int = 8 * 1024 * 1024) throws -> Data {
        let authority = try requireSFTP(location)
        guard maxBytes > 0 else { return Data() }

        let metadata = try info(at: location)
        if let size = metadata.size, size > Int64(maxBytes) {
            throw FileSystemError.fileTooLarge(maxBytes: maxBytes)
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-navigator-sftp-get-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let destination = temporaryDirectory.appendingPathComponent("payload")

        _ = try runSFTP(
            authority: authority,
            commands: ["get \(quoteSFTP(location.path)) \(quoteSFTP(destination.path))"]
        )
        let data = try Data(contentsOf: destination)
        guard data.count <= maxBytes else { throw FileSystemError.fileTooLarge(maxBytes: maxBytes) }
        return data
    }

    private func requireSFTP(_ location: FileSystemLocation) throws -> String {
        guard location.kind == .sftp else {
            throw FileSystemError.wrongProvider(expected: .sftp, actual: location.kind)
        }
        guard let authority = location.authority, !authority.isEmpty else {
            throw SFTPFileSystemError.missingAuthority
        }
        guard FileManager.default.isExecutableFile(atPath: sftpPath) else {
            throw SFTPFileSystemError.unavailable
        }
        return authority
    }

    private func parseLongListing(_ output: String, base: FileSystemLocation) -> [FileInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("sftp>"),
                  !line.hasPrefix("Connected to ") else { return nil }

            let fields = line.split(maxSplits: 8, whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 9,
                  let type = fields[0].first,
                  "bcdlps-".contains(type),
                  let size = Int64(fields[4]) else { return nil }

            var name = fields[8]
            if type == "l", let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }
            if name == base.path + "/." || (base.path == "/" && name == "/.") {
                name = "."
            } else if name == base.path + "/.." || (base.path == "/" && name == "/..") {
                name = ".."
            } else if name.hasPrefix("/") {
                name = (name as NSString).lastPathComponent
            }
            guard !name.isEmpty else { return nil }

            let isDirectory = type == "d"
            let itemLocation = name == "." ? base : (name == ".." ? base.parent : base.appending(name))
            return FileInfo(
                url: itemLocation.url,
                name: name,
                isDirectory: isDirectory,
                isPackage: false,
                size: isDirectory ? nil : size,
                modifiedAt: parseListingDate(month: fields[5], day: fields[6], timeOrYear: fields[7]),
                isHidden: name.hasPrefix(".") && name != "." && name != ".."
            )
        }
    }

    private func parseListingDate(month: String, day: String, timeOrYear: String) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        let currentYear = calendar.component(.year, from: Date())
        let value: String
        let format: String
        if timeOrYear.contains(":") {
            value = "\(month) \(day) \(currentYear) \(timeOrYear)"
            format = "MMM d yyyy HH:mm"
        } else {
            value = "\(month) \(day) \(timeOrYear)"
            format = "MMM d yyyy"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.date(from: value)
    }

    private func quoteSFTP(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func runSFTP(authority: String, commands: [String]) throws -> String {
        do {
            return try runSFTPOnce(authority: authority, commands: commands)
        } catch let error as SFTPFileSystemError {
            guard case .commandFailed(_, let message) = error,
                  isTransientConnectionFailure(message) else {
                throw error
            }
            return try runSFTPOnce(authority: authority, commands: commands)
        }
    }

    private func runSFTPOnce(authority: String, commands: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: sftpPath) else {
            throw SFTPFileSystemError.unavailable
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("morrow-navigator-sftp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let batchURL = temporaryDirectory.appendingPathComponent("batch")
        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        try (commands.joined(separator: "\n") + "\n").write(to: batchURL, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sftpPath)
        process.arguments = [
            "-q",
            "-b", batchURL.path,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ConnectionAttempts=1",
            "-o", "NumberOfPasswordPrompts=0",
            authority
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw SFTPFileSystemError.commandFailed(host: authority, message: error.localizedDescription)
        }
        process.waitUntilExit()
        try? stdout.synchronize()
        try? stderr.synchronize()

        let outputData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SFTPFileSystemError.commandFailed(host: authority, message: message)
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private func isTransientConnectionFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("connection closed")
            || normalized.contains("connection reset")
            || normalized.contains("connection timed out")
            || normalized.contains("operation timed out")
    }

    private static func defaultSFTPPath() -> String {
        ["/usr/bin/sftp", "/opt/homebrew/bin/sftp", "/usr/local/bin/sftp"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/sftp"
    }
}
