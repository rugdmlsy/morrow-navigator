import AppKit
import MorrowNavigatorCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var commandServer: CommandIPCServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureMainMenu()

        let savedPath = UserDefaults.standard.string(forKey: "lastWorkspacePath")
        let savedURL = savedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let initialURL = savedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        let controller = MainWindowController(initialWorkspace: initialURL)
        windowController = controller
        commandServer = CommandIPCServer { [weak controller] arguments in
            controller?.executeCommand(arguments: arguments) ?? .failure("Navigator window is unavailable.")
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Morrow Navigator", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Morrow Navigator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quit)

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let openWorkspace = NSMenuItem(title: "Open Folder as Workspace…", action: #selector(openWorkspace), keyEquivalent: "o")
        openWorkspace.keyEquivalentModifierMask = [.command]
        openWorkspace.target = self
        fileMenu.addItem(openWorkspace)
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "")
        reveal.target = self
        fileMenu.addItem(reveal)

        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goItem.submenu = goMenu
        let back = NSMenuItem(title: "Back", action: #selector(goBack), keyEquivalent: "[")
        back.keyEquivalentModifierMask = [.command]
        back.target = self
        goMenu.addItem(back)
        let forward = NSMenuItem(title: "Forward", action: #selector(goForward), keyEquivalent: "]")
        forward.keyEquivalentModifierMask = [.command]
        forward.target = self
        goMenu.addItem(forward)
        goMenu.addItem(.separator())
        let parentWorkspace = NSMenuItem(title: "Use Parent Folder as Workspace", action: #selector(useParentAsWorkspace), keyEquivalent: "")
        parentWorkspace.target = self
        goMenu.addItem(parentWorkspace)
        let currentWorkspace = NSMenuItem(title: "Use Current Folder as Workspace", action: #selector(useCurrentAsWorkspace), keyEquivalent: "")
        currentWorkspace.target = self
        goMenu.addItem(currentWorkspace)

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refresh.keyEquivalentModifierMask = [.command]
        refresh.target = self
        viewMenu.addItem(refresh)
        let focusCommand = NSMenuItem(title: "Focus Command", action: #selector(focusCommand), keyEquivalent: "l")
        focusCommand.keyEquivalentModifierMask = [.command]
        focusCommand.target = self
        viewMenu.addItem(focusCommand)
    }

    @objc private func openWorkspace() {
        windowController?.chooseWorkspace()
    }

    @objc private func revealInFinder() {
        windowController?.revealSelectedInFinder()
    }

    @objc private func goBack() {
        windowController?.goBack()
    }

    @objc private func goForward() {
        windowController?.goForward()
    }

    @objc private func useParentAsWorkspace() {
        windowController?.useParentAsWorkspace()
    }

    @objc private func useCurrentAsWorkspace() {
        windowController?.useCurrentDirectoryAsWorkspace()
    }

    @objc private func refresh() {
        windowController?.refresh()
    }

    @objc private func focusCommand() {
        _ = windowController?.executeCommand(arguments: ["ui", "focus"])
    }
}
