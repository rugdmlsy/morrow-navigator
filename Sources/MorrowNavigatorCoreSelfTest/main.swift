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

    let cdOutside = engine.execute(arguments: ["cd", ".."], baseDirectory: root, workspaceRoot: root)
    try expect(!cdOutside.success, "cd unexpectedly escaped workspace")
}

do {
    try run()
    print("MorrowNavigatorCoreSelfTest: PASS")
} catch {
    fputs("MorrowNavigatorCoreSelfTest: FAIL — \(error)\n", stderr)
    exit(1)
}
