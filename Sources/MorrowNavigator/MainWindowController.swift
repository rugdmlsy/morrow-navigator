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

        if clickedRow >= 0 {
            let clickedItem = item(atRow: clickedRow)
            let isDirectory = (clickedItem as? FileNode)?.info.isNavigableDirectory
                ?? (clickedItem as? RemoteFileNode)?.info.isNavigableDirectory
                ?? false
            if isDirectory {
                // The whole row is the interaction target. The disclosure triangle is
                // presentation only and never receives separate click behavior.
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
                if isItemExpanded(clickedItem) {
                    collapseItem(clickedItem)
                } else {
                    expandItem(clickedItem)
                }
                return
            }
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
    private let remoteFileSystem = RemoteFileSystemService()
    private let remoteDirectoryCache = RemoteDirectoryCache()
    private let sshConfigDiscovery = SSHConfigDiscovery()
    private let commandEngine = NavigatorCommandEngine()
    private let directoryWatcher = DirectoryWatcher()
    private let iconCache = NSCache<NSString, NSImage>()

    private var rootNode: FileNode?
    private var remoteRootNode: RemoteFileNode?
    private var currentDirectory: URL?
    private var tableItems: [FileInfo] = []
    private var history: [URL] = []
    private var historyIndex = -1
    private var remoteHosts: [RemoteHost] = []
    private var remoteNavigationRequestID: UUID?
    private var suppressOutlineSelection = false
    private var isRestoringSidebarWidth = false

    private let splitView = NSSplitView()
    private let outlineView = InstantOutlineView()
    private let tableView = NSTableView()
    private let workspaceLabel = NSTextField(labelWithString: "")
    private let pathControl = NSPathControl()
    private let statusLabel = NSTextField(labelWithString: "")
    private let commandOutputLabel = NSTextField(labelWithString: "")
    private let commandOutputHitArea = NSView()
    private let commandField = CommandTextField()
    private let commandPlaceholderLabel = NonInteractiveLabel(labelWithString: "Command · help for available commands")
    private let remoteHostsStack = NSStackView()
    private var lastCommandOutput = ""
    private var commandOutputPopover: NSPopover?
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let browserRevealButton = NSButton()
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

        remoteHosts = loadManagedRemoteHosts()
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

        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        let sidebar = makeSidebar()
        let browser = makeBrowser()

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(browser)
        contentView.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        isRestoringSidebarWidth = true
        contentView.layoutSubtreeIfNeeded()
        let savedWidth = UserDefaults.standard.object(forKey: "sidebarWidth") as? NSNumber
        setSidebarWidth(CGFloat(savedWidth?.doubleValue ?? 260), persist: false)
        isRestoringSidebarWidth = false
    }

    private func setSidebarWidth(_ requestedWidth: CGFloat, persist: Bool) {
        guard splitView.subviews.count >= 2 else { return }
        let minimumSidebarWidth: CGFloat = 190
        let minimumBrowserWidth: CGFloat = 360
        let maximumSidebarWidth = max(
            minimumSidebarWidth,
            splitView.bounds.width - splitView.dividerThickness - minimumBrowserWidth
        )
        let width = min(max(requestedWidth, minimumSidebarWidth), maximumSidebarWidth)
        splitView.setPosition(width, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        if persist {
            UserDefaults.standard.set(Double(width), forKey: "sidebarWidth")
        }
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

        let remoteLabel = NSTextField(labelWithString: "REMOTE")
        remoteLabel.translatesAutoresizingMaskIntoConstraints = false
        remoteLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        remoteLabel.textColor = .secondaryLabelColor

        let addRemoteButton = symbolButton("plus", action: #selector(addRemoteHost))
        addRemoteButton.toolTip = "Add Remote Connection…"
        let remoteButtonStack = NSStackView(views: [addRemoteButton])
        remoteButtonStack.translatesAutoresizingMaskIntoConstraints = false
        remoteButtonStack.orientation = .horizontal
        remoteButtonStack.spacing = 2

        remoteHostsStack.translatesAutoresizingMaskIntoConstraints = false
        remoteHostsStack.orientation = .vertical
        remoteHostsStack.alignment = .leading
        remoteHostsStack.spacing = 1
        rebuildRemoteHostButtons()

        container.addSubview(explorerLabel)
        container.addSubview(workspaceLabel)
        container.addSubview(buttonStack)
        container.addSubview(scrollView)
        container.addSubview(remoteLabel)
        container.addSubview(remoteButtonStack)
        container.addSubview(remoteHostsStack)

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
            scrollView.bottomAnchor.constraint(equalTo: remoteLabel.topAnchor, constant: -8),

            remoteLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            remoteLabel.bottomAnchor.constraint(equalTo: remoteHostsStack.topAnchor, constant: -5),

            remoteButtonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            remoteButtonStack.centerYAnchor.constraint(equalTo: remoteLabel.centerYAnchor),

            remoteHostsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            remoteHostsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            remoteHostsStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        return container
    }

    private func rebuildRemoteHostButtons() {
        for view in remoteHostsStack.arrangedSubviews {
            remoteHostsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !remoteHosts.isEmpty else {
            let label = NSTextField(labelWithString: "No remote connections")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            remoteHostsStack.addArrangedSubview(label)
            return
        }

        for host in remoteHosts {
            let button = NSButton(title: host.displayName ?? host.alias, target: self, action: #selector(openRemoteHost(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.identifier = NSUserInterfaceItemIdentifier(host.id)
            let symbol = host.kind == .github ? "chevron.left.forwardslash.chevron.right" : "server.rack"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: host.kind.displayName)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.bezelStyle = .inline
            button.isBordered = false
            button.toolTip = "\(host.kind.displayName) · \(host.endpointDescription)"

            let badge = host.kind == .github && host.rootPath != "/" ? "GH REPO" : (host.kind == .github ? "GITHUB" : "SSH")
            let kindBadge = NSTextField(labelWithString: badge)
            kindBadge.font = .systemFont(ofSize: 8.5, weight: .semibold)
            kindBadge.textColor = .tertiaryLabelColor
            kindBadge.alignment = .right
            kindBadge.setContentHuggingPriority(.required, for: .horizontal)

            let removeButton = NSButton()
            configureSymbolButton(removeButton, symbol: "minus.circle", action: #selector(removeRemoteHost(_:)))
            removeButton.identifier = NSUserInterfaceItemIdentifier(host.id)
            removeButton.toolTip = "Remove \(host.displayName ?? host.alias) from Navigator"
            let row = NSStackView(views: [button, kindBadge, removeButton])
            row.translatesAutoresizingMaskIntoConstraints = false
            row.orientation = .horizontal
            row.spacing = 2
            row.distribution = .fill
            remoteHostsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: remoteHostsStack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
    }

    private var remoteHostAliasesDefaultsKey: String { "remoteHostAliases.v1" }
    private var remoteHostsDefaultsKey: String { "remoteHosts.v2" }

    private func loadManagedRemoteHosts() -> [RemoteHost] {
        let defaults = UserDefaults.standard
        let discovered = sshConfigDiscovery.hosts()
        let discoveredByAlias = Dictionary(uniqueKeysWithValues: discovered.map { ($0.alias, $0) })
        if let data = defaults.data(forKey: remoteHostsDefaultsKey),
           let hosts = try? JSONDecoder().decode([RemoteHost].self, from: data) {
            return hosts.sorted {
                ($0.displayName ?? $0.alias).localizedStandardCompare($1.displayName ?? $1.alias) == .orderedAscending
            }
        }
        if let aliases = defaults.stringArray(forKey: remoteHostAliasesDefaultsKey) {
            let migrated = aliases.map { discoveredByAlias[$0] ?? RemoteHost(alias: $0) }.sorted {
                $0.alias.localizedStandardCompare($1.alias) == .orderedAscending
            }
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: remoteHostsDefaultsKey)
            }
            return migrated
        }
        if let data = try? JSONEncoder().encode(discovered) {
            defaults.set(data, forKey: remoteHostsDefaultsKey)
        }
        return discovered
    }

    private func persistRemoteHosts() {
        if let data = try? JSONEncoder().encode(remoteHosts) {
            UserDefaults.standard.set(data, forKey: remoteHostsDefaultsKey)
        }
    }

    private func addManagedRemoteHost(_ host: RemoteHost) {
        guard !remoteHosts.contains(where: { $0.id == host.id }) else { return }
        remoteHosts.append(host)
        remoteHosts.sort {
            ($0.displayName ?? $0.alias).localizedStandardCompare($1.displayName ?? $1.alias) == .orderedAscending
        }
        persistRemoteHosts()
        rebuildRemoteHostButtons()
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

        upButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Up One Level")
        upButton.target = self
        upButton.action = #selector(goUpOneLevel)
        upButton.bezelStyle = .inline
        upButton.isBordered = false
        upButton.toolTip = "Up One Level"

        let navigationStack = NSStackView(views: [backButton, forwardButton, upButton])
        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        navigationStack.orientation = .horizontal
        navigationStack.spacing = 7

        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.font = .systemFont(ofSize: 12)

        configureSymbolButton(browserRevealButton, symbol: "arrow.forward.square", action: #selector(revealSelectedInFinder))
        browserRevealButton.toolTip = "Reveal in Finder"
        let refreshButton = symbolButton("arrow.clockwise", action: #selector(refresh))
        refreshButton.toolTip = "Refresh"

        let actionStack = NSStackView(views: [browserRevealButton, refreshButton])
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
            commandOutputHitArea.heightAnchor.constraint(equalToConstant: 26),
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
        if let remote = RemoteLocation(url: url) {
            setRemoteWorkspace(remote)
            return
        }

        let standardized = url.standardizedFileURL
        guard let info = try? fileSystem.info(for: standardized), info.isNavigableDirectory else {
            return
        }

        remoteRootNode = nil
        let root = FileNode(info: info, fileSystem: fileSystem)
        rootNode = root
        workspaceLabel.stringValue = info.name.uppercased()
        workspaceLabel.toolTip = standardized.path
        UserDefaults.standard.set(standardized.path, forKey: "lastWorkspacePath")
        UserDefaults.standard.set(standardized.absoluteString, forKey: "lastWorkspaceURL")

        history.removeAll(keepingCapacity: true)
        historyIndex = -1
        outlineView.reloadData()
        navigate(to: standardized, recordHistory: true, revealInSidebar: false)
        updateWorkspaceButtons()
    }

    private func setRemoteWorkspace(_ location: RemoteLocation) {
        rootNode = nil
        let name = location.path == "/"
            ? location.host
            : (location.path as NSString).lastPathComponent
        let info = FileInfo(
            url: location.url,
            name: name,
            isDirectory: true,
            isPackage: false,
            size: nil,
            modifiedAt: nil,
            isHidden: false
        )
        remoteRootNode = RemoteFileNode(info: info, cache: remoteDirectoryCache)
        workspaceLabel.stringValue = name.uppercased()
        workspaceLabel.toolTip = location.displayPath
        UserDefaults.standard.set(location.url.absoluteString, forKey: "lastWorkspaceURL")

        history.removeAll(keepingCapacity: true)
        historyIndex = -1
        outlineView.reloadData()
        navigate(to: location.url, recordHistory: true, revealInSidebar: false)
        updateWorkspaceButtons()
    }

    private func navigate(to url: URL, recordHistory: Bool, revealInSidebar: Bool = true) {
        if let remoteLocation = RemoteLocation(url: url) {
            navigateRemote(to: remoteLocation, recordHistory: recordHistory, revealInSidebar: revealInSidebar)
            return
        }

        remoteNavigationRequestID = nil
        browserRevealButton.isEnabled = true
        let standardized = url.standardizedFileURL
        guard let rootNode, fileSystem.isDescendant(standardized, of: rootNode.info.url) else { return }

        do {
            tableItems = try fileSystem.children(of: standardized)
            currentDirectory = standardized
            watchCurrentDirectory(standardized)
            pathControl.url = standardized
            pathControl.toolTip = standardized.path
            tableView.reloadData()
            tableView.deselectAll(nil)
            updateStatus()

            if recordHistory {
                recordNavigationHistory(standardized)
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

    private func navigateRemote(to location: RemoteLocation, recordHistory: Bool, revealInSidebar: Bool) {
        let requestID = UUID()
        remoteNavigationRequestID = requestID
        let isGitHub = remoteFileSystem.isGitHubHost(location.host)
        directoryWatcher.stop()
        browserRevealButton.isEnabled = false
        currentDirectory = location.url
        pathControl.url = location.url
        pathControl.toolTip = location.displayPath

        let cached = remoteDirectoryCache.cachedDirectory(location)
        tableItems = cached?.items ?? []
        tableView.reloadData()
        tableView.deselectAll(nil)
        if let cached {
            let source = isGitHub ? "GitHub" : location.host
            statusLabel.stringValue = "Cached · \(cached.items.count) item\(cached.items.count == 1 ? "" : "s") · refreshing \(source)…"
        } else {
            statusLabel.stringValue = isGitHub ? "Loading GitHub repositories…" : "Connecting to \(location.host)…"
        }
        if recordHistory {
            recordNavigationHistory(location.url)
        }
        updateNavigationButtons()
        updateWorkspaceButtons()
        if revealInSidebar {
            selectRemoteDirectoryInSidebar(location)
        }

        let service = remoteFileSystem
        let cache = remoteDirectoryCache
        let cachedItems = cached?.items
        Task { [weak self] in
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try service.children(of: location)
                }.value
                try? cache.store(items, for: location)
                guard let self, self.remoteNavigationRequestID == requestID else { return }
                if cachedItems != items {
                    self.tableItems = items
                    self.tableView.reloadData()
                    self.tableView.deselectAll(nil)
                }
                let source = isGitHub ? "\(location.host) · GitHub" : location.host
                self.statusLabel.stringValue = "\(source) · \(items.count) item\(items.count == 1 ? "" : "s")"
                self.updateRemoteWorkspaceNode(location: location, items: items)
                if revealInSidebar {
                    self.selectRemoteDirectoryInSidebar(location)
                }
                self.updateNavigationButtons()
            } catch {
                guard let self, self.remoteNavigationRequestID == requestID else { return }
                if let cachedItems {
                    self.tableItems = cachedItems
                    self.tableView.reloadData()
                    self.statusLabel.stringValue = "Offline · showing cached \(cachedItems.count) item\(cachedItems.count == 1 ? "" : "s") · \(error.localizedDescription)"
                } else {
                    self.tableItems = []
                    self.tableView.reloadData()
                    self.statusLabel.stringValue = "Unable to read \(location.displayPath): \(error.localizedDescription)"
                }
                self.updateNavigationButtons()
            }
        }
    }

    private func recordNavigationHistory(_ url: URL) {
        if historyIndex + 1 < history.count {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        if history.last != url {
            history.append(url)
        }
        historyIndex = max(0, history.count - 1)
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

    private func isRemoteDescendant(_ candidate: RemoteLocation, of root: RemoteLocation) -> Bool {
        guard candidate.host == root.host else { return false }
        if candidate.path == root.path { return true }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        return candidate.path.hasPrefix(prefix)
    }

    private func remoteNode(for location: RemoteLocation) -> RemoteFileNode? {
        guard let root = remoteRootNode,
              let rootLocation = root.location,
              isRemoteDescendant(location, of: rootLocation) else { return nil }
        if location == rootLocation { return root }

        let relative = String(location.path.dropFirst(rootLocation.path == "/" ? 1 : rootLocation.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = relative.split(separator: "/").map(String.init)
        var node = root
        for component in components {
            guard let child = node.child(named: component) else { return nil }
            node = child
        }
        return node
    }

    private func updateRemoteWorkspaceNode(location: RemoteLocation, items: [FileInfo]) {
        guard let node = remoteNode(for: location) else { return }
        node.replaceChildren(with: items)
        if node === remoteRootNode {
            outlineView.reloadData()
        } else {
            outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    private func selectRemoteDirectoryInSidebar(_ location: RemoteLocation) {
        guard let root = remoteRootNode,
              let rootLocation = root.location,
              isRemoteDescendant(location, of: rootLocation) else { return }

        suppressOutlineSelection = true
        defer { suppressOutlineSelection = false }

        if location == rootLocation {
            outlineView.deselectAll(nil)
            return
        }
        guard let node = remoteNode(for: location) else { return }
        var ancestors: [RemoteFileNode] = []
        var parent = node.parent
        while let current = parent, current !== root {
            ancestors.append(current)
            parent = current.parent
        }
        for ancestor in ancestors.reversed() {
            outlineView.expandItem(ancestor)
        }
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    private func refreshRemoteNode(_ node: RemoteFileNode) {
        guard let location = node.location else { return }
        let service = remoteFileSystem
        let cache = remoteDirectoryCache
        Task { [weak self, weak node] in
            do {
                let items = try await Task.detached(priority: .utility) {
                    try service.children(of: location)
                }.value
                try? cache.store(items, for: location)
                guard let self, let node else { return }
                node.replaceChildren(with: items)
                if node === self.remoteRootNode {
                    self.outlineView.reloadData()
                } else {
                    self.outlineView.reloadItem(node, reloadChildren: true)
                }
            } catch {
                // Cached children remain visible when the remote host is unavailable.
            }
        }
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex >= 0 && historyIndex < history.count - 1
        upButton.isEnabled = browserParentDestination() != nil
    }

    private func browserParentDestination() -> URL? {
        guard let currentDirectory else { return nil }

        if let currentRemote = RemoteLocation(url: currentDirectory) {
            if let remoteRoot = remoteRootNode?.location,
               remoteRoot.host == currentRemote.host,
               isRemoteDescendant(currentRemote, of: remoteRoot) {
                guard currentRemote != remoteRoot else { return nil }
                return currentRemote.parent.url
            }
            guard currentRemote.path != "/" else { return nil }
            return currentRemote.parent.url
        }

        guard let localRoot = rootNode?.info.url.standardizedFileURL else { return nil }
        let current = currentDirectory.standardizedFileURL
        guard current != localRoot, fileSystem.isDescendant(current, of: localRoot) else { return nil }
        return current.deletingLastPathComponent().standardizedFileURL
    }

    private func updateWorkspaceButtons() {
        if let remoteRoot = remoteRootNode?.location {
            workspaceParentButton.isEnabled = remoteRoot.path != "/"
            workspaceCurrentButton.isEnabled = currentDirectory.flatMap(RemoteLocation.init(url:)).map {
                $0.host == remoteRoot.host && $0 != remoteRoot
            } ?? false
            return
        }

        guard let root = rootNode?.info.url.standardizedFileURL else {
            workspaceParentButton.isEnabled = false
            workspaceCurrentButton.isEnabled = false
            return
        }

        let parent = root.deletingLastPathComponent().standardizedFileURL
        workspaceParentButton.isEnabled = parent.path != root.path
        if currentDirectory.flatMap(RemoteLocation.init(url:)) != nil {
            workspaceCurrentButton.isEnabled = true
        } else {
            workspaceCurrentButton.isEnabled = currentDirectory.map {
                $0.standardizedFileURL != root
            } ?? false
        }
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
        if RemoteLocation(url: info.url) != nil {
            let symbol = info.isNavigableDirectory ? "folder" : "doc"
            let key = "__remote_\(symbol)__" as NSString
            if let cached = iconCache.object(forKey: key) {
                return cached
            }
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
            image.size = NSSize(width: 16, height: 16)
            iconCache.setObject(image, forKey: key)
            return image
        }

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
        if let currentDirectory,
           let remote = RemoteLocation(url: currentDirectory),
           let command = arguments.first?.lowercased(),
           !["help", "back", "forward", "ui"].contains(command) {
            let result = NavigatorCommandResult.failure(
                "Remote command execution is not available yet for \(remote.host). Directory browsing is read-only."
            )
            showCommandResult(result)
            return result
        }

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
        case .uiSidebarWidth(let width):
            setSidebarWidth(CGFloat(width), persist: true)
            return .ok("sidebar_width=\(Int(splitView.subviews.first?.frame.width ?? 0))")
        case .uiState:
            let workspace = remoteRootNode?.location?.displayPath ?? rootNode?.info.url.path ?? ""
            let directory = currentDirectory.map {
                RemoteLocation(url: $0)?.displayPath ?? $0.path
            } ?? ""
            let selected = tableView.selectedRowIndexes.compactMap { index -> String? in
                guard tableItems.indices.contains(index) else { return nil }
                return RemoteLocation(url: tableItems[index].url)?.displayPath ?? tableItems[index].url.path
            }
            let output = [
                "workspace=\(workspace)",
                "cwd=\(directory)",
                "items=\(tableItems.count)",
                "outline_rows=\(outlineView.numberOfRows)",
                "up_enabled=\(upButton.isEnabled)",
                "selection=\(selected.joined(separator: ","))",
                "window_width=\(Int(window?.frame.width ?? 0))",
                "sidebar_width=\(Int(splitView.subviews.first?.frame.width ?? 0))",
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
        if let remoteRoot = remoteRootNode?.location {
            guard remoteRoot.path != "/" else { return }
            setWorkspace(remoteRoot.parent.url)
            return
        }
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
        panel.directoryURL = currentDirectory.flatMap {
            RemoteLocation(url: $0) == nil ? $0 : nil
        } ?? rootNode?.info.url ?? FileManager.default.homeDirectoryForCurrentUser
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setWorkspace(url)
        }
    }

    @objc func refresh() {
        if let currentDirectory, RemoteLocation(url: currentDirectory) != nil {
            navigate(to: currentDirectory, recordHistory: false, revealInSidebar: false)
            return
        }

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

    @objc private func goUpOneLevel() {
        guard let parent = browserParentDestination() else { return }
        navigate(to: parent, recordHistory: true)
    }

    @objc func revealSelectedInFinder() {
        guard currentDirectory.flatMap(RemoteLocation.init(url:)) == nil else { return }
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
        } else if let remote = RemoteLocation(url: item.url) {
            statusLabel.stringValue = "\(remote.displayPath) · remote file opening is not available yet"
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func openContextItem() {
        guard let item = itemForContextMenu() else { return }
        if item.isNavigableDirectory {
            navigate(to: item.url, recordHistory: true)
        } else if let remote = RemoteLocation(url: item.url) {
            statusLabel.stringValue = "\(remote.displayPath) · remote file opening is not available yet"
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func useContextItemAsWorkspace() {
        guard let item = itemForContextMenu(), item.isNavigableDirectory else { return }
        setWorkspace(item.url)
    }

    @objc private func revealContextItem() {
        guard let item = itemForContextMenu(), RemoteLocation(url: item.url) == nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func copyContextPath() {
        guard let item = itemForContextMenu() else { return }
        NSPasteboard.general.clearContents()
        let path = RemoteLocation(url: item.url)?.displayPath ?? item.url.path
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func openRemoteHost(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let host = remoteHosts.first(where: { $0.id == id }) else { return }
        navigate(to: host.navigationLocation.url, recordHistory: true, revealInSidebar: false)
    }

    @objc private func addRemoteHost() {
        guard let window else { return }
        let existingAliases = Set(remoteHosts.filter { $0.rootPath == "/" }.map(\.alias))
        let availableHosts = sshConfigDiscovery.hosts().filter { !existingAliases.contains($0.alias) }
        let picker = RemoteConnectionPickerView(hosts: availableHosts)

        let alert = NSAlert()
        alert.messageText = "Add Remote Connection"
        alert.informativeText = "Choose a configured connection, add a GitHub repository directly, or create a new SSH entry."
        let addButton = alert.addButton(withTitle: "Add Selected")
        addButton.isEnabled = !availableHosts.isEmpty
        alert.addButton(withTitle: "GitHub Repository…")
        alert.addButton(withTitle: "New SSH…")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = picker
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                if let host = picker.selectedHost {
                    self.addManagedRemoteHost(host)
                }
            } else if response == .alertSecondButtonReturn {
                self.loadGitHubRepositoriesAndPresentPicker()
            } else if response == .alertThirdButtonReturn {
                DispatchQueue.main.async { [weak self] in
                    self?.presentNewSSHConnectionSheet()
                }
            }
        }
    }

    private func loadGitHubRepositoriesAndPresentPicker() {
        let service = remoteFileSystem
        Task { [weak self] in
            do {
                let repositories = try await Task.detached(priority: .userInitiated) {
                    try service.githubRepositories()
                }.value
                self?.presentGitHubRepositorySheet(repositories)
            } catch {
                self?.presentRemoteConnectionError(error.localizedDescription)
            }
        }
    }

    private func presentGitHubRepositorySheet(_ repositories: [GitHubRepository]) {
        guard let window else { return }
        let existing = Set(remoteHosts.filter { $0.kind == .github && $0.rootPath != "/" }.map(\.rootPath))
        let available = repositories.filter { !existing.contains("/" + $0.fullName) }
        let picker = GitHubRepositoryPickerView(repositories: available)
        let alert = NSAlert()
        alert.messageText = "Add GitHub Repository"
        alert.informativeText = available.isEmpty
            ? "All accessible GitHub repositories are already added."
            : "Choose a repository from the account authenticated by gh."
        let addButton = alert.addButton(withTitle: "Add Repository")
        addButton.isEnabled = !available.isEmpty
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = picker
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  let repository = picker.selectedRepository else { return }
            let host = RemoteHost(
                alias: "github.com",
                hostname: "github.com",
                user: "git",
                kind: .github,
                displayName: repository.fullName,
                rootPath: "/" + repository.fullName
            )
            self.addManagedRemoteHost(host)
        }
    }

    private func presentNewSSHConnectionSheet() {
        guard let window else { return }
        let form = NewSSHConnectionView()
        let alert = NSAlert()
        alert.messageText = "New SSH Connection"
        alert.informativeText = "Navigator will add this connection to ~/.ssh/config and reuse OpenSSH for authentication."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = form
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let definition = form.definition else {
                self.presentRemoteConnectionError("Alias and host are required, and Port must be a valid number.")
                return
            }
            do {
                _ = try self.sshConfigDiscovery.appendHost(definition)
                let configured = self.sshConfigDiscovery.hosts()
                guard let host = configured.first(where: { $0.alias == definition.alias }) else {
                    self.presentRemoteConnectionError("The SSH entry was written, but Navigator could not reload it.")
                    return
                }
                self.addManagedRemoteHost(host)
            } catch {
                self.presentRemoteConnectionError(error.localizedDescription)
            }
        }
    }

    private func presentRemoteConnectionError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Add Remote"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    @objc private func removeRemoteHost(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        remoteHosts.removeAll { $0.id == id }
        persistRemoteHosts()
        rebuildRemoteHostButtons()
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

extension MainWindowController: NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMinimumPosition }
        return max(proposedMinimumPosition, 190)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMaximumPosition }
        let maximumSidebarWidth = max(190, splitView.bounds.width - splitView.dividerThickness - 360)
        return min(proposedMaximumPosition, maximumSidebarWidth)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isRestoringSidebarWidth,
              let splitView = notification.object as? NSSplitView,
              splitView === self.splitView,
              let sidebar = splitView.subviews.first,
              sidebar.frame.width > 0 else { return }
        UserDefaults.standard.set(Double(sidebar.frame.width), forKey: "sidebarWidth")
    }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(useContextItemAsWorkspace) {
            guard let item = itemForContextMenu() else { return false }
            return item.isNavigableDirectory
        }
        if menuItem.action == #selector(revealContextItem) {
            guard let item = itemForContextMenu() else { return false }
            return RemoteLocation(url: item.url) == nil
        }
        if menuItem.action == #selector(openContextItem),
           let item = itemForContextMenu(),
           RemoteLocation(url: item.url) != nil {
            return item.isNavigableDirectory
        }
        return true
    }
}

extension MainWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode {
            return node.children().count
        }
        if let node = item as? RemoteFileNode {
            return node.children().count
        }
        return rootNode?.children().count ?? remoteRootNode?.children().count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode {
            return node.children()[index]
        }
        if let node = item as? RemoteFileNode {
            return node.children()[index]
        }
        if let rootNode {
            return rootNode.children()[index]
        }
        return remoteRootNode!.children()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isExpandable
            ?? (item as? RemoteFileNode)?.isExpandable
            ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let info = (item as? FileNode)?.info ?? (item as? RemoteFileNode)?.info
        guard let info else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ExplorerCell")
        let cell: NSTableCellView

        if let reusable = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reusable
        } else {
            cell = makeIconTextCell(identifier: identifier)
        }

        cell.textField?.stringValue = info.name
        cell.textField?.toolTip = RemoteLocation(url: info.url)?.displayPath ?? info.url.path
        cell.imageView?.image = icon(for: info)
        return cell
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?.values.compactMap({ $0 as? RemoteFileNode }).first else { return }
        _ = node.children()
        refreshRemoteNode(node)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressOutlineSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0 else { return }

        if let node = outlineView.item(atRow: row) as? RemoteFileNode {
            if node.info.isNavigableDirectory {
                navigate(to: node.info.url, recordHistory: true, revealInSidebar: false)
            } else if let parent = node.parent {
                navigate(to: parent.info.url, recordHistory: true, revealInSidebar: false)
                if let index = tableItems.firstIndex(where: { $0.url == node.info.url }) {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    tableView.scrollRowToVisible(index)
                }
            }
            return
        }

        guard let node = outlineView.item(atRow: row) as? FileNode else { return }

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
