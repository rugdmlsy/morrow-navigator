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
            let isDirectory = (clickedItem as? FileNode)?.info.isNavigableDirectory ?? false
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
    private let fileSystem = UnifiedFileSystemService()
    private let directoryCache = FileSystemDirectoryCache()
    private let sshConfigDiscovery = SSHConfigDiscovery()
    private let commandEngine = NavigatorCommandEngine()
    private let directoryWatcher = DirectoryWatcher()
    private let iconCache = NSCache<NSString, NSImage>()

    private var rootNode: FileNode?
    private var currentDirectory: URL?
    private var tableItems: [FileInfo] = []
    private var history: [URL] = []
    private var historyIndex = -1
    private var remoteHosts: [RemoteHost] = []
    private var pinnedWorkspaceURLs: [URL] = []
    private var remoteNavigationRequestID: UUID?
    private var remoteNavigationRequestLocation: FileSystemLocation?
    private var remoteRefreshTimes: [FileSystemLocation: Date] = [:]
    private var suppressOutlineSelection = false
    private var isRestoringSidebarWidth = false
    private let remoteAutoRefreshInterval: TimeInterval = 60 * 60

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
    private let pinnedWorkspacesStack = NSStackView()
    private let remoteHostsStack = NSStackView()
    private var lastCommandOutput = ""
    private var commandOutputPopover: NSPopover?
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let browserRevealButton = NSButton()
    private let workspaceParentButton = NSButton()
    private let workspaceCurrentButton = NSButton()
    private let workspacePinButton = NSButton()
    private let previewPane = FilePreviewPane()
    private var previewRequestID: UUID?
    private var previewTemporaryDirectory: URL?
    private let remotePreviewByteLimit = 8 * 1024 * 1024

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    convenience init(initialWorkspace: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Morrow Navigator"
        window.minSize = NSSize(width: 950, height: 480)
        window.center()
        window.tabbingMode = .preferred
        self.init(window: window)

        remoteHosts = loadManagedRemoteHosts()
        pinnedWorkspaceURLs = loadPinnedWorkspaces()
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

        let sourcesSidebar = makeSourcesSidebar()
        let workspaceSidebar = makeSidebar()
        let browser = makeBrowser()

        splitView.addArrangedSubview(sourcesSidebar)
        splitView.addArrangedSubview(workspaceSidebar)
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
        let savedSourcesWidth = UserDefaults.standard.object(forKey: "sourcesSidebarWidth") as? NSNumber
        let savedWorkspaceWidth = UserDefaults.standard.object(forKey: "sidebarWidth") as? NSNumber
        setSourcesSidebarWidth(CGFloat(savedSourcesWidth?.doubleValue ?? 210), persist: false)
        setSidebarWidth(CGFloat(savedWorkspaceWidth?.doubleValue ?? 260), persist: false)
        isRestoringSidebarWidth = false
    }

    private func setSourcesSidebarWidth(_ requestedWidth: CGFloat, persist: Bool) {
        guard splitView.subviews.count >= 3 else { return }
        let minimumSourcesWidth: CGFloat = 150
        let minimumWorkspaceWidth: CGFloat = 190
        let minimumBrowserWidth: CGFloat = 360
        let maximumSourcesWidth = max(
            minimumSourcesWidth,
            splitView.bounds.width - (splitView.dividerThickness * 2) - minimumWorkspaceWidth - minimumBrowserWidth
        )
        let width = min(max(requestedWidth, minimumSourcesWidth), min(320, maximumSourcesWidth))
        splitView.setPosition(width, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        if persist {
            UserDefaults.standard.set(Double(width), forKey: "sourcesSidebarWidth")
        }
    }

    private func setSidebarWidth(_ requestedWidth: CGFloat, persist: Bool) {
        guard splitView.subviews.count >= 3 else { return }
        let minimumWorkspaceWidth: CGFloat = 190
        let minimumBrowserWidth: CGFloat = 360
        let sourcesWidth = splitView.subviews[0].frame.width
        let maximumWorkspaceWidth = max(
            minimumWorkspaceWidth,
            splitView.bounds.width - sourcesWidth - (splitView.dividerThickness * 2) - minimumBrowserWidth
        )
        let width = min(max(requestedWidth, minimumWorkspaceWidth), maximumWorkspaceWidth)
        let dividerPosition = sourcesWidth + splitView.dividerThickness + width
        splitView.setPosition(dividerPosition, ofDividerAt: 1)
        splitView.layoutSubtreeIfNeeded()
        if persist {
            UserDefaults.standard.set(Double(width), forKey: "sidebarWidth")
        }
    }

    private func makeSourcesSidebar() -> NSView {
        let container = SidebarBackgroundView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let pinnedLabel = NSTextField(labelWithString: "PINNED")
        pinnedLabel.translatesAutoresizingMaskIntoConstraints = false
        pinnedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        pinnedLabel.textColor = .secondaryLabelColor

        pinnedWorkspacesStack.translatesAutoresizingMaskIntoConstraints = false
        pinnedWorkspacesStack.orientation = .vertical
        pinnedWorkspacesStack.alignment = .leading
        pinnedWorkspacesStack.spacing = 1
        rebuildPinnedWorkspaceButtons()

        let remoteLabel = NSTextField(labelWithString: "REMOTE")
        remoteLabel.translatesAutoresizingMaskIntoConstraints = false
        remoteLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        remoteLabel.textColor = .secondaryLabelColor

        let addRemoteButton = symbolButton("plus", action: #selector(addRemoteHost))
        addRemoteButton.toolTip = "Add Remote Connection…"

        remoteHostsStack.translatesAutoresizingMaskIntoConstraints = false
        remoteHostsStack.orientation = .vertical
        remoteHostsStack.alignment = .leading
        remoteHostsStack.spacing = 1
        rebuildRemoteHostButtons()

        container.addSubview(pinnedLabel)
        container.addSubview(pinnedWorkspacesStack)
        container.addSubview(remoteLabel)
        container.addSubview(addRemoteButton)
        container.addSubview(remoteHostsStack)

        NSLayoutConstraint.activate([
            pinnedLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            pinnedLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),

            pinnedWorkspacesStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            pinnedWorkspacesStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            pinnedWorkspacesStack.topAnchor.constraint(equalTo: pinnedLabel.bottomAnchor, constant: 5),

            remoteLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            remoteLabel.topAnchor.constraint(equalTo: pinnedWorkspacesStack.bottomAnchor, constant: 18),

            addRemoteButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            addRemoteButton.centerYAnchor.constraint(equalTo: remoteLabel.centerYAnchor),

            remoteHostsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            remoteHostsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            remoteHostsStack.topAnchor.constraint(equalTo: remoteLabel.bottomAnchor, constant: 5),
            remoteHostsStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8)
        ])

        return container
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

        configureSymbolButton(workspacePinButton, symbol: "pin", action: #selector(toggleCurrentWorkspacePin))
        workspacePinButton.toolTip = "Pin Workspace"
        configureSymbolButton(workspaceParentButton, symbol: "arrow.up", action: #selector(useParentAsWorkspace))
        workspaceParentButton.toolTip = "Use Parent Folder as Workspace"
        configureSymbolButton(workspaceCurrentButton, symbol: "scope", action: #selector(useCurrentDirectoryAsWorkspace))
        workspaceCurrentButton.toolTip = "Use Current Folder as Workspace"
        let chooseButton = symbolButton("folder.badge.plus", action: #selector(chooseWorkspace))
        chooseButton.toolTip = "Open Folder as Workspace…"
        let refreshButton = symbolButton("arrow.clockwise", action: #selector(refresh))
        refreshButton.toolTip = "Refresh"

        let buttonStack = NSStackView(views: [workspacePinButton, workspaceParentButton, workspaceCurrentButton, chooseButton, refreshButton])
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

    private var pinnedWorkspacesDefaultsKey: String { "pinnedWorkspaceURLs.v1" }
    private var permanentPinnedWorkspaceURL: URL { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }

    private func isPermanentPinnedWorkspace(_ url: URL) -> Bool {
        url.standardizedFileURL == permanentPinnedWorkspaceURL
    }

    private func loadPinnedWorkspaces() -> [URL] {
        let saved = (UserDefaults.standard.stringArray(forKey: pinnedWorkspacesDefaultsKey) ?? [])
            .compactMap(URL.init(string:))
            .filter { FileSystemLocation(url: $0)?.kind == .local }
            .filter { !isPermanentPinnedWorkspace($0) }
        return [permanentPinnedWorkspaceURL] + saved
    }

    private func persistPinnedWorkspaces() {
        let userPins = pinnedWorkspaceURLs
            .filter { !isPermanentPinnedWorkspace($0) }
            .map(\.absoluteString)
        UserDefaults.standard.set(userPins, forKey: pinnedWorkspacesDefaultsKey)
    }

    private func rebuildPinnedWorkspaceButtons() {
        for view in pinnedWorkspacesStack.arrangedSubviews {
            pinnedWorkspacesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !pinnedWorkspaceURLs.isEmpty else {
            let label = NSTextField(labelWithString: "No pinned workspaces")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            pinnedWorkspacesStack.addArrangedSubview(label)
            return
        }

        for url in pinnedWorkspaceURLs {
            guard let location = FileSystemLocation(url: url) else { continue }
            let isPermanent = isPermanentPinnedWorkspace(url)
            let title = isPermanent ? "~" : location.name
            let button = NSButton(title: title, target: self, action: #selector(openPinnedWorkspace(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
            button.image = NSImage(
                systemSymbolName: isPermanent ? "house" : "folder",
                accessibilityDescription: isPermanent ? "Home" : "Pinned Workspace"
            )
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.bezelStyle = .inline
            button.isBordered = false
            button.toolTip = location.displayPath

            let row: NSStackView
            if isPermanent {
                row = NSStackView(views: [button])
            } else {
                let removeButton = NSButton()
                configureSymbolButton(removeButton, symbol: "minus.circle", action: #selector(removePinnedWorkspace(_:)))
                removeButton.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
                removeButton.toolTip = "Unpin \(location.name)"
                row = NSStackView(views: [button, removeButton])
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            row.orientation = .horizontal
            row.spacing = 2
            row.distribution = .fill
            pinnedWorkspacesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: pinnedWorkspacesStack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
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
            let button = NSButton(title: host.displayTitle, target: self, action: #selector(openRemoteHost(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.identifier = NSUserInterfaceItemIdentifier(host.id)
            let symbol = host.kind == .github ? "chevron.left.forwardslash.chevron.right" : "server.rack"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: host.kind.displayName)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.bezelStyle = .inline
            button.isBordered = false
            button.toolTip = "\(host.kind.displayName) · \(host.endpointDescription)"

            let badge = host.kind == .github && host.rootPath != "/" ? "GH REPO" : (host.kind == .github ? "GITHUB" : "SFTP")
            let kindBadge = NSTextField(labelWithString: badge)
            kindBadge.font = .systemFont(ofSize: 8.5, weight: .semibold)
            kindBadge.textColor = .tertiaryLabelColor
            kindBadge.alignment = .right
            kindBadge.setContentHuggingPriority(.required, for: .horizontal)

            let removeButton = NSButton()
            configureSymbolButton(removeButton, symbol: "minus.circle", action: #selector(removeRemoteHost(_:)))
            removeButton.identifier = NSUserInterfaceItemIdentifier(host.id)
            removeButton.toolTip = "Remove \(host.displayTitle) from Navigator"
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

    private func isPinnedWorkspace(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        return pinnedWorkspaceURLs.contains { $0.standardizedFileURL == target }
    }

    private func updateWorkspacePinButton() {
        guard let root = rootNode?.location, root.kind == .local else {
            workspacePinButton.isEnabled = false
            workspacePinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin Workspace")
            workspacePinButton.toolTip = "Only local workspaces can be pinned"
            return
        }
        if isPermanentPinnedWorkspace(root.url) {
            workspacePinButton.isEnabled = false
            workspacePinButton.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Permanently Pinned Workspace")
            workspacePinButton.toolTip = "~ is permanently pinned"
            return
        }
        let pinned = isPinnedWorkspace(root.url)
        workspacePinButton.isEnabled = true
        workspacePinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: pinned ? "Unpin Workspace" : "Pin Workspace"
        )
        workspacePinButton.toolTip = pinned ? "Unpin Workspace" : "Pin Workspace"
    }

    @objc private func toggleCurrentWorkspacePin() {
        guard let root = rootNode?.location, root.kind == .local else { return }
        let url = root.url.standardizedFileURL
        guard !isPermanentPinnedWorkspace(url) else { return }
        if isPinnedWorkspace(url) {
            pinnedWorkspaceURLs.removeAll { $0.standardizedFileURL == url }
        } else {
            pinnedWorkspaceURLs.append(url)
            pinnedWorkspaceURLs.sort {
                if isPermanentPinnedWorkspace($0) { return true }
                if isPermanentPinnedWorkspace($1) { return false }
                return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        }
        persistPinnedWorkspaces()
        rebuildPinnedWorkspaceButtons()
        updateWorkspacePinButton()
    }

    @objc private func openPinnedWorkspace(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        setWorkspace(url)
    }

    @objc private func removePinnedWorkspace(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        let standardized = url.standardizedFileURL
        guard !isPermanentPinnedWorkspace(standardized) else { return }
        pinnedWorkspaceURLs.removeAll { $0.standardizedFileURL == standardized }
        persistPinnedWorkspaces()
        rebuildPinnedWorkspaceButtons()
        updateWorkspacePinButton()
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
        tableScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        previewPane.isHidden = true
        previewPane.setContentCompressionResistancePriority(.required, for: .horizontal)
        let browserContentStack = NSStackView(views: [tableScroll, previewPane])
        browserContentStack.translatesAutoresizingMaskIntoConstraints = false
        browserContentStack.orientation = .horizontal
        browserContentStack.alignment = .centerY
        browserContentStack.spacing = 0
        browserContentStack.distribution = .fill
        let previewWidth = previewPane.widthAnchor.constraint(equalToConstant: 320)
        previewWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            previewWidth,
            previewPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            tableScroll.heightAnchor.constraint(equalTo: browserContentStack.heightAnchor),
            previewPane.heightAnchor.constraint(equalTo: browserContentStack.heightAnchor)
        ])

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
        container.addSubview(browserContentStack)
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

            browserContentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            browserContentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            browserContentStack.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            browserContentStack.bottomAnchor.constraint(equalTo: commandSeparator.topAnchor),

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
        guard let location = FileSystemLocation(url: url) else { return }

        let info: FileInfo
        if location.kind == .local {
            guard let localInfo = try? fileSystem.info(at: location), localInfo.isNavigableDirectory else { return }
            info = localInfo
        } else {
            info = FileInfo(
                url: location.url,
                name: location.name,
                isDirectory: true,
                isPackage: false,
                size: nil,
                modifiedAt: nil,
                isHidden: false
            )
        }

        let root = FileNode(info: info, fileSystem: fileSystem, cache: directoryCache)
        rootNode = root
        let workspaceTitle = remoteHosts.first(where: { $0.navigationLocation == location })?.displayTitle ?? info.name
        workspaceLabel.stringValue = workspaceTitle.uppercased()
        workspaceLabel.toolTip = location.displayPath
        if location.kind == .local {
            UserDefaults.standard.set(location.path, forKey: "lastWorkspacePath")
        }
        UserDefaults.standard.set(location.url.absoluteString, forKey: "lastWorkspaceURL")

        history.removeAll(keepingCapacity: true)
        historyIndex = -1
        outlineView.reloadData()
        navigate(to: location.url, recordHistory: true, revealInSidebar: false)
        updateWorkspaceButtons()
    }

    private func navigate(to url: URL, recordHistory: Bool, revealInSidebar: Bool = true) {
        guard let location = FileSystemLocation(url: url),
              let rootLocation = rootNode?.location,
              location.isDescendant(of: rootLocation) else { return }

        if location.kind != .local {
            navigateExternal(to: location, recordHistory: recordHistory, revealInSidebar: revealInSidebar)
            return
        }

        remoteNavigationRequestID = nil
        remoteNavigationRequestLocation = nil
        browserRevealButton.isEnabled = true
        do {
            tableItems = try fileSystem.children(of: location)
            currentDirectory = location.url
            watchCurrentDirectory(location.url)
            pathControl.url = location.url
            pathControl.toolTip = location.displayPath
            tableView.reloadData()
            tableView.deselectAll(nil)
            updateStatus()

            if recordHistory { recordNavigationHistory(location.url) }
            updateNavigationButtons()
            updateWorkspaceButtons()
            if revealInSidebar { selectDirectoryInSidebar(location) }
        } catch {
            tableItems = []
            tableView.reloadData()
            statusLabel.stringValue = "Unable to read \(location.name): \(error.localizedDescription)"
        }
    }

    private func navigateExternal(
        to location: FileSystemLocation,
        recordHistory: Bool,
        revealInSidebar: Bool,
        forceRefresh: Bool = false
    ) {
        directoryWatcher.stop()
        browserRevealButton.isEnabled = false
        currentDirectory = location.url
        pathControl.url = location.url
        pathControl.toolTip = location.displayPath

        let cached = directoryCache.cachedDirectory(location)
        tableItems = cached?.items ?? []
        tableView.reloadData()
        tableView.deselectAll(nil)
        let source = [location.kind.displayName, location.authority].compactMap { $0 }.joined(separator: " · ")
        if let cached {
            statusLabel.stringValue = "Cached · \(cached.items.count) item\(cached.items.count == 1 ? "" : "s")"
        } else {
            statusLabel.stringValue = "No cached data"
        }
        if recordHistory { recordNavigationHistory(location.url) }
        updateNavigationButtons()
        updateWorkspaceButtons()
        if revealInSidebar { selectDirectoryInSidebar(location) }

        let now = Date()
        let shouldRefresh = forceRefresh || shouldAutomaticallyRefreshExternal(location, now: now)
        guard shouldRefresh else {
            if remoteNavigationRequestLocation != location {
                remoteNavigationRequestID = nil
                remoteNavigationRequestLocation = nil
            }
            if cached == nil {
                statusLabel.stringValue = remoteNavigationRequestLocation == location
                    ? "Loading \(source)…"
                    : "No cached data · use Refresh to retry \(source)"
            }
            return
        }

        let requestID = UUID()
        remoteNavigationRequestID = requestID
        remoteNavigationRequestLocation = location
        remoteRefreshTimes[location] = now
        if let cached {
            statusLabel.stringValue = "Cached · \(cached.items.count) item\(cached.items.count == 1 ? "" : "s") · refreshing \(source)…"
        } else {
            statusLabel.stringValue = "Loading \(source)…"
        }

        let service = fileSystem
        let cache = directoryCache
        let cachedItems = cached?.items
        Task { [weak self] in
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try service.children(of: location)
                }.value
                try? cache.store(items, for: location)
                guard let self, self.remoteNavigationRequestID == requestID else { return }
                self.remoteNavigationRequestID = nil
                self.remoteNavigationRequestLocation = nil
                if cachedItems != items {
                    self.tableItems = items
                    self.tableView.reloadData()
                    self.tableView.deselectAll(nil)
                }
                self.statusLabel.stringValue = "\(source) · \(items.count) item\(items.count == 1 ? "" : "s")"
                self.updateWorkspaceNode(location: location, items: items)
                if revealInSidebar { self.selectDirectoryInSidebar(location) }
                self.updateNavigationButtons()
            } catch {
                guard let self, self.remoteNavigationRequestID == requestID else { return }
                self.remoteNavigationRequestID = nil
                self.remoteNavigationRequestLocation = nil
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

    private func shouldAutomaticallyRefreshExternal(_ location: FileSystemLocation, now: Date = Date()) -> Bool {
        guard let lastRefresh = remoteRefreshTimes[location] else { return true }
        return now.timeIntervalSince(lastRefresh) >= remoteAutoRefreshInterval
    }

    private func recordNavigationHistory(_ url: URL) {
        if historyIndex + 1 < history.count {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        if history.last != url { history.append(url) }
        historyIndex = max(0, history.count - 1)
    }

    private func node(for location: FileSystemLocation) -> FileNode? {
        guard let root = rootNode,
              let rootLocation = root.location,
              location.isDescendant(of: rootLocation) else { return nil }
        if location == rootLocation { return root }

        let relative: String
        if rootLocation.path == "/" {
            relative = String(location.path.dropFirst())
        } else {
            relative = String(location.path.dropFirst(rootLocation.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let components = relative.split(separator: "/").map(String.init)
        var node = root
        for component in components {
            guard let child = node.child(named: component) else { return nil }
            node = child
        }
        return node
    }

    private func updateWorkspaceNode(location: FileSystemLocation, items: [FileInfo]) {
        guard let node = node(for: location) else { return }
        node.replaceChildren(with: items)
        if node === rootNode {
            outlineView.reloadItem(nil, reloadChildren: true)
        } else {
            outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    private func selectDirectoryInSidebar(_ location: FileSystemLocation) {
        guard let root = rootNode,
              let rootLocation = root.location,
              location.isDescendant(of: rootLocation) else { return }

        suppressOutlineSelection = true
        defer { suppressOutlineSelection = false }
        if location == rootLocation {
            outlineView.deselectAll(nil)
            return
        }
        guard let node = node(for: location) else { return }
        var ancestors: [FileNode] = []
        var parent = node.parent
        while let current = parent, current !== root {
            ancestors.append(current)
            parent = current.parent
        }
        for ancestor in ancestors.reversed() { outlineView.expandItem(ancestor) }
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    private func refreshExternalNode(_ node: FileNode, forceRefresh: Bool = false) {
        guard let location = node.location, location.kind != .local else { return }
        let now = Date()
        guard forceRefresh || shouldAutomaticallyRefreshExternal(location, now: now) else { return }
        remoteRefreshTimes[location] = now
        let service = fileSystem
        let cache = directoryCache
        Task { [weak self, weak node] in
            do {
                let items = try await Task.detached(priority: .utility) {
                    try service.children(of: location)
                }.value
                try? cache.store(items, for: location)
                guard let self, let node else { return }
                node.replaceChildren(with: items)
                if node === self.rootNode {
                    self.outlineView.reloadItem(nil, reloadChildren: true)
                } else {
                    self.outlineView.reloadItem(node, reloadChildren: true)
                }
            } catch {
                // Cached children remain visible while an external provider is unavailable.
            }
        }
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex >= 0 && historyIndex < history.count - 1
        upButton.isEnabled = browserParentDestination() != nil
    }

    private func browserParentDestination() -> URL? {
        guard let currentDirectory,
              let current = FileSystemLocation(url: currentDirectory),
              let root = rootNode?.location,
              current.isDescendant(of: root),
              current != root else { return nil }
        return current.parent.url
    }

    private func updateWorkspaceButtons() {
        guard let root = rootNode?.location else {
            workspaceParentButton.isEnabled = false
            workspaceCurrentButton.isEnabled = false
            workspacePinButton.isEnabled = false
            return
        }
        workspaceParentButton.isEnabled = root.parent != root
        if let currentDirectory, let current = FileSystemLocation(url: currentDirectory) {
            workspaceCurrentButton.isEnabled = current.kind == root.kind
                && current.authority == root.authority
                && current != root
        } else {
            workspaceCurrentButton.isEnabled = false
        }
        updateWorkspacePinButton()
    }

    private func updatePreviewForSelection() {
        let selectedRows = tableView.selectedRowIndexes
        guard selectedRows.count == 1,
              let row = selectedRows.first,
              tableItems.indices.contains(row) else {
            clearPreview()
            return
        }

        let item = tableItems[row]
        guard !item.isDirectory else {
            clearPreview()
            return
        }
        let details = previewDetails(for: item)

        guard let location = item.location else {
            clearPreview()
            return
        }
        if location.kind == .local {
            previewRequestID = nil
            removePreviewTemporaryDirectory()
            previewPane.isHidden = false
            previewPane.showPreview(url: item.url, details: details)
            return
        }
        if let size = item.size, size > Int64(remotePreviewByteLimit) {
            previewRequestID = nil
            removePreviewTemporaryDirectory()
            previewPane.isHidden = false
            previewPane.showMessage(
                details: details,
                message: "Remote preview is limited to \(ByteCountFormatter.string(fromByteCount: Int64(remotePreviewByteLimit), countStyle: .file))."
            )
            return
        }

        let requestID = UUID()
        previewRequestID = requestID
        removePreviewTemporaryDirectory()
        previewPane.isHidden = false
        previewPane.showLoading(details: details)
        let service = fileSystem
        let maxBytes = remotePreviewByteLimit
        let filename = item.name

        Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try service.fileContents(of: location, maxBytes: maxBytes)
                }.value
                guard let self, self.previewRequestID == requestID else { return }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("morrow-navigator-preview-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let safeName = filename.replacingOccurrences(of: "/", with: "_")
                let fileURL = directory.appendingPathComponent(safeName.isEmpty ? "preview" : safeName)
                try data.write(to: fileURL, options: .atomic)
                guard self.previewRequestID == requestID else {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                self.previewTemporaryDirectory = directory
                self.previewPane.showPreview(url: fileURL, details: details)
            } catch {
                guard let self, self.previewRequestID == requestID else { return }
                self.removePreviewTemporaryDirectory()
                self.previewPane.showMessage(
                    details: details,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func previewDetails(for item: FileInfo) -> FilePreviewDetails {
        let path = item.location?.displayPath ?? item.url.path
        return FilePreviewDetails(
            name: item.name,
            kind: kindText(for: item),
            size: item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—",
            modified: item.modifiedAt.map(dateFormatter.string(from:)) ?? "—",
            path: path
        )
    }

    private func clearPreview() {
        previewRequestID = nil
        previewPane.clear()
        previewPane.isHidden = true
        removePreviewTemporaryDirectory()
    }

    private func removePreviewTemporaryDirectory() {
        guard let previewTemporaryDirectory else { return }
        try? FileManager.default.removeItem(at: previewTemporaryDirectory)
        self.previewTemporaryDirectory = nil
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
        if info.location?.kind != .local {
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
           let location = FileSystemLocation(url: currentDirectory),
           location.kind != .local,
           let command = arguments.first?.lowercased(),
           !["help", "back", "forward", "ui"].contains(command) {
            let result = NavigatorCommandResult.failure(
                "Command execution is not available yet for \(location.kind.displayName) filesystems. Browsing is read-only."
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
            let workspaceWidth = splitView.subviews.count > 1 ? splitView.subviews[1].frame.width : 0
            return .ok("sidebar_width=\(Int(workspaceWidth))")
        case .uiState:
            let workspace = rootNode?.location?.displayPath ?? ""
            let directory = currentDirectory.map {
                FileSystemLocation(url: $0)?.displayPath ?? $0.path
            } ?? ""
            let selected = tableView.selectedRowIndexes.compactMap { index -> String? in
                guard tableItems.indices.contains(index) else { return nil }
                return tableItems[index].location?.displayPath ?? tableItems[index].url.path
            }
            let output = [
                "workspace=\(workspace)",
                "cwd=\(directory)",
                "items=\(tableItems.count)",
                "outline_rows=\(outlineView.numberOfRows)",
                "up_enabled=\(upButton.isEnabled)",
                "selection=\(selected.joined(separator: ","))",
                "preview_visible=\(!previewPane.isHidden)",
                "window_width=\(Int(window?.frame.width ?? 0))",
                "sources_width=\(Int(splitView.subviews.first?.frame.width ?? 0))",
                "sidebar_width=\(Int(splitView.subviews.count > 1 ? splitView.subviews[1].frame.width : 0))",
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
        guard let root = rootNode?.location, root.parent != root else { return }
        setWorkspace(root.parent.url)
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
        panel.directoryURL = currentDirectory.flatMap { url in
            FileSystemLocation(url: url)?.kind == .local ? url : nil
        } ?? (rootNode?.location?.kind == .local ? rootNode?.info.url : nil)
            ?? FileManager.default.homeDirectoryForCurrentUser
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setWorkspace(url)
        }
    }

    @objc func refresh() {
        guard let root = rootNode?.location else { return }
        if let currentDirectory,
           let current = FileSystemLocation(url: currentDirectory),
           current.kind != .local {
            navigateExternal(
                to: current,
                recordHistory: false,
                revealInSidebar: false,
                forceRefresh: true
            )
            return
        }

        rootNode?.invalidateChildren(recursively: true)
        outlineView.reloadData()
        if let currentDirectory, FileManager.default.fileExists(atPath: currentDirectory.path) {
            navigate(to: currentDirectory, recordHistory: false)
        } else {
            navigate(to: root.url, recordHistory: false)
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
        guard let currentDirectory, FileSystemLocation(url: currentDirectory)?.kind == .local else { return }
        if tableView.selectedRow >= 0, tableItems.indices.contains(tableView.selectedRow) {
            NSWorkspace.shared.activateFileViewerSelecting([tableItems[tableView.selectedRow].url])
        } else {
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
        } else if let location = item.location, location.kind != .local {
            statusLabel.stringValue = "\(location.displayPath) · external file opening is not available yet"
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func openContextItem() {
        guard let item = itemForContextMenu() else { return }
        if item.isNavigableDirectory {
            navigate(to: item.url, recordHistory: true)
        } else if let location = item.location, location.kind != .local {
            statusLabel.stringValue = "\(location.displayPath) · external file opening is not available yet"
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func useContextItemAsWorkspace() {
        guard let item = itemForContextMenu(), item.isNavigableDirectory else { return }
        setWorkspace(item.url)
    }

    @objc private func revealContextItem() {
        guard let item = itemForContextMenu(), item.location?.kind == .local else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func copyContextPath() {
        guard let item = itemForContextMenu() else { return }
        NSPasteboard.general.clearContents()
        let path = item.location?.displayPath ?? item.url.path
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func openRemoteHost(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let host = remoteHosts.first(where: { $0.id == id }) else { return }
        setWorkspace(host.navigationLocation.url)
    }

    @objc private func addRemoteHost() {
        guard let window else { return }
        let existingAliases = Set(remoteHosts.filter { $0.rootPath == "/" }.map(\.alias))
        let availableHosts = sshConfigDiscovery.hosts().filter { !existingAliases.contains($0.alias) }
        let picker = RemoteConnectionPickerView(hosts: availableHosts)

        let alert = NSAlert()
        alert.messageText = "Add Remote Connection"
        alert.informativeText = "Choose a configured connection, add a GitHub repository directly, or create a new SFTP connection."
        let addButton = alert.addButton(withTitle: "Add Selected")
        addButton.isEnabled = !availableHosts.isEmpty
        alert.addButton(withTitle: "GitHub Repository…")
        alert.addButton(withTitle: "New SFTP…")
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
                    self?.presentNewSFTPConnectionSheet()
                }
            }
        }
    }

    private func loadGitHubRepositoriesAndPresentPicker() {
        let service = fileSystem
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

    private func presentNewSFTPConnectionSheet() {
        guard let window else { return }
        let form = NewSFTPConnectionView()
        let alert = NSAlert()
        alert.messageText = "New SFTP Connection"
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
                    self.presentRemoteConnectionError("The SSH config entry was written, but Navigator could not reload the SFTP connection.")
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
        switch dividerIndex {
        case 0:
            return max(proposedMinimumPosition, 150)
        case 1:
            let sourcesWidth = splitView.subviews.first?.frame.width ?? 150
            return max(proposedMinimumPosition, sourcesWidth + splitView.dividerThickness + 190)
        default:
            return proposedMinimumPosition
        }
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        switch dividerIndex {
        case 0:
            let maximumSourcesWidth = max(
                150,
                splitView.bounds.width - (splitView.dividerThickness * 2) - 190 - 360
            )
            return min(proposedMaximumPosition, min(320, maximumSourcesWidth))
        case 1:
            let maximumWorkspaceEdge = max(
                150 + splitView.dividerThickness + 190,
                splitView.bounds.width - splitView.dividerThickness - 360
            )
            return min(proposedMaximumPosition, maximumWorkspaceEdge)
        default:
            return proposedMaximumPosition
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isRestoringSidebarWidth,
              let splitView = notification.object as? NSSplitView,
              splitView === self.splitView,
              splitView.subviews.count >= 3 else { return }
        let sourcesWidth = splitView.subviews[0].frame.width
        let workspaceWidth = splitView.subviews[1].frame.width
        if sourcesWidth > 0 {
            UserDefaults.standard.set(Double(sourcesWidth), forKey: "sourcesSidebarWidth")
        }
        if workspaceWidth > 0 {
            UserDefaults.standard.set(Double(workspaceWidth), forKey: "sidebarWidth")
        }
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
            return item.location?.kind == .local
        }
        if menuItem.action == #selector(openContextItem),
           let item = itemForContextMenu(),
           item.location?.kind != .local {
            return item.isNavigableDirectory
        }
        return true
    }
}

extension MainWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode { return node.children().count }
        return rootNode?.children().count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode { return node.children()[index] }
        return rootNode!.children()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let info = (item as? FileNode)?.info else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ExplorerCell")
        let cell: NSTableCellView
        if let reusable = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reusable
        } else {
            cell = makeIconTextCell(identifier: identifier)
        }
        cell.textField?.stringValue = info.name
        cell.textField?.toolTip = info.location?.displayPath ?? info.url.path
        cell.imageView?.image = icon(for: info)
        return cell
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?.values.compactMap({ $0 as? FileNode }).first else { return }
        _ = node.children()
        refreshExternalNode(node)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressOutlineSelection else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }

        if node.info.isNavigableDirectory {
            navigate(to: node.info.url, recordHistory: true, revealInSidebar: false)
        } else if let parent = node.parent {
            navigate(to: parent.info.url, recordHistory: true, revealInSidebar: false)
            if let index = tableItems.firstIndex(where: { $0.location == node.info.location }) {
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
        updatePreviewForSelection()
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
