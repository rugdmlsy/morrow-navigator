import AppKit
import QuickLookUI

struct FilePreviewDetails {
    let name: String
    let kind: String
    let size: String
    let modified: String
    let path: String
}

private final class HoverIconButton: NSButton {
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

@MainActor
final class FilePreviewPane: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewView: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)!
    private let messageLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private let detailsSeparator = NSBox()
    private let kindValue = NSTextField(labelWithString: "—")
    private let sizeValue = NSTextField(labelWithString: "—")
    private let modifiedValue = NSTextField(labelWithString: "—")
    private let pathValue = NSTextField(wrappingLabelWithString: "—")
    private let copyPathButton = HoverIconButton()
    private var currentPath: String?
    private var copyConfirmationPopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let sideSeparator = NSBox()
        sideSeparator.translatesAutoresizingMaskIntoConstraints = false
        sideSeparator.boxType = .separator

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.autostarts = true

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 4
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.isHidden = true

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        detailsSeparator.translatesAutoresizingMaskIntoConstraints = false
        detailsSeparator.boxType = .separator

        [kindValue, sizeValue, modifiedValue].forEach { field in
            field.font = .systemFont(ofSize: 11.5)
            field.textColor = .labelColor
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
        }
        pathValue.font = .systemFont(ofSize: 11.5)
        pathValue.textColor = .labelColor
        pathValue.maximumNumberOfLines = 2
        pathValue.lineBreakMode = .byTruncatingMiddle
        pathValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        copyPathButton.translatesAutoresizingMaskIntoConstraints = false
        copyPathButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy Path")
        copyPathButton.bezelStyle = .inline
        copyPathButton.isBordered = false
        copyPathButton.target = self
        copyPathButton.action = #selector(copyPath)
        copyPathButton.toolTip = "Copy Path"
        copyPathButton.isHidden = true
        copyPathButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            copyPathButton.widthAnchor.constraint(equalToConstant: 22),
            copyPathButton.heightAnchor.constraint(equalToConstant: 22)
        ])

        let copyButtonContainer = NSView()
        copyButtonContainer.translatesAutoresizingMaskIntoConstraints = false
        copyButtonContainer.addSubview(copyPathButton)
        NSLayoutConstraint.activate([
            copyPathButton.centerXAnchor.constraint(equalTo: copyButtonContainer.centerXAnchor),
            copyPathButton.centerYAnchor.constraint(equalTo: copyButtonContainer.centerYAnchor)
        ])

        let detailsTitle = NSTextField(labelWithString: "DETAILS")
        detailsTitle.font = .systemFont(ofSize: 10.5, weight: .semibold)
        detailsTitle.textColor = .secondaryLabelColor

        let detailsGrid = NSGridView(views: [
            [detailLabel("Kind"), kindValue, NSView()],
            [detailLabel("Size"), sizeValue, NSView()],
            [detailLabel("Modified"), modifiedValue, NSView()],
            [detailLabel("Path"), pathValue, copyButtonContainer]
        ])
        detailsGrid.translatesAutoresizingMaskIntoConstraints = false
        detailsGrid.rowSpacing = 7
        detailsGrid.columnSpacing = 9
        detailsGrid.column(at: 0).xPlacement = .trailing
        detailsGrid.column(at: 1).xPlacement = .fill
        detailsGrid.column(at: 2).xPlacement = .trailing
        detailsGrid.column(at: 0).width = 53
        detailsGrid.column(at: 2).width = 22
        detailsGrid.row(at: 3).yPlacement = .fill
        detailsGrid.cell(atColumnIndex: 0, rowIndex: 3).yPlacement = .top
        detailsGrid.cell(atColumnIndex: 1, rowIndex: 3).yPlacement = .top
        detailsGrid.cell(atColumnIndex: 2, rowIndex: 3).yPlacement = .fill

        let detailsStack = NSStackView(views: [detailsTitle, detailsGrid])
        detailsStack.translatesAutoresizingMaskIntoConstraints = false
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 8

        addSubview(sideSeparator)
        addSubview(titleLabel)
        addSubview(previewView)
        addSubview(messageLabel)
        addSubview(spinner)
        addSubview(detailsSeparator)
        addSubview(detailsStack)

        NSLayoutConstraint.activate([
            sideSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            sideSeparator.topAnchor.constraint(equalTo: topAnchor),
            sideSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.heightAnchor.constraint(equalToConstant: 16),

            previewView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            previewView.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            previewView.bottomAnchor.constraint(equalTo: detailsSeparator.topAnchor),

            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            messageLabel.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: messageLabel.topAnchor, constant: -10),

            detailsSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailsSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailsSeparator.bottomAnchor.constraint(equalTo: detailsStack.topAnchor, constant: -9),

            detailsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            detailsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detailsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            detailsGrid.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),

            previewView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPreview(url: URL, details: FilePreviewDetails) {
        apply(details)
        messageLabel.isHidden = true
        spinner.stopAnimation(nil)
        previewView.isHidden = false
        previewView.previewItem = url as NSURL
        previewView.refreshPreviewItem()
    }

    func showLoading(details: FilePreviewDetails) {
        apply(details)
        previewView.previewItem = nil
        previewView.isHidden = true
        messageLabel.stringValue = "Loading preview…"
        messageLabel.isHidden = false
        spinner.startAnimation(nil)
    }

    func showMessage(details: FilePreviewDetails, message: String) {
        apply(details)
        previewView.previewItem = nil
        previewView.isHidden = true
        spinner.stopAnimation(nil)
        messageLabel.stringValue = message
        messageLabel.isHidden = false
    }

    func clear() {
        previewView.previewItem = nil
        previewView.isHidden = true
        spinner.stopAnimation(nil)
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
        titleLabel.stringValue = ""
        kindValue.stringValue = "—"
        sizeValue.stringValue = "—"
        modifiedValue.stringValue = "—"
        pathValue.stringValue = "—"
        pathValue.toolTip = nil
        currentPath = nil
        copyPathButton.isHidden = true
        copyConfirmationPopover?.close()
        copyConfirmationPopover = nil
    }

    private func apply(_ details: FilePreviewDetails) {
        titleLabel.stringValue = details.name
        titleLabel.toolTip = details.name
        kindValue.stringValue = details.kind
        sizeValue.stringValue = details.size
        modifiedValue.stringValue = details.modified
        pathValue.stringValue = details.path
        pathValue.toolTip = details.path
        let path = details.path.trimmingCharacters(in: .whitespacesAndNewlines)
        currentPath = path.isEmpty || path == "—" ? nil : path
        copyPathButton.isHidden = currentPath == nil
    }

    @objc private func copyPath() {
        guard let currentPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentPath, forType: .string)
        showCopyConfirmation()
    }

    private func showCopyConfirmation() {
        copyConfirmationPopover?.close()

        let label = NSTextField(labelWithString: "Copied")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 74, height: 30))
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        let controller = NSViewController()
        controller.view = container

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 74, height: 30)
        popover.contentViewController = controller
        copyConfirmationPopover = popover
        popover.show(relativeTo: copyPathButton.bounds, of: copyPathButton, preferredEdge: .maxY)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self, weak popover] in
            guard let self, let popover, self.copyConfirmationPopover === popover else { return }
            popover.close()
            self.copyConfirmationPopover = nil
        }
    }

    private func detailLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11.5)
        field.textColor = .secondaryLabelColor
        return field
    }
}
