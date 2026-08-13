# Morrow Navigator

A lightweight native macOS file navigator. The MVP uses AppKit directly and keeps the file tree lazy so opening a large workspace does not recursively crawl the filesystem.

## MVP

- VS Code-style workspace explorer using `NSOutlineView`
- Lazy directory expansion
- Native file list with name, kind, size, and modified time
- Back/forward navigation
- Open a workspace with `⌘O`
- Refresh with `⌘R`
- Double-click folders to navigate and files to open with the default app
- Reveal items in Finder
- Copy an item's absolute path from the context menu
- Restore the last workspace on launch

Hidden files are intentionally omitted in the first MVP.

## Stack

- Swift 6
- AppKit (`NSOutlineView`, `NSTableView`, `NSOpenPanel`, `NSWorkspace`)
- Swift Package Manager
- No Electron, WebView, Node.js, or third-party runtime dependencies

## Build

```bash
swift run MorrowNavigatorCoreSelfTest
./scripts/build-app.sh
open "dist/Morrow Navigator.app"
```

The self-test executable is used instead of XCTest so the project can be built and verified with Apple's standalone Command Line Tools; full Xcode is not required.
