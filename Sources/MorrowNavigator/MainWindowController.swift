import AppKit
import MorrowNavigatorCore

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centeredRect(for bounds: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: bounds)
        let height = cellSize(forBounds: bounds).height
        if rect.height > height {
            rect.origin.y += (rect.height - height) / 2
            rect.size.height = height
        }
        return rect
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(for: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(withFrame: centeredRect(for: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: centeredRect(for: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

private final class CommandTextField: NSTextField {
    var onFocusRequest: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        onFocusRequest?()
        return super.becomeFirstResponder()
    }
}

private final class NonInteractiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class InstantOutlineView: NSOutlineView {
    private func beginInstantUpdates() {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
    }

    private func endInstantUpdates() {
        NSAnimationContext.endGrouping()
    }

    override func expandItem(_ item: Any?) {
        beginInstantUpdates()
        super.expandItem(item)
        endInstantUpdates()
    }

    override func collapseItem(_ item: Any?) {
        beginInstantUpdates()
        super.collapseItem(item)
        endInstantUpdates()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        if clickedRow >= 0,
           let node = item(atRow: clickedRow) as? FileNode,
           node.info.isNavigableDirectory {
            // The whole row is the interaction target. The disclosure triangle is
            // presentation only and never receives separate click behavior.
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            if isItemExpanded(node) {
                collapseItem(node)
            } else {
                expandItem(node)
            }
            return
        }

        beginInstantUpdates()
        super.mouseDown(with: event)
        endInstantUpdates()
    }

    override func keyDown(with event: NSEvent) {
        beginInstantUpdates()
        super.keyDown(with: event)
        endInstantUpdates()
    }
}

@MainActor
final class MainWindowController: NSWindowController {
    private let fileSystem = FileSystemService()
    private let commandEngine = NavigatorCommandEngine()
    private let directoryWatcher = DirectoryWatcher()
    private let iconCache = NSCache<NSString, NSImage>()

    private var rootNode: FileNode?
    private var currentDirectory: URL?
    private var tableItems: [FileInfo] = []
    private var history: [URL] = []
    private var historyIndex = -1
    private var suppressOutlineSelection = false

    private let outlineView = InstantOutlineView()
    private let tableView = NSTableView()
    private let workspaceLabel = NSTextField(labelWithString: "")
    private let pathControl = NSPathControl()
    private let statusLabel = NSTextField(labelWithString: "")
    private let commandOutputLabel = NSTextField(labelWithString: "")
    private let commandOutputHitArea = NSView()
    private let commandField = CommandTextField()
    private let commandPlaceholderLabel = NonInteractiveLabel(labelWithString: "Command · help for available commands")
    private var lastCommandOutput = ""
    private var commandOutputPopover: NSPopover?
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let workspaceParentButton = NSButton()
    private let workspaceCurrentButton = NSButton()

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    convenience init(initialWorkspace: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Morrow Navigator"
        window.minSize = NSSize(width: 760, height: 480)
        window.center()
        window.tabbingMode = .preferred
        self.init(window: window)

        configureUI()
        iconCache.countLimit = 256

        let workspace = initialWorkspace ?? FileManager.default.homeDirectoryForCurrentUser
        setWorkspace(workspace)
    }

    private override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUI() {
        guard let contentView = window?.contentView else { return }

        let splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebar = makeSidebar()
        let browser = makeBrowser()

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(browser)
        contentView.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])

        sidebar.setFrameSize(NSSize(width: 260, height: 720))
        browser.setFrameSize(NSSize(width: 860, height: 720))
    }

    private func makeSidebar() -> NSView {
        let container = SidebarBackgroundView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let explorerLabel = NSTextField(labelWithString: "EXPLORER")
        explorerLabel.translatesAutoresizingMaskIntoConstraints = false
        explorerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        explorerLabel.textColor = .secondaryLabelColor

        workspaceLabel.translatesAutoresizingMaskIntoConstraints = false
        workspaceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        workspaceLabel.lineBreakMode = .byTruncatingMiddle
        workspaceLabel.maximumNumberOfLines = 1

        configureSymbolButton(workspaceParentButton, symbol: "arrow.up", action: #selector(useParentAsWorkspace))
        workspaceParentButton.toolTip = "Use Parent Folder as Workspace"
        configureSymbolButton(workspaceCurrentButton, symbol: "scope", action: #selector(useCurrentDirectoryAsWorkspace))
        workspaceCurrentButton.toolTip = "Use Current Folder as Workspace"
        let chooseButton = symbolButton("folder.badge.plus", action: #selector(chooseWorkspace))
        chooseButton.toolTip = "Open Folder as Workspace…"
        let refreshButton = symbolButton("arrow.clockwise", action: #selector(refresh))
        refreshButton.toolTip = "Refresh"

        let buttonStack = NSStackView(views: [workspaceParentButton, workspaceCurrentButton, chooseButton, refreshButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 2

        let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Explorer"))
        outlineColumn.resizingMask = .autoresizingMask
        outlineView.addTableColumn(outlineColumn)
        outlineView.outlineTableColumn = outlineColumn
        outlineView.headerView = nil
        outlineView.rowHeight = 23
        outlineView.indentationPerLevel = 14
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineDoubleClicked)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        container.addSubview(explorerLabel)
        container.addSubview(workspaceLabel)
        container.addSubview(buttonStack)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            explorerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            explorerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),

            workspaceLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            workspaceLabel.topAnchor.constraint(equalTo: explorerLabel.bottomAnchor, constant: 10),
            workspaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -6),

            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            buttonStack.centerYAnchor.constraint(equalTo: workspaceLabel.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: workspaceLabel.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func makeBrowser() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.bezelStyle = .inline
        backButton.isBordered = false
        backButton.toolTip = "Back"

        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        forwardButton.bezelStyle = .inline
        forwardButton.isBordered = false
        forwardButton.toolTip = "Forward"

        let navigationStack = NSStackView(views: [backButton, forwardButton])
        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        navigationStack.orientation = .horizontal
        navigationStack.spacing = 7

        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.font = .systemFont(ofSize: 12)

        let revealButton = symbolButton("arrow.forward.square", action: #selector(revealSelectedInFinder))
        revealButton.toolTip = "Reveal in Finder"
        let refreshButton = symbolButton("arrow.clockwise", action: #selector(refresh))
        refreshButton.toolTip = "Refresh"

        let actionStack = NSStackView(views: [revealButton, refreshButton])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .horizontal
        actionStack.spacing = 5

        let headerSeparator = NSBox()
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.boxType = .separator

        configureTable()
        let tableScroll = NSScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = false
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .noBorder

        let commandSeparator = NSBox()
        commandSeparator.translatesAutoresizingMaskIntoConstraints = false
        commandSeparator.boxType = .separator

        commandOutputHitArea.translatesAutoresizingMaskIntoConstraints = false
        commandOutputHitArea.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(showFullCommandOutput))
        )

        commandOutputLabel.translatesAutoresizingMaskIntoConstraints = false
        commandOutputLabel.font = .systemFont(ofSize: 11, weight: .medium)
        commandOutputLabel.textColor = .labelColor
        commandOutputLabel.lineBreakMode = .byTruncatingTail
        commandOutputLabel.maximumNumberOfLines = 1
        commandOutputLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandOutputLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commandOutputLabel.toolTip = "Click to view full command output"
        commandOutputHitArea.addSubview(commandOutputLabel)

        let commandInputBackground = NSVisualEffectView()
        commandInputBackground.translatesAutoresizingMaskIntoConstraints = false
        commandInputBackground.material = .hudWindow
        commandInputBackground.blendingMode = .withinWindow
        commandInputBackground.state = .active
        commandInputBackground.wantsLayer = true
        commandInputBackground.layer?.cornerRadius = 6
        commandInputBackground.layer?.masksToBounds = true
        commandInputBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.48).cgColor

        let promptLabel = NSTextField(labelWithString: ">")
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        promptLabel.textColor = NSColor.white.withAlphaComponent(0.95)

        commandField.translatesAutoresizingMaskIntoConstraints = false
        commandField.cell = VerticallyCenteredTextFieldCell(textCell: "")
        commandField.isEditable = true
        commandField.isSelectable = true
        commandField.isEnabled = true
        commandField.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        commandField.textColor = NSColor.white.withAlphaComponent(0.95)
        commandField.delegate = self
        commandField.focusRingType = .none
        commandField.isBordered = false
        commandField.drawsBackground = false
        commandField.target = self
        commandField.action = #selector(runCommandField)
        commandField.onFocusRequest = { [weak self] in
            self?.hideCommandPlaceholder()
        }

        commandPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        commandPlaceholderLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        commandPlaceholderLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        commandPlaceholderLabel.lineBreakMode = .byTruncatingTail
        commandPlaceholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandPlaceholderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        commandInputBackground.addSubview(promptLabel)
        commandInputBackground.addSubview(commandPlaceholderLabel)
        commandInputBackground.addSubview(commandField)

        let statusSeparator = NSBox()
        statusSeparator.translatesAutoresizingMaskIntoConstraints = false
        statusSeparator.boxType = .separator

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        container.addSubview(navigationStack)
        container.addSubview(pathControl)
        container.addSubview(actionStack)
        container.addSubview(headerSeparator)
        container.addSubview(tableScroll)
        container.addSubview(commandSeparator)
        container.addSubview(commandOutputHitArea)
        container.addSubview(commandInputBackground)
        container.addSubview(statusSeparator)
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            navigationStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            navigationStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            navigationStack.heightAnchor.constraint(equalToConstant: 24),

            pathControl.leadingAnchor.constraint(equalTo: navigationStack.trailingAnchor, constant: 10),
            pathControl.centerYAnchor.constraint(equalTo: navigationStack.centerYAnchor),
            pathControl.trailingAnchor.constraint(equalTo: actionStack.leadingAnchor, constant: -10),

            actionStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            actionStack.centerYAnchor.constraint(equalTo: navigationStack.centerYAnchor),

            headerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerSeparator.topAnchor.constraint(equalTo: navigationStack.bottomAnchor, constant: 8),

            tableScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: commandSeparator.topAnchor),

            commandSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            commandSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            commandSeparator.bottomAnchor.constraint(equalTo: commandOutputHitArea.topAnchor),

            commandOutputHitArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            commandOutputHitArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            commandOutputHitArea.bottomAnchor.constraint(equalTo: commandInputBackground.topAnchor),

            commandOutputLabel.leadingAnchor.constraint(equalTo: commandOutputHitArea.leadingAnchor, constant: 12),
            commandOutputLabel.trailingAnchor.constraint(equalTo: commandOutputHitArea.trailingAnchor, constant: -12),
            commandOutputLabel.heightAnchor.constraint(equalToConstant: 15),
            commandOutputLabel.centerYAnchor.constraint(equalTo: commandOutputHitArea.centerYAnchor),

            commandInputBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            commandInputBackground.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            commandInputBackground.heightAnchor.constraint(equalToConstant: 30),
            commandInputBackground.bottomAnchor.constraint(equalTo: statusSeparator.topAnchor, constant: -5),

            promptLabel.leadingAnchor.constraint(equalTo: commandInputBackground.leadingAnchor, constant: 9),
            promptLabel.widthAnchor.constraint(equalToConstant: 10),
            promptLabel.centerYAnchor.constraint(equalTo: commandInputBackground.centerYAnchor),

            commandField.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 4),
            commandField.trailingAnchor.constraint(equalTo: commandInputBackground.trailingAnchor, constant: -9),
            commandField.heightAnchor.constraint(equalToConstant: 22),
            commandField.centerYAnchor.constraint(equalTo: commandInputBackground.centerYAnchor),

            commandPlaceholderLabel.leadingAnchor.constraint(equalTo: commandField.leadingAnchor),
            commandPlaceholderLabel.trailingAnchor.constraint(equalTo: commandField.trailingAnchor),
            commandPlaceholderLabel.centerYAnchor.constraint(equalTo: commandInputBackground.centerYAnchor),

            statusSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusSeparator.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 14)
        ])

        return container
    }

    private func configureTable() {
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Name"
        name.width = 400
        name.minWidth = 180
        name.resizingMask = .autoresizingMask

        let kind = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kind.title = "Kind"
        kind.width = 120
        kind.minWidth = 80

        let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        size.title = "Size"
        size.width = 90
        size.minWidth = 70

        let modified = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))
        modified.title = "Modified"
        modified.width = 170
        modified.minWidth = 130

        [name, kind, size, modified].forEach(tableView.addTableColumn)
        tableView.rowHeight = 27
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)

        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Open", action: #selector(openContextItem), keyEquivalent: "")
        menu.addItem(withTitle: "Use as Workspace", action: #selector(useContextItemAsWorkspace), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealContextItem), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Path", action: #selector(copyContextPath), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        tableView.menu = menu
    }

    private func symbolButton(_ symbol: String, action: Selector) -> NSButton {
        let button = NSButton()
        configureSymbolButton(button, symbol: symbol, action: action)
        return button
    }

    private func configureSymbolButton(_ button: NSButton, symbol: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.target = self
        button.action = action
        button.bezelStyle = .inline
        button.isBordered = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    func setWorkspace(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard let info = try? fileSystem.info(for: standardized), info.isNavigableDirectory else {
            return
        }

        let root = FileNode(info: info, fileSystem: fileSystem)
        rootNode = root
        workspaceLabel.stringValue = info.name.uppercased()
        workspaceLabel.toolTip = standardized.path
        UserDefaults.standard.set(standardized.path, forKey: "lastWorkspacePath")

        history.removeAll(keepingCapacity: true)
        historyIndex = -1
        outlineView.reloadData()
        navigate(to: standardized, recordHistory: true, revealInSidebar: false)
        updateWorkspaceButtons()
    }

    private func navigate(to url: URL, recordHistory: Bool, revealInSidebar: Bool = true) {
        let standardized = url.standardizedFileURL
        guard let rootNode, fileSystem.isDescendant(standardized, of: rootNode.info.url) else { return }

        do {
            tableItems = try fileSystem.children(of: standardized)
            currentDirectory = standardized
            watchCurrentDirectory(standardized)
            pathControl.url = standardized
            tableView.reloadData()
            tableView.deselectAll(nil)
            updateStatus()

            if recordHistory {
                if historyIndex + 1 < history.count {
                    history.removeSubrange((historyIndex + 1)..<history.count)
                }
                if history.last?.standardizedFileURL != standardized {
                    history.append(standardized)
                }
                historyIndex = max(0, history.count - 1)
            }

            updateNavigationButtons()
            updateWorkspaceButtons()
            if revealInSidebar {
                selectDirectoryInSidebar(standardized)
            }
        } catch {
            tableItems = []
            tableView.reloadData()
            statusLabel.stringValue = "Unable to read \(standardized.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func selectDirectoryInSidebar(_ url: URL) {
        guard let rootNode else { return }
        let rootURL = rootNode.info.url.standardizedFileURL
        let targetURL = url.standardizedFileURL
        guard fileSystem.isDescendant(targetURL, of: rootURL) else { return }

        suppressOutlineSelection = true
        defer { suppressOutlineSelection = false }

        if targetURL == rootURL {
            outlineView.deselectAll(nil)
            return
        }

        let relativePath = String(targetURL.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relativePath.split(separator: "/").map(String.init)
        var node = rootNode

        for component in components {
            guard let child = node.child(named: component) else { return }
            if node !== rootNode {
                outlineView.expandItem(node)
            }
            node = child
        }

        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex >= 0 && historyIndex < history.count - 1
    }

    private func updateWorkspaceButtons() {
        guard let root = rootNode?.info.url.standardizedFileURL else {
            workspaceParentButton.isEnabled = false
            workspaceCurrentButton.isEnabled = false
            return
        }

        let parent = root.deletingLastPathComponent().standardizedFileURL
        workspaceParentButton.isEnabled = parent.path != root.path
        workspaceCurrentButton.isEnabled = currentDirectory.map { $0.standardizedFileURL != root } ?? false
    }

    private func updateStatus() {
        let selected = tableView.selectedRowIndexes.compactMap { index in
            tableItems.indices.contains(index) ? tableItems[index] : nil
        }
        if selected.isEmpty {
            statusLabel.stringValue = "\(tableItems.count) item\(tableItems.count == 1 ? "" : "s")"
            return
        }

        let fileBytes = selected.compactMap { $0.isDirectory ? nil : $0.size }.reduce(0, +)
        let sizeText = fileBytes > 0 ? " · \(ByteCountFormatter.string(fromByteCount: fileBytes, countStyle: .file))" : ""
        statusLabel.stringValue = "\(selected.count) selected\(sizeText)"
    }

    private func itemForContextMenu() -> FileInfo? {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard tableItems.indices.contains(row) else { return nil }
        return tableItems[row]
    }

    private func icon(for info: FileInfo) -> NSImage {
        let key: NSString = info.isNavigableDirectory
            ? "__folder__"
            : "ext:\(info.fileExtension.isEmpty ? "__file__" : info.fileExtension)" as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: info.url.path)
        image.size = NSSize(width: 16, height: 16)
        iconCache.setObject(image, forKey: key)
        return image
    }

    private func kindText(for info: FileInfo) -> String {
        if info.isNavigableDirectory { return "Folder" }
        if info.isPackage { return "Package" }
        if !info.fileExtension.isEmpty { return info.fileExtension.uppercased() }
        return "File"
    }

    private func sizeText(for info: FileInfo) -> String {
        guard !info.isDirectory, let size = info.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    @objc private func runCommandField() {
        let line = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        switch NavigatorCommandLine.tokenize(line) {
        case .success(let arguments):
            let result = executeCommand(arguments: arguments)
            if result.success {
                commandField.stringValue = ""
            }
        case .failure(let error):
            showCommandResult(.failure(error.localizedDescription))
        }
    }

    private func hideCommandPlaceholder() {
        commandPlaceholderLabel.isHidden = true
    }

    private func restoreCommandPlaceholder() {
        commandPlaceholderLabel.isHidden = !commandField.stringValue.isEmpty
    }

    func executeCommand(arguments: [String]) -> NavigatorCommandResult {
        let baseDirectory = currentDirectory ?? rootNode?.info.url ?? FileManager.default.homeDirectoryForCurrentUser
        let result = commandEngine.execute(
            arguments: arguments,
            baseDirectory: baseDirectory,
            workspaceRoot: rootNode?.info.url
        )
        guard result.success else {
            showCommandResult(result)
            return result
        }

        let applied = applyCommandEffect(result)
        showCommandResult(applied)
        return applied
    }

    private func applyCommandEffect(_ result: NavigatorCommandResult) -> NavigatorCommandResult {
        switch result.effect {
        case .none:
            return result
        case .refresh:
            refresh()
        case .refreshAndSelect(let path):
            refresh()
            selectPath(URL(fileURLWithPath: path))
        case .navigate(let path):
            navigate(to: URL(fileURLWithPath: path), recordHistory: true)
        case .workspace(let path):
            setWorkspace(URL(fileURLWithPath: path, isDirectory: true))
        case .select(let path):
            selectPath(URL(fileURLWithPath: path))
        case .open(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .reveal(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .back:
            goBack()
        case .forward:
            goForward()
        case .uiFocusCommand:
            hideCommandPlaceholder()
            window?.makeFirstResponder(commandField)
        case .uiShow:
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .uiState:
            let workspace = rootNode?.info.url.path ?? ""
            let directory = currentDirectory?.path ?? ""
            let selected = tableView.selectedRowIndexes.compactMap { index -> String? in
                guard tableItems.indices.contains(index) else { return nil }
                return tableItems[index].url.path
            }
            let output = [
                "workspace=\(workspace)",
                "cwd=\(directory)",
                "items=\(tableItems.count)",
                "selection=\(selected.joined(separator: ","))",
                "window_width=\(Int(window?.frame.width ?? 0))",
                "sidebar_width=\(Int(outlineView.enclosingScrollView?.frame.width ?? 0))",
                "browser_width=\(Int(tableView.enclosingScrollView?.frame.width ?? 0))",
                "command_focused=\(commandField.currentEditor() != nil)",
                "command_placeholder_visible=\(!commandPlaceholderLabel.isHidden)"
            ].joined(separator: "\n")
            return .ok(output)
        }
        return result
    }

    private func showCommandResult(_ result: NavigatorCommandResult) {
        let raw = result.output.isEmpty ? (result.success ? "ok" : "error") : result.output
        lastCommandOutput = raw
        if let popover = commandOutputPopover, popover.isShown {
            popover.performClose(nil)
            commandOutputPopover = nil
        }
        let summary = raw.replacingOccurrences(of: "\n", with: "  ·  ")
        commandOutputLabel.stringValue = (result.success ? "Result · " : "Error · ") + summary
        commandOutputLabel.toolTip = "Click to view full command output"
        commandOutputLabel.textColor = result.success ? .labelColor : .systemRed
    }

    @objc private func showFullCommandOutput() {
        guard !lastCommandOutput.isEmpty else { return }

        if let popover = commandOutputPopover, popover.isShown {
            popover.performClose(nil)
            commandOutputPopover = nil
            return
        }

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.string = lastCommandOutput

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 300))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let controller = NSViewController()
        controller.view = scrollView
        controller.preferredContentSize = NSSize(width: 620, height: 300)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 620, height: 300)
        popover.contentViewController = controller
        popover.show(relativeTo: commandOutputLabel.bounds, of: commandOutputLabel, preferredEdge: .maxY)
        commandOutputPopover = popover
    }

    private func selectPath(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard let root = rootNode?.info.url,
              fileSystem.isDescendant(standardized, of: root) else { return }

        if standardized == root.standardizedFileURL {
            navigate(to: root, recordHistory: true)
            return
        }

        let parent = standardized.deletingLastPathComponent()
        navigate(to: parent, recordHistory: true)
        if let index = tableItems.firstIndex(where: { $0.url.standardizedFileURL == standardized }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
            updateStatus()
        }
    }

    private func watchCurrentDirectory(_ url: URL) {
        directoryWatcher.watch(url) { [weak self] in
            self?.refresh()
        }
    }

    @objc func useParentAsWorkspace() {
        guard let root = rootNode?.info.url.standardizedFileURL else { return }
        let parent = root.deletingLastPathComponent().standardizedFileURL
        guard parent.path != root.path else { return }
        setWorkspace(parent)
    }

    @objc func useCurrentDirectoryAsWorkspace() {
        guard let currentDirectory else { return }
        setWorkspace(currentDirectory)
    }

    @objc func chooseWorkspace() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Folder as Workspace"
        panel.prompt = "Use as Workspace"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setWorkspace(url)
        }
    }

    @objc func refresh() {
        rootNode?.invalidateChildren(recursively: true)
        outlineView.reloadData()
        if let currentDirectory, FileManager.default.fileExists(atPath: currentDirectory.path) {
            navigate(to: currentDirectory, recordHistory: false)
        } else if let root = rootNode?.info.url {
            navigate(to: root, recordHistory: false)
        }
    }

    @objc func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        navigate(to: history[historyIndex], recordHistory: false)
    }

    @objc func goForward() {
        guard historyIndex >= 0, historyIndex < history.count - 1 else { return }
        historyIndex += 1
        navigate(to: history[historyIndex], recordHistory: false)
    }

    @objc func revealSelectedInFinder() {
        if tableView.selectedRow >= 0, tableItems.indices.contains(tableView.selectedRow) {
            NSWorkspace.shared.activateFileViewerSelecting([tableItems[tableView.selectedRow].url])
        } else if let currentDirectory {
            NSWorkspace.shared.activateFileViewerSelecting([currentDirectory])
        }
    }

    @objc private func outlineDoubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if !node.info.isNavigableDirectory {
            NSWorkspace.shared.open(node.info.url)
        }
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard tableItems.indices.contains(row) else { return }
        let item = tableItems[row]
        if item.isNavigableDirectory {
            navigate(to: item.url, recordHistory: true)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func openContextItem() {
        guard let item = itemForContextMenu() else { return }
        if item.isNavigableDirectory {
            navigate(to: item.url, recordHistory: true)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func useContextItemAsWorkspace() {
        guard let item = itemForContextMenu(), item.isNavigableDirectory else { return }
        setWorkspace(item.url)
    }

    @objc private func revealContextItem() {
        guard let item = itemForContextMenu() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func copyContextPath() {
        guard let item = itemForContextMenu() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
    }
}

extension MainWindowController: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === commandField else { return }
        hideCommandPlaceholder()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === commandField else { return }
        restoreCommandPlaceholder()
    }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(useContextItemAsWorkspace) {
            return itemForContextMenu()?.isNavigableDirectory == true
        }
        return true
    }
}

