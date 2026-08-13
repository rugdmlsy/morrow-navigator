#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Morrow Navigator.app"
CLI="$ROOT/dist/morrow-navigator"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BIN_DIR/MorrowNavigator" "$MACOS/MorrowNavigator"
cp "$BIN_DIR/morrow-navigator" "$CLI"
chmod +x "$CLI"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Morrow Navigator</string>
    <key>CFBundleExecutable</key>
    <string>MorrowNavigator</string>
    <key>CFBundleIdentifier</key>
    <string>com.xycdev.morrow-navigator</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Morrow Navigator</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP" >/dev/null
fi

mkdir -p "$HOME/.local/bin"
ln -sf "$CLI" "$HOME/.local/bin/morrow-navigator"
ln -sf "$CLI" "$HOME/.local/bin/mnavi"

# Remove only the legacy Navigator-owned `morrow` symlink. Never touch an
# unrelated command so the top-level name stays available for the Morrow suite.
LEGACY="$HOME/.local/bin/morrow"
if [[ -L "$LEGACY" ]]; then
    LEGACY_TARGET="$(readlink "$LEGACY")"
    case "$LEGACY_TARGET" in
        "$ROOT/dist/morrow"|"$ROOT/dist/morrow-navigator") rm -f "$LEGACY" ;;
    esac
fi
rm -f "$ROOT/dist/morrow"

echo "$APP"
echo "CLI: $CLI"
echo "Installed: $HOME/.local/bin/morrow-navigator"
echo "Alias: $HOME/.local/bin/mnavi"
