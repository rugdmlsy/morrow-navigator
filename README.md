# Morrow Navigator

A lightweight native macOS file navigator built around one rule: the GUI is a frontend to capabilities that remain accessible from the shell.

The app uses AppKit directly and keeps the file tree lazy so opening a large workspace does not recursively crawl the filesystem.

## MVP

- VS Code-style workspace explorer using `NSOutlineView`
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
- Read-only remote directory browsing over SSH plus GitHub repository browsing for SSH aliases that resolve to `github.com`
- Automatic in-place file preview on single selection, using macOS Quick Look for local files and on-demand temporary fetches for remote files
- Restore the last workspace on launch

Hidden files remain omitted from the GUI by default; `ls -a` can inspect them from the command interface.

Remote connections appear in the sidebar under **REMOTE** with explicit **SSH**, **GITHUB**, or **GH REPO** badges. **+** opens a connection picker populated from `~/.ssh/config`, showing each unused alias together with its detected type and effective endpoint metadata. It also provides **GitHub Repository…**, which loads repositories accessible to the account authenticated by `gh` and adds a selected `owner/repository` as a direct sidebar shortcut, plus **New SSH…** for creating a normal OpenSSH `Host` block from structured alias/host/user/port/identity-file fields. Navigator never stores passwords or private-key contents; new SSH connections are written to `~/.ssh/config` and authentication remains owned by the system SSH client. The minus button removes only the Navigator shortcut, not the underlying SSH config entry or GitHub repository.

Remote directory listings are cached lazily under `~/Library/Caches/MorrowNavigator/RemoteDirectories`. Revisiting a directory renders cached metadata immediately while a background refresh runs; fresh results replace stale cache entries. Ordinary SSH hosts use a short-lived OpenSSH multiplexed connection and require remote `python3` for structured metadata. SSH aliases that resolve to `github.com` are treated as a virtual repository filesystem instead: Navigator uses the authenticated GitHub CLI (`gh`) to browse repositories and repository contents because GitHub SSH intentionally provides Git transport rather than shell access. Aliases named `github-<owner>` are scoped directly to that GitHub owner (for example, `github-reslab-asu` opens the `reslab-asu` repository list); a generic GitHub alias keeps the all-accessible-owners view. GitHub browsing requires `gh auth login`. Remote folders can also be promoted to the main workspace root, and remote browsing remains read-only for now.

Selecting exactly one file opens an embedded preview pane on the right side of the browser. Local files are passed directly to macOS Quick Look. Remote GitHub and SSH files are fetched only when selected, written to a temporary preview file, and then rendered by the same Quick Look view; remote previews are capped at 8 MB to avoid accidentally downloading large files. A details section below the preview shows the file kind, size, modified time, and full local or remote path. Directories, multiple selections, and cleared selections collapse the preview pane automatically.

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

The workspace is a movable browsing root, not a fixed VS Code-style boundary. In the GUI, the sidebar's up-arrow promotes the workspace to its parent, the scope button uses the current directory as the new workspace, and a child folder's context menu provides **Use as Workspace**. The same operations are available as `ws ..`, `ws .`, and `ws <child>`.

When Morrow Navigator is running, the CLI sends commands to the app over local per-user IPC. Filesystem operations therefore update the same state observed by the GUI immediately. When the app is not running, stateless filesystem commands such as `ls`, `mkdir`, `touch`, `mv`, `cp`, `rm`, `open`, and `reveal` can still run directly; commands that manipulate Navigator navigation state require the app.

`mnavi --json ...` (or `morrow-navigator --json ...`) returns a machine-readable `NavigatorCommandResult` for automation and agents.

## Architecture

```text
                    MorrowNavigatorCore
             command parser + filesystem engine
                    /                 \
             AppKit GUI       morrow-navigator / mnavi
                 |                       |
                 +----- local IPC -------+
                 |
          directory change watcher
```

The GUI owns presentation state such as the active workspace, current directory, selection, and navigation history. Filesystem commands are defined once in `MorrowNavigatorCore`; GUI-specific commands are limited to the `ui ...` namespace.

## Stack

- Swift 6
- AppKit (`NSOutlineView`, `NSTableView`, `NSOpenPanel`, `NSWorkspace`)
- Foundation distributed notifications + per-user temporary request/response files for lightweight local IPC
- Dispatch vnode source for current-directory change notification
- macOS system `ssh` client for remote directory metadata; no bundled SSH credentials
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