extension MainWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode {
            return node.children().count
        }
        return rootNode?.children().count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode {
            return node.children()[index]
        }
        return rootNode!.children()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ExplorerCell")
        let cell: NSTableCellView

        if let reusable = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reusable
        } else {
            cell = makeIconTextCell(identifier: identifier)
        }

        cell.textField?.stringValue = node.info.name
        cell.textField?.toolTip = node.info.url.path
        cell.imageView?.image = icon(for: node.info)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressOutlineSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }

        if node.info.isNavigableDirectory {
            navigate(to: node.info.url, recordHistory: true, revealInSidebar: false)
        } else if let parent = node.parent {
            navigate(to: parent.info.url, recordHistory: true, revealInSidebar: false)
            if let index = tableItems.firstIndex(where: { $0.url.standardizedFileURL == node.info.url.standardizedFileURL }) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                tableView.scrollRowToVisible(index)
            }
        }
    }
}

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableItems.indices.contains(row), let tableColumn else { return nil }
        let item = tableItems[row]
        let identifier = tableColumn.identifier

        if identifier.rawValue == "name" {
            let cell: NSTableCellView
            if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
                cell = reusable
            } else {
                cell = makeIconTextCell(identifier: identifier)
            }
            cell.textField?.stringValue = item.name
            cell.textField?.toolTip = item.url.path
            cell.imageView?.image = icon(for: item)
            return cell
        }

        let cell: NSTableCellView
        if let reusable = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reusable
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        switch identifier.rawValue {
        case "kind": cell.textField?.stringValue = kindText(for: item)
        case "size": cell.textField?.stringValue = sizeText(for: item)
        case "modified": cell.textField?.stringValue = item.modifiedAt.map(dateFormatter.string(from:)) ?? "—"
        default: cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
    }

    private func makeIconTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1

        cell.addSubview(imageView)
        cell.addSubview(label)
        cell.imageView = imageView
        cell.textField = label

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

private final class SidebarBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
