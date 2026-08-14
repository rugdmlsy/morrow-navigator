import AppKit
import QuickLookUI

@MainActor
final class FilePreviewPane: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let previewView: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)!
    private let messageLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1

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

        addSubview(separator)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(previewView)
        addSubview(messageLabel)
        addSubview(spinner)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.heightAnchor.constraint(equalToConstant: 16),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.heightAnchor.constraint(equalToConstant: 14),

            previewView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            previewView.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewView.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 6),
            previewView.bottomAnchor.constraint(equalTo: bottomAnchor),

            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            messageLabel.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: messageLabel.topAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPreview(url: URL, title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        messageLabel.isHidden = true
        spinner.stopAnimation(nil)
        previewView.isHidden = false
        previewView.previewItem = url as NSURL
        previewView.refreshPreviewItem()
    }

    func showLoading(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        previewView.previewItem = nil
        previewView.isHidden = true
        messageLabel.stringValue = "Loading preview…"
        messageLabel.isHidden = false
        spinner.startAnimation(nil)
    }

    func showMessage(title: String, detail: String, message: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
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
        detailLabel.stringValue = ""
    }
}
