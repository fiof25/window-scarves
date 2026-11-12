#!/bin/bash
# Build "Window Scarves.app" with Apple's Command Line Tools (no Xcode needed).
#   ./build.sh            build into build/
#   ./build.sh --install  also copy it into ~/Applications and open it
#   ./build.sh --zip      also make build/Window-Scarves.zip, ready to attach to a release
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
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Drop Finder metadata so it doesn't end up inside the signed app.
xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: ad-hoc signing skipped" >&2
echo "Built $APP ($(lipo -archs "$BIN"))"

case "${1:-}" in
  --install)
    mkdir -p "$HOME/Applications"
    pkill -x WindowScarves 2>/dev/null || true
    rm -rf "$HOME/Applications/Window Scarves.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/Window Scarves.app"
    echo "Installed to ~/Applications and opened it. Look for 🧣 in your menu bar."
    ;;
  --zip)
    ZIP="build/Window-Scarves.zip"
    rm -f "$ZIP"
    # No resource forks or extended attributes: those become stray "._" files that break the
    # app's signature when the zip is opened with command-line unzip.
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
    # Check it survives both ways of unzipping, and that the app inside still works.
    for tool in ditto unzip; do
      tmp=$(mktemp -d)
      if [ "$tool" = ditto ]; then ditto -x -k "$ZIP" "$tmp"; else unzip -q "$ZIP" -d "$tmp"; fi
      codesign --verify --deep --strict "$tmp/Window Scarves.app" \
        || { echo "zip check failed: bad signature after $tool" >&2; exit 1; }
      "$tmp/Window Scarves.app/Contents/MacOS/WindowScarves" --self-test >/dev/null \
        || { echo "zip check failed: self-test after $tool" >&2; exit 1; }
      rm -rf "$tmp"
    done
    echo "Made $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' ')), checked with ditto and unzip"
    ;;
esac
