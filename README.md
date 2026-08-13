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
- Read-only remote directory browsing over the system SSH client, with hosts discovered from `~/.ssh/config`
- Restore the last workspace on launch

Hidden files remain omitted from the GUI by default; `ls -a` can inspect them from the command interface.

Remote hosts appear in the sidebar under **REMOTE**. Selecting a host opens its filesystem root and uses the existing SSH alias, key, proxy, and host configuration. Remote browsing is intentionally read-only for now; local-only actions such as **Reveal in Finder** and **Use as Workspace** are disabled while browsing a remote location. The remote host must provide `python3` for structured directory metadata collection.

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
