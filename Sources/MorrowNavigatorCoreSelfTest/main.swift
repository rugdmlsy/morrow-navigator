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
}

do {
    try run()
    print("MorrowNavigatorCoreSelfTest: PASS")
} catch {
    fputs("MorrowNavigatorCoreSelfTest: FAIL — \(error)\n", stderr)
    exit(1)
}
