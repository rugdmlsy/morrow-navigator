import Foundation
import MorrowNavigatorCore

struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SelfTestFailure(description: message)
    }
}

func run() throws {
    let service = FileSystemService()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("morrow-navigator-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("folder10"), withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("folder2"), withIntermediateDirectories: false)
    try Data("a".utf8).write(to: root.appendingPathComponent("file10.txt"))
    try Data("b".utf8).write(to: root.appendingPathComponent("file2.txt"))
    try Data().write(to: root.appendingPathComponent(".hidden.txt"))

    let visible = try service.children(of: root)
    try expect(
        visible.map(\.name) == ["folder2", "folder10", "file2.txt", "file10.txt"],
        "directories-first natural sorting failed: \(visible.map(\.name))"
    )

    let allNames = Set(try service.children(of: root, includeHidden: true).map(\.name))
    try expect(allNames.contains(".hidden.txt"), "includeHidden did not return hidden files")
    try expect(!visible.map(\.name).contains(".hidden.txt"), "hidden file leaked into default listing")

    let descendantRoot = URL(fileURLWithPath: "/tmp/work")
    try expect(service.isDescendant(URL(fileURLWithPath: "/tmp/work/src"), of: descendantRoot), "valid descendant rejected")
    try expect(!service.isDescendant(URL(fileURLWithPath: "/tmp/work-old"), of: descendantRoot), "sibling prefix accepted as descendant")

    let sshConfig = root.appendingPathComponent("ssh-config")
    let includedSSHConfig = root.appendingPathComponent("ssh-config-extra")
    try """
    Host included-host
        HostName 127.0.0.1
        User tester
        Port 2222
    """.write(to: includedSSHConfig, atomically: true, encoding: .utf8)
    try """
    Include \(includedSSHConfig.path)
    Host beta
        HostName beta.example.com
    Host *.internal
        User ignored
    Host alpha beta
        HostName shared.example.com
    Host github-lab
        HostName github.com
        User git
        IdentityFile ~/.ssh/github_lab_ed25519
    """.write(to: sshConfig, atomically: true, encoding: .utf8)
    let sshConfigDiscovery = SSHConfigDiscovery()
    let remoteHosts = sshConfigDiscovery.hosts(configURL: sshConfig)
    try expect(remoteHosts.map(\.alias) == ["alpha", "beta", "github-lab", "included-host"], "SSH host discovery failed: \(remoteHosts)")
    try expect(remoteHosts.first(where: { $0.alias == "beta" })?.hostname == "beta.example.com", "SSH hostname metadata was not parsed")
    try expect(remoteHosts.first(where: { $0.alias == "github-lab" })?.kind == .github, "GitHub SSH host was not classified")
    try expect(remoteHosts.first(where: { $0.alias == "github-lab" })?.endpointDescription == "git@github.com", "remote endpoint description was incorrect")
    try expect(remoteHosts.first(where: { $0.alias == "included-host" })?.endpointDescription == "tester@127.0.0.1:2222", "SSH Include metadata was not parsed")

    try sshConfigDiscovery.appendHost(
        .init(alias: "gamma", hostname: "10.0.0.8", user: "dev", port: 2202, identityFile: "~/.ssh/gamma_ed25519"),
        configURL: sshConfig
    )
    let updatedRemoteHosts = sshConfigDiscovery.hosts(configURL: sshConfig)
    let gamma = updatedRemoteHosts.first(where: { $0.alias == "gamma" })
    try expect(gamma?.kind == .sftp, "new SFTP host kind was incorrect")
    try expect(gamma?.endpointDescription == "dev@10.0.0.8:2202", "new SSH host endpoint was incorrect")
    let updatedSSHConfig = try String(contentsOf: sshConfig, encoding: .utf8)
    try expect(updatedSSHConfig.contains("Host gamma\n    HostName 10.0.0.8\n    User dev\n    Port 2202"), "new SSH host block was not written correctly")

    let repositoryShortcut = RemoteHost(
        alias: "github.com",
        hostname: "github.com",
        user: "git",
        kind: .github,
        displayName: "reslab-asu/agent-rollback-protocol",
        rootPath: "/reslab-asu/agent-rollback-protocol"
    )
    try expect(repositoryShortcut.displayTitle == "reslab-asu/agent-rollback-protocol", "remote shortcut display title was incorrect")
    try expect(repositoryShortcut.navigationLocation == FileSystemLocation(kind: .github, authority: "github.com", path: "/reslab-asu/agent-rollback-protocol"), "GitHub repository shortcut navigation path was incorrect")
    try expect(repositoryShortcut.endpointDescription == "github.com/reslab-asu/agent-rollback-protocol", "GitHub repository shortcut endpoint description was incorrect")
    let shortcutData = try JSONEncoder().encode([repositoryShortcut])
    let decodedShortcuts = try JSONDecoder().decode([RemoteHost].self, from: shortcutData)
    try expect(decodedShortcuts == [repositoryShortcut], "GitHub repository shortcut did not persist through Codable")

    let remoteRoot = FileSystemLocation(kind: .sftp, authority: "alpha", path: "/")
    let remoteChild = remoteRoot.appending("var").appending("log")
    try expect(remoteChild.displayPath == "alpha:/var/log", "remote path append failed: \(remoteChild.displayPath)")
    try expect(remoteChild.parent == FileSystemLocation(kind: .sftp, authority: "alpha", path: "/var"), "remote path parent failed")
    try expect(FileSystemLocation(url: remoteChild.url) == remoteChild, "remote URL round-trip failed: \(remoteChild.url)")
    let legacySSHURL = URL(string: "ssh://alpha/var/log")!
    try expect(FileSystemLocation(url: legacySSHURL) == remoteChild, "legacy ssh:// URL did not migrate to SFTP")
    try expect(remoteChild.url.scheme == "sftp", "SFTP location did not emit sftp:// URL")

    let remoteCache = FileSystemDirectoryCache(rootDirectory: root.appendingPathComponent("remote-cache", isDirectory: true))
    let cachedItem = FileInfo(
        url: remoteRoot.appending("etc").url,
        name: "etc",
        isDirectory: true,
        isPackage: false,
        size: nil,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        isHidden: false
    )
    let cachedAt = Date(timeIntervalSince1970: 1_700_000_100)
    try remoteCache.store([cachedItem], for: remoteRoot, savedAt: cachedAt)
    let cachedDirectory = remoteCache.cachedDirectory(remoteRoot)
    try expect(cachedDirectory?.items == [cachedItem], "remote directory cache did not round-trip items")
    try expect(cachedDirectory?.savedAt == cachedAt, "remote directory cache did not preserve timestamp")

    let parsed = try NavigatorCommandLine.tokenize("mv 'file 1.txt' \"folder 2/file 2.txt\"").get()
    try expect(parsed == ["mv", "file 1.txt", "folder 2/file 2.txt"], "command quoting failed: \(parsed)")

    let shortPrefixed = try NavigatorCommandLine.tokenize("mnavi pwd").get()
    try expect(shortPrefixed == ["pwd"], "mnavi prefix was not stripped: \(shortPrefixed)")
    let officialPrefixed = try NavigatorCommandLine.tokenize("morrow-navigator pwd").get()
    try expect(officialPrefixed == ["pwd"], "morrow-navigator prefix was not stripped: \(officialPrefixed)")
    let reservedTopLevel = try NavigatorCommandLine.tokenize("morrow pwd").get()
    try expect(reservedTopLevel == ["morrow", "pwd"], "reserved top-level morrow namespace was consumed")

    let engine = NavigatorCommandEngine()
    let reservedResult = engine.execute(arguments: ["morrow", "pwd"], baseDirectory: root, workspaceRoot: root)
    try expect(!reservedResult.success, "Navigator unexpectedly claimed the top-level morrow command")
    let mkdir = engine.execute(arguments: ["mkdir", "notes"], baseDirectory: root, workspaceRoot: root)
    try expect(mkdir.success, "mkdir command failed: \(mkdir.output)")
    try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes").path), "mkdir did not create directory")

    let touch = engine.execute(arguments: ["touch", "draft.txt"], baseDirectory: root, workspaceRoot: root)
    try expect(touch.success, "touch command failed: \(touch.output)")
    try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("draft.txt").path), "touch did not create file")

    let move = engine.execute(arguments: ["mv", "draft.txt", "notes/final.txt"], baseDirectory: root, workspaceRoot: root)
    try expect(move.success, "mv command failed: \(move.output)")
    try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/final.txt").path), "mv did not move file")

    let workspaceState = engine.execute(arguments: ["ws"], baseDirectory: root, workspaceRoot: root)
    try expect(workspaceState.success && workspaceState.output == root.path, "ws did not report workspace root")

    let childWorkspace = engine.execute(arguments: ["ws", "notes"], baseDirectory: root, workspaceRoot: root)
    try expect(childWorkspace.effect == .workspace(root.appendingPathComponent("notes").path), "ws child did not retarget workspace")

    let parent = root.deletingLastPathComponent().standardizedFileURL
    let cdOutside = engine.execute(arguments: ["cd", ".."], baseDirectory: root, workspaceRoot: root)
    try expect(cdOutside.success, "cd .. at workspace root should promote the parent")
    try expect(cdOutside.effect == .workspace(parent.path), "cd .. did not promote parent to workspace: \(cdOutside.effect)")

    let resizeSidebar = engine.execute(arguments: ["ui", "sidebar", "333"], baseDirectory: root, workspaceRoot: root)
    try expect(resizeSidebar.effect == .uiSidebarWidth(333), "ui sidebar did not parse width: \(resizeSidebar.effect)")

    let sftpHost = ProcessInfo.processInfo.environment["MORROW_NAVIGATOR_TEST_SFTP_HOST"]
        ?? ProcessInfo.processInfo.environment["MORROW_NAVIGATOR_TEST_SSH_HOST"]
    if let sftpHost, !sftpHost.isEmpty {
        let remoteItems = try UnifiedFileSystemService().children(of: FileSystemLocation(kind: .sftp, authority: sftpHost, path: "/"))
        try expect(!remoteItems.isEmpty, "remote root listing was unexpectedly empty for \(sftpHost)")
        try expect(remoteItems.allSatisfy { FileSystemLocation(url: $0.url)?.authority == sftpHost }, "remote listing returned invalid URLs")
        let remotePreviewData = try UnifiedFileSystemService().fileContents(
            of: FileSystemLocation(kind: .sftp, authority: sftpHost, path: "/etc/hostname"),
            maxBytes: 64 * 1024
        )
        try expect(!remotePreviewData.isEmpty, "remote file preview read returned empty data for \(sftpHost)")
        print("Remote SFTP integration: PASS (\(sftpHost), \(remoteItems.count) root items, preview read \(remotePreviewData.count) bytes)")
    }

    if let githubHost = ProcessInfo.processInfo.environment["MORROW_NAVIGATOR_TEST_GITHUB_HOST"], !githubHost.isEmpty {
        let githubService = UnifiedFileSystemService()
                let accessibleRepositories = try githubService.githubRepositories()
        try expect(!accessibleRepositories.isEmpty, "GitHub repository picker source was empty")
        let owner = ProcessInfo.processInfo.environment["MORROW_NAVIGATOR_TEST_GITHUB_OWNER"]
        let rootItems = try githubService.children(of: FileSystemLocation(kind: .github, authority: githubHost, path: "/"))
        try expect(!rootItems.isEmpty, "GitHub root did not return items")
        let scopedOwner = githubHost.lowercased().hasPrefix("github-") ? String(githubHost.dropFirst("github-".count)) : nil
        let repositories: [FileInfo]
        if let scopedOwner {
            try expect(owner == nil || owner == scopedOwner, "GitHub alias owner scope mismatch: \(githubHost) -> \(scopedOwner)")
            repositories = rootItems
        } else {
            let selectedOwner = owner ?? rootItems[0].name
            repositories = try githubService.children(of: FileSystemLocation(kind: .github, authority: githubHost, path: "/\(selectedOwner)"))
        }
        try expect(!repositories.isEmpty, "GitHub repository list was empty for \(githubHost)")
        let repository = ProcessInfo.processInfo.environment["MORROW_NAVIGATOR_TEST_GITHUB_REPO"] ?? repositories[0].name
        try expect(repositories.contains(where: { $0.name == repository }), "GitHub repository \(repository) was not visible at the expected level")
        if let owner {
            try expect(accessibleRepositories.contains(where: { $0.fullName == "\(owner)/\(repository)" }), "GitHub repository picker did not expose \(owner)/\(repository)")
        }
        let repositoryPath = scopedOwner == nil
            ? "/\(owner ?? rootItems[0].name)/\(repository)"
            : "/\(repository)"
        let repositoryItems = try githubService.children(
            of: FileSystemLocation(kind: .github, authority: githubHost, path: repositoryPath)
        )
        try expect(!repositoryItems.isEmpty, "GitHub repository \(repository) root was unexpectedly empty")
        if let previewFile = repositoryItems.first(where: { !$0.isDirectory }),
           let previewLocation = FileSystemLocation(url: previewFile.url) {
            let previewData = try githubService.fileContents(of: previewLocation, maxBytes: 2 * 1024 * 1024)
            try expect(!previewData.isEmpty, "GitHub file preview read returned empty data for \(previewFile.name)")
        } else {
            throw SelfTestFailure(description: "GitHub repository had no root file available for preview integration test")
        }
        print("GitHub integration: PASS (\(githubHost), \(repository), \(repositoryItems.count) root items, preview read PASS)")
    }
}

do {
    try run()
    print("MorrowNavigatorCoreSelfTest: PASS")
} catch {
    fputs("MorrowNavigatorCoreSelfTest: FAIL — \(error)\n", stderr)
    exit(1)
}
