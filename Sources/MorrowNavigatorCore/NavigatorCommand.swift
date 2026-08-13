import Foundation

public enum NavigatorCommandEffect: Sendable, Equatable, Codable {
    case none
    case refresh
    case refreshAndSelect(String)
    case navigate(String)
    case workspace(String)
    case select(String)
    case open(String)
    case reveal(String)
    case back
    case forward
    case uiFocusCommand
    case uiShow
    case uiState
}

public struct NavigatorCommandResult: Sendable, Equatable, Codable {
    public let success: Bool
    public let output: String
    public let effect: NavigatorCommandEffect

    public init(success: Bool, output: String = "", effect: NavigatorCommandEffect = .none) {
        self.success = success
        self.output = output
        self.effect = effect
    }

    public static func ok(_ output: String = "", effect: NavigatorCommandEffect = .none) -> Self {
        .init(success: true, output: output, effect: effect)
    }

    public static func failure(_ output: String) -> Self {
        .init(success: false, output: output)
    }
}

public enum NavigatorCommandLine {
    public static func tokenize(_ line: String) -> Result<[String], NavigatorCommandLineError> {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var hasToken = false

        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                hasToken = true
                continue
            }

            if character == "\\" && quote != "'" {
                escaping = true
                hasToken = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasToken = true
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken {
                    arguments.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }

        if escaping {
            current.append("\\")
        }
        if quote != nil {
            return .failure(.unterminatedQuote)
        }
        if hasToken {
            arguments.append(current)
        }

        if let first = arguments.first?.lowercased(),
           first == "morrow-navigator" || first == "mnavi" {
            arguments.removeFirst()
        }
        return .success(arguments)
    }
}

public enum NavigatorCommandLineError: Error, LocalizedError {
    case unterminatedQuote

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote: "Unterminated quote"
        }
    }
}

public struct NavigatorCommandEngine {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func execute(
        arguments originalArguments: [String],
        baseDirectory: URL,
        workspaceRoot: URL?
    ) -> NavigatorCommandResult {
        var arguments = originalArguments
        if let first = arguments.first?.lowercased(),
           first == "morrow-navigator" || first == "mnavi" {
            arguments.removeFirst()
        }
        guard let rawCommand = arguments.first else {
            return .ok(helpText)
        }
        let command = rawCommand.lowercased()
        let args = Array(arguments.dropFirst())

        do {
            switch command {
            case "help", "?":
                return .ok(helpText)
            case "pwd":
                return .ok(baseDirectory.path)
            case "ls":
                return try list(args: args, baseDirectory: baseDirectory)
            case "cd":
                guard args.count == 1 else { return usage("cd <directory>") }
                let url = resolve(args[0], relativeTo: baseDirectory)
                guard try isNavigableDirectory(url) else { return .failure("Not a directory: \(url.path)") }
                if let workspaceRoot,
                   !FileSystemService(fileManager: fileManager).isDescendant(url, of: workspaceRoot) {
                    return .failure("Outside workspace. Use 'workspace <directory>' to change the workspace root.")
                }
                return .ok(url.path, effect: .navigate(url.path))
            case "workspace", "ws":
                guard args.count == 1 else { return usage("workspace <directory>") }
                let url = resolve(args[0], relativeTo: baseDirectory)
                guard try isNavigableDirectory(url) else { return .failure("Not a directory: \(url.path)") }
                return .ok(url.path, effect: .workspace(url.path))
            case "mkdir":
                return try makeDirectories(args: args, baseDirectory: baseDirectory)
            case "touch", "new":
                return try touch(args: args, baseDirectory: baseDirectory)
            case "rm":
                return try remove(args: args, baseDirectory: baseDirectory)
            case "mv", "rename":
                return try move(args: args, baseDirectory: baseDirectory)
            case "cp":
                return try copy(args: args, baseDirectory: baseDirectory)
            case "open":
                guard args.count == 1 else { return usage("open <path>") }
                let url = resolve(args[0], relativeTo: baseDirectory)
                guard fileManager.fileExists(atPath: url.path) else { return .failure("No such file: \(url.path)") }
                return .ok(url.path, effect: .open(url.path))
            case "reveal":
                guard args.count <= 1 else { return usage("reveal [path]") }
                let url = args.first.map { resolve($0, relativeTo: baseDirectory) } ?? baseDirectory
                guard fileManager.fileExists(atPath: url.path) else { return .failure("No such file: \(url.path)") }
                return .ok(url.path, effect: .reveal(url.path))
            case "select":
                guard args.count == 1 else { return usage("select <path>") }
                let url = resolve(args[0], relativeTo: baseDirectory)
                guard fileManager.fileExists(atPath: url.path) else { return .failure("No such file: \(url.path)") }
                return .ok(url.path, effect: .select(url.path))
            case "refresh":
                return .ok("refreshed", effect: .refresh)
            case "back":
                return .ok(effect: .back)
            case "forward":
                return .ok(effect: .forward)
            case "ui":
                return ui(args: args)
            default:
                return .failure("Unknown command: \(rawCommand). Run 'help' for commands.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func list(args: [String], baseDirectory: URL) throws -> NavigatorCommandResult {
        var includeHidden = false
        var paths: [String] = []
        for arg in args {
            if arg == "-a" || arg == "--all" { includeHidden = true }
            else { paths.append(arg) }
        }
        guard paths.count <= 1 else { return usage("ls [-a] [directory]") }
        let directory = paths.first.map { resolve($0, relativeTo: baseDirectory) } ?? baseDirectory
        let items = try FileSystemService(fileManager: fileManager).children(of: directory, includeHidden: includeHidden)
        let output = items.map { $0.name + ($0.isNavigableDirectory ? "/" : "") }.joined(separator: "\n")
        return .ok(output)
    }

    private func makeDirectories(args: [String], baseDirectory: URL) throws -> NavigatorCommandResult {
        let recursive = args.contains("-p")
        let paths = args.filter { $0 != "-p" }
        guard !paths.isEmpty else { return usage("mkdir [-p] <path> [...]") }
        for path in paths {
            let url = resolve(path, relativeTo: baseDirectory)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: recursive)
        }
        return .ok("created \(paths.count) director\(paths.count == 1 ? "y" : "ies")", effect: .refresh)
    }

    private func touch(args: [String], baseDirectory: URL) throws -> NavigatorCommandResult {
        guard !args.isEmpty else { return usage("touch <path> [...]") }
        for path in args {
            let url = resolve(path, relativeTo: baseDirectory)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } else {
                guard fileManager.createFile(atPath: url.path, contents: Data()) else {
                    return .failure("Unable to create: \(url.path)")
                }
            }
        }
        return .ok("touched \(args.count) item\(args.count == 1 ? "" : "s")", effect: .refresh)
    }

    private func remove(args: [String], baseDirectory: URL) throws -> NavigatorCommandResult {
        let recursiveFlags: Set<String> = ["-r", "-R", "-rf", "-fr"]
        let recursive = args.contains { recursiveFlags.contains($0) }
        let paths = args.filter { !recursiveFlags.contains($0) }
        guard !paths.isEmpty else { return usage("rm [-r] <path> [...]") }

        for path in paths {
            let url = resolve(path, relativeTo: baseDirectory)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return .failure("No such file: \(url.path)")
            }
            if isDirectory.boolValue && !recursive {
                let children = try fileManager.contentsOfDirectory(atPath: url.path)
                if !children.isEmpty {
                    return .failure("Directory not empty (use rm -r): \(url.path)")
                }
            }
            try fileManager.removeItem(at: url)
        }
        return .ok("removed \(paths.count) item\(paths.count == 1 ? "" : "s")", effect: .refresh)
    }

