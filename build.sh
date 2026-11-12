#!/bin/bash
# Build "Window Scarves.app" with Apple's Command Line Tools (no Xcode needed).
#   ./build.sh            build into build/
#   ./build.sh --install  also copy it into ~/Applications and open it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Window Scarves.app"
BIN="$APP/Contents/MacOS/WindowScarves"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

FLAGS=(-O -swift-version 5 -framework AppKit -framework QuartzCore -framework Carbon -framework ServiceManagement)
archs=()
for arch in arm64 x86_64; do
  if swiftc "${FLAGS[@]}" -target "$arch-apple-macos13.0" -o "build/obj/WindowScarves-$arch" Sources/*.swift; then
    archs+=("build/obj/WindowScarves-$arch")
  else
    echo "note: couldn't build for $arch, skipping it" >&2
  fi
done
[ ${#archs[@]} -gt 0 ] || { echo "build failed" >&2; exit 1; }
lipo -create "${archs[@]}" -output "$BIN"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: ad-hoc signing skipped" >&2
echo "Built $APP ($(lipo -archs "$BIN"))"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x WindowScarves 2>/dev/null || true
  rm -rf "$HOME/Applications/Window Scarves.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/Window Scarves.app"
  echo "Installed to ~/Applications and opened it. Look for 🧣 in your menu bar."
fi
