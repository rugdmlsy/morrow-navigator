import AppKit
import MorrowNavigatorCore

@MainActor
final class RemoteConnectionPickerView: NSView {
    private let hosts: [RemoteHost]
    private let popup = NSPopUpButton()

    init(hosts: [RemoteHost]) {
        self.hosts = hosts
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 92))
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "From ~/.ssh/config")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor

        let detail = NSTextField(labelWithString: hosts.isEmpty
            ? "All configured connections are already added."
            : "Choose a configured SFTP connection. Existing SSH settings and keys will be reused for authentication.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping

        popup.removeAllItems()
        if hosts.isEmpty {
            popup.addItem(withTitle: "No available SSH config entries")
            popup.isEnabled = false
        } else {
            for host in hosts {
                let kind = host.kind == .github ? "GitHub" : "SFTP"
                popup.addItem(withTitle: "\(kind)  ·  \(host.alias)  ·  \(host.endpointDescription)")
            }
        }

        let stack = NSStackView(views: [title, popup, detail])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 420),
            heightAnchor.constraint(equalToConstant: 92),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            popup.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selectedHost: RemoteHost? {
        guard hosts.indices.contains(popup.indexOfSelectedItem) else { return nil }
        return hosts[popup.indexOfSelectedItem]
    }
}

@MainActor
final class GitHubRepositoryPickerView: NSView {
    private let repositories: [GitHubRepository]
    private var filteredRepositories: [GitHubRepository]
    private let searchField = NSSearchField()
    private let popup = NSPopUpButton()

    init(repositories: [GitHubRepository]) {
        self.repositories = repositories
        self.filteredRepositories = repositories
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 108))
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "GitHub Repository")
        title.font = .systemFont(ofSize: 12, weight: .semibold)

        searchField.placeholderString = "Filter owner/repository"
        searchField.target = self
        searchField.action = #selector(filterRepositories)

        let note = NSTextField(labelWithString: "Repositories are loaded from the account authenticated by gh. Private repositories are included when your token allows them.")
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping

        reloadPopup()
        let stack = NSStackView(views: [title, searchField, popup, note])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 440),
            heightAnchor.constraint(equalToConstant: 108),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            popup.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selectedRepository: GitHubRepository? {
        guard filteredRepositories.indices.contains(popup.indexOfSelectedItem) else { return nil }
        return filteredRepositories[popup.indexOfSelectedItem]
    }

    @objc private func filterRepositories() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredRepositories = repositories
        } else {
            filteredRepositories = repositories.filter {
                $0.fullName.localizedCaseInsensitiveContains(query)
            }
        }
        reloadPopup()
    }

    private func reloadPopup() {
        popup.removeAllItems()
        if filteredRepositories.isEmpty {
            popup.addItem(withTitle: "No matching repositories")
            popup.isEnabled = false
        } else {
            popup.isEnabled = true
            for repository in filteredRepositories {
                popup.addItem(withTitle: repository.fullName)
            }
        }
    }
}

@MainActor
final class NewSFTPConnectionView: NSView {
    private let aliasField = NSTextField()
    private let hostnameField = NSTextField()
    private let userField = NSTextField()
    private let portField = NSTextField()
    private let identityField = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
        translatesAutoresizingMaskIntoConstraints = false

        aliasField.placeholderString = "example: lab-server"
        hostnameField.placeholderString = "hostname or IP address"
        userField.placeholderString = "optional"
        portField.stringValue = "22"
        identityField.placeholderString = "optional, e.g. ~/.ssh/id_ed25519"

        let grid = NSGridView(views: [
            [label("Alias"), aliasField],
            [label("Host"), hostnameField],
            [label("User"), userField],
            [label("Port"), portField],
            [label("Identity File"), identityField]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        addSubview(grid)

        let note = NSTextField(labelWithString: "This writes a standard Host block to ~/.ssh/config. Passwords and private-key contents are never stored by Navigator.")
        note.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        addSubview(note)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 440),
            heightAnchor.constraint(equalToConstant: 180),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            note.leadingAnchor.constraint(equalTo: leadingAnchor),
            note.trailingAnchor.constraint(equalTo: trailingAnchor),
            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var definition: SSHConfigDiscovery.NewHost? {
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = hostnameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, !hostname.isEmpty else { return nil }
        let user = normalizedOptional(userField.stringValue)
        let identity = normalizedOptional(identityField.stringValue)
        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port: Int?
        if portText.isEmpty {
            port = nil
        } else {
            guard let parsedPort = Int(portText), (1...65535).contains(parsedPort) else { return nil }
            port = parsedPort
        }
        return SSHConfigDiscovery.NewHost(
            alias: alias,
            hostname: hostname,
            user: user,
            port: port,
            identityFile: identity
        )
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