    private func move(args: [String], baseDirectory: URL) throws -> NavigatorCommandResult {
        guard args.count == 2 else { return usage("mv <source> <destination>") }
        let source = resolve(args[0], relativeTo: baseDirectory)
        var destination = resolve(args[1], relativeTo: baseDirectory)
        if (try? isNavigableDirectory(destination)) == true {
            destination.appendPathComponent(source.lastPathComponent)
        }
        try fileManager.moveItem(at: source, to: destination)
        return .ok(destination.path, effect: .refreshAndSelect(destination.path))
    }

    private func copy(args: [String], baseDirectory: URL) throws -> NavigatorCommandResult {
        let recursiveFlags: Set<String> = ["-r", "-R"]
        let paths = args.filter { !recursiveFlags.contains($0) }
        guard paths.count == 2 else { return usage("cp [-r] <source> <destination>") }
        let source = resolve(paths[0], relativeTo: baseDirectory)
        var destination = resolve(paths[1], relativeTo: baseDirectory)
        if (try? isNavigableDirectory(destination)) == true {
            destination.appendPathComponent(source.lastPathComponent)
        }
        try fileManager.copyItem(at: source, to: destination)
        return .ok(destination.path, effect: .refreshAndSelect(destination.path))
    }

    private func ui(args: [String]) -> NavigatorCommandResult {
        guard let subcommand = args.first?.lowercased(), args.count == 1 else {
            return usage("ui <focus|show|state>")
        }
        switch subcommand {
        case "focus", "command": return .ok(effect: .uiFocusCommand)
        case "show": return .ok(effect: .uiShow)
        case "state": return .ok(effect: .uiState)
        default: return usage("ui <focus|show|state>")
        }
    }

    private func resolve(_ path: String, relativeTo baseDirectory: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return baseDirectory.appendingPathComponent(expanded).standardizedFileURL
    }

    private func isNavigableDirectory(_ url: URL) throws -> Bool {
        let info = try FileSystemService(fileManager: fileManager).info(for: url)
        return info.isNavigableDirectory
    }

    private func usage(_ value: String) -> NavigatorCommandResult {
        .failure("Usage: \(value)")
    }

    public var helpText: String {
        """
        pwd                         current Navigator directory
        ls [-a] [dir]               list files
        cd <dir>                    navigate
        workspace|ws <dir>          change workspace
        mkdir [-p] <path> [...]     create directories
        touch|new <path> [...]      create/touch files
        mv|rename <src> <dst>       move or rename
        cp [-r] <src> <dst>         copy
        rm [-r] <path> [...]        remove
        open <path>                 open with default app
        reveal [path]               reveal in Finder
        select <path>               select in Navigator
        refresh | back | forward    navigation controls
        ui focus | ui show | ui state
        help
        """
    }
}
