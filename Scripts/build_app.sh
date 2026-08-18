#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="DiskBloom"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

cd "$ROOT"
echo "[1/5] Release binary"
swift build -c release --product DiskBloom

echo "[2/5] App icon"
python3 "$ROOT/Scripts/make_icon.py" >/dev/null
rm -f "$ROOT/Assets/DiskBloom.icns"
iconutil -c icns "$ROOT/Assets/DiskBloom.iconset" -o "$ROOT/Assets/DiskBloom.icns"

echo "[3/5] App bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/release/DiskBloom" "$CONTENTS/MacOS/DiskBloom"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Assets/DiskBloom.icns" "$CONTENTS/Resources/DiskBloom.icns"
chmod 755 "$CONTENTS/MacOS/DiskBloom"

echo "[4/5] Local signature"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "[5/5] Distribution zip"
rm -f "$DIST/DiskBloom.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/DiskBloom.zip"

printf '\nBuilt:\n  %s\n  %s\n' "$APP" "$DIST/DiskBloom.zip"
