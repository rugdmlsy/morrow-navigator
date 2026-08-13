# Morrow Navigator

A lightweight native macOS file navigator built around one rule: the GUI is a frontend to capabilities that remain accessible from the shell.

The app uses AppKit directly and keeps the file tree lazy so opening a large workspace does not recursively crawl the filesystem.

## MVP

- VS Code-style workspace explorer using `NSOutlineView`
- Lazy directory expansion with instant row-based toggle behavior
- Native file list with name, kind, size, and modified time
- Back/forward navigation
- Open/change workspace
- Refresh, select, open, and reveal files
- Built-in command bar (`⌘L` focuses it)
- External `morrow` CLI using the same command parser and command engine
- Live GUI synchronization for CLI mutations
- Lightweight current-directory watcher for changes made by ordinary shell tools such as `touch`, `mv`, and `rm`
- Restore the last workspace on launch

Hidden files remain omitted from the GUI by default; `ls -a` can inspect them from the command interface.

## Command model

There is one command vocabulary, not separate GUI and shell command sets.

From a terminal:

```bash
morrow pwd
morrow ls
morrow workspace ~/workspaces
morrow cd morrow-navigator
morrow mkdir notes
morrow touch notes/idea.md
morrow mv notes/idea.md notes/design.md
morrow select notes/design.md
morrow open notes/design.md
morrow rm notes/design.md
morrow ui state
```

Inside the app command bar, enter the same commands without the `morrow` executable prefix:

```text
pwd
ls
cd Sources
mkdir Scratch
mv old.txt new.txt
ui state
```

Run `help` for the complete command list.

When Morrow Navigator is running, the CLI sends commands to the app over local per-user IPC. Filesystem operations therefore update the same state observed by the GUI immediately. When the app is not running, stateless filesystem commands such as `ls`, `mkdir`, `touch`, `mv`, `cp`, `rm`, `open`, and `reveal` can still run directly; commands that manipulate Navigator navigation state require the app.

`morrow --json ...` returns a machine-readable `NavigatorCommandResult` for automation and agents.

## Architecture

```text
                    MorrowNavigatorCore
             command parser + filesystem engine
                    /                 \
             AppKit GUI              morrow CLI
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
- Swift Package Manager
- No Electron, WebView, Node.js, or third-party runtime dependencies

## Build

```bash
swift run MorrowNavigatorCoreSelfTest
./scripts/build-app.sh
open "dist/Morrow Navigator.app"
```

`build-app.sh` also builds `dist/morrow` and symlinks it to `~/.local/bin/morrow`.

The self-test executable is used instead of XCTest so the project can be built and verified with Apple's standalone Command Line Tools; full Xcode is not required.
