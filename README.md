# Morrow Navigator

A lightweight native macOS file navigator built around one rule: the GUI is a frontend to capabilities that remain accessible from the shell.

The app uses AppKit directly and keeps the file tree lazy so opening a large workspace does not recursively crawl the filesystem.

## MVP

- Three-column browser layout: pinned/remote sources, active workspace explorer, and file browser
- VS Code-style active workspace explorer using `NSOutlineView`
- Lazy directory expansion with instant row-based toggle behavior
- Native file list with name, kind, size, and modified time
- Back/forward navigation
- Movable workspace root: promote to the parent or shrink to the current/selected child folder at any time
- `cd ..` at the workspace root automatically promotes the parent instead of hitting a hard boundary
- Refresh, select, open, and reveal files
- Built-in command bar (`⌘L` focuses it)
- External `morrow-navigator` CLI (`mnavi` short alias) using the same command parser and command engine
- Live GUI synchronization for CLI mutations
- Lightweight current-directory watcher for changes made by ordinary shell tools such as `touch`, `mv`, and `rm`
- Unified read-only filesystem browsing across local files, SFTP remotes, and GitHub repositories
- Automatic in-place file preview on single selection, using macOS Quick Look for local files and on-demand temporary fetches for remote files
- Restore the last workspace on launch

Hidden files remain omitted from the GUI by default; `ls -a` can inspect them from the command interface.

The leftmost sources column keeps **PINNED** workspaces and **REMOTE** connections separate from the active workspace tree. Local workspace roots can be pinned or unpinned with the pin button beside the workspace title; pinned shortcuts persist across launches and switch the active workspace when clicked. Remote connections use explicit **SFTP**, **GITHUB**, or **GH REPO** badges. **+** opens a connection picker populated from `~/.ssh/config`; those OpenSSH entries supply host, user, port, and key settings, while filesystem operations themselves use the SFTP subsystem. It also provides **GitHub Repository…**, which loads repositories accessible to the account authenticated by `gh`, plus **New SFTP…** for creating a normal OpenSSH `Host` block from structured connection fields. Navigator never stores passwords or private-key contents. The minus button removes only the Navigator shortcut, not the underlying SSH config entry or GitHub repository.

Local, SFTP, and GitHub locations share one `FileSystemLocation` model and one `FileSystemProvider` interface for metadata, child enumeration, and file reads. `UnifiedFileSystemService` routes each operation to `LocalFileSystemProvider`, `SFTPFileSystemProvider`, or `GitHubFileSystemProvider`; the GUI therefore uses one `FileNode` tree and one navigation path instead of separate local/remote implementations. Existing saved `ssh://` Navigator URLs are accepted as legacy input and normalized to `sftp://`.

Non-local directory listings are cached lazily under `~/Library/Caches/MorrowNavigator/FileSystemDirectories`. Revisiting an SFTP or GitHub directory renders cached metadata immediately while a background refresh runs. SFTP browsing uses the system `sftp` client directly and does not execute a remote shell or require remote Python. GitHub remains a virtual filesystem backed by the authenticated GitHub CLI (`gh`), because GitHub SSH provides Git transport rather than general SFTP access. Aliases named `github-<owner>` are scoped directly to that owner; a generic GitHub authority keeps the all-accessible-owners view. GitHub browsing requires `gh auth login`. Non-local browsing is read-only for now.

Selecting exactly one file opens an embedded preview pane on the right side of the browser. Local files are passed directly to macOS Quick Look. SFTP and GitHub files are fetched only when selected, written to a temporary preview file, and rendered by the same Quick Look view; non-local previews are capped at 8 MB. A details section below the preview shows the file kind, size, modified time, and full provider-specific path. Directories, multiple selections, and cleared selections collapse the preview pane automatically.

## Command model

There is one command vocabulary, not separate GUI and shell command sets.

From a terminal:

```bash
mnavi pwd
mnavi ls
mnavi workspace ~/workspaces
mnavi cd morrow-navigator
mnavi ws .       # make the current folder the workspace root
mnavi cd ..      # at the root, promote its parent automatically
mnavi ws ..      # explicitly use the current folder's parent as root
mnavi mkdir notes
mnavi touch notes/idea.md
mnavi mv notes/idea.md notes/design.md
mnavi select notes/design.md
mnavi open notes/design.md
mnavi rm notes/design.md
mnavi ui state
```

The official executable name is `morrow-navigator`; `mnavi` is the short daily-use alias. The top-level `morrow` command is intentionally left unclaimed for a future Morrow ecosystem dispatcher.

Inside the app command bar, enter the same commands without any executable prefix:

```text
pwd
ls
cd Sources
mkdir Scratch
mv old.txt new.txt
ui state
```

Run `help` for the complete command list.

The workspace is a movable browsing root, not a fixed VS Code-style boundary. The middle column contains only the active workspace tree; the left sources column holds pinned workspaces and remotes. In the workspace header, the pin button pins a local root, the up-arrow promotes the workspace to its parent, the scope button uses the current directory as the new workspace, and a child folder's context menu provides **Use as Workspace**. The same workspace-root operations are available as `ws ..`, `ws .`, and `ws <child>`.

When Morrow Navigator is running, the CLI sends commands to the app over local per-user IPC. Filesystem operations therefore update the same state observed by the GUI immediately. When the app is not running, stateless filesystem commands such as `ls`, `mkdir`, `touch`, `mv`, `cp`, `rm`, `open`, and `reveal` can still run directly; commands that manipulate Navigator navigation state require the app.

`mnavi --json ...` (or `morrow-navigator --json ...`) returns a machine-readable `NavigatorCommandResult` for automation and agents.

## Architecture

```text
                         MorrowNavigatorCore
                FileSystemLocation + FileInfo
                              |
                  UnifiedFileSystemService
                 /            |             \
              Local          SFTP          GitHub
           FileManager   system sftp       gh api
                 \            |             /
                  +------ one FileNode -----+
                              |
                          AppKit GUI
                              |
                        local IPC / CLI
```

The GUI owns presentation state such as the active workspace, current directory, selection, and navigation history. Filesystem commands are defined once in `MorrowNavigatorCore`; GUI-specific commands are limited to the `ui ...` namespace.

## Stack

- Swift 6
- AppKit (`NSOutlineView`, `NSTableView`, `NSOpenPanel`, `NSWorkspace`)
- Foundation distributed notifications + per-user temporary request/response files for lightweight local IPC
- Dispatch vnode source for current-directory change notification
- macOS system `sftp` client for remote filesystem access; OpenSSH config/credentials remain system-owned
- GitHub CLI (`gh`) for the GitHub virtual filesystem
- Swift Package Manager
- No Electron, WebView, Node.js, or third-party runtime dependencies

## Build

```bash
swift run MorrowNavigatorCoreSelfTest
./scripts/build-app.sh
open "dist/Morrow Navigator.app"
```

`build-app.sh` also builds `dist/morrow-navigator` and installs two symlinks: `~/.local/bin/morrow-navigator` and `~/.local/bin/mnavi`. It removes the old `~/.local/bin/morrow` only when that symlink points to this Navigator project, leaving the `morrow` namespace free for the wider ecosystem.

The self-test executable is used instead of XCTest so the project can be built and verified with Apple's standalone Command Line Tools; full Xcode is not required.
