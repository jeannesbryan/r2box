#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.6.0}"
ARCH="${ARCH:-x86_64}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APPDIR="$ROOT/AppDir"

BIN="$BUILD_DIR/r2box"
ICON="$ROOT/r2box.png"

if ! command -v v >/dev/null 2>&1; then
  echo "ERROR: V compiler not found in PATH." >&2
  exit 1
fi

if [[ ! -f "$ROOT/main.v" ]]; then
  echo "ERROR: main.v not found in $ROOT" >&2
  exit 1
fi

if [[ ! -f "$ICON" ]]; then
  echo "ERROR: r2box.png not found in $ROOT" >&2
  exit 1
fi

APPIMAGETOOL=""
if command -v appimagetool >/dev/null 2>&1; then
  APPIMAGETOOL="$(command -v appimagetool)"
elif [[ -x "$HOME/.local/bin/appimagetool" ]]; then
  APPIMAGETOOL="$HOME/.local/bin/appimagetool"
else
  echo "ERROR: appimagetool not found." >&2
  echo "Expected either appimagetool in PATH or ~/.local/bin/appimagetool" >&2
  exit 1
fi

echo "==> Formatting main.v"
v fmt -w "$ROOT/main.v"

echo "==> Building production binary"
mkdir -p "$BUILD_DIR" "$DIST_DIR"
v -prod -o "$BIN" "$ROOT/main.v"

echo "==> Checking dynamic libraries"
if ldd "$BIN" | grep -q "not found"; then
  echo "ERROR: missing runtime libraries:" >&2
  ldd "$BIN" | grep "not found" >&2
  exit 1
fi

echo "==> Creating fresh AppDir"
rm -rf "$APPDIR"
mkdir -p \
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps"

cp "$BIN" "$APPDIR/usr/bin/r2box"
cp "$ICON" "$APPDIR/r2box.png"
cp "$ICON" "$APPDIR/usr/share/icons/hicolor/256x256/apps/r2box.png"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
APPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$APPDIR/usr/bin/r2box" "$@"
EOF
chmod 755 "$APPDIR/AppRun"

cat > "$APPDIR/r2box.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=R2Box
Comment=Experimental Cloudflare R2 / S3 desktop client
Exec=r2box
Icon=r2box
Terminal=false
Categories=Network;Utility;
EOF

cp "$APPDIR/r2box.desktop" "$APPDIR/usr/share/applications/r2box.desktop"

ln -sfn r2box.png "$APPDIR/.DirIcon"

echo "==> Testing AppRun"
"$APPDIR/AppRun" &
TEST_PID=$!
sleep 2

if kill -0 "$TEST_PID" 2>/dev/null; then
  kill "$TEST_PID" 2>/dev/null || true
  wait "$TEST_PID" 2>/dev/null || true
  echo "AppRun started successfully."
else
  wait "$TEST_PID" || {
    echo "ERROR: AppRun exited with an error." >&2
    exit 1
  }
fi

OUTPUT="$DIST_DIR/R2Box-${VERSION}-${ARCH}.AppImage"

echo "==> Building AppImage"
ARCH="$ARCH" "$APPIMAGETOOL" "$APPDIR" "$OUTPUT"

chmod +x "$OUTPUT"

echo
echo "DONE"
echo "AppImage: $OUTPUT"
echo
echo "Run:"
echo "  \"$OUTPUT\""
echo
echo "NOTE: xclip is still expected on the host for R2Box Paste buttons."
