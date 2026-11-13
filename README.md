# window-scarves

A little macOS menu-bar app that gives each of your windows a cozy scarf for autumn. 🧣🍂

![Four windows, each wearing a different scarf: a lilac mohair check, a cream cable knit, a red fine knit and a cocoa check](docs/hero.png)

![All six scarves: Lilac Check, Cream Cable, Rosehip, Cocoa Check, Moss Check and Blush](docs/colourways.png)

![Close-up of the lilac mohair check](docs/close-up.png)

## Install

Needs macOS 13 or later. Runs on Apple Silicon and Intel; tested on Apple Silicon. Uses only public macOS APIs and needs no permissions.

### Download

1. Download **Window-Scarves.zip** from the [latest release](https://github.com/fiof25/window-scarves/releases/latest).
2. Unzip it and drag **Window Scarves.app** into your Applications folder.
3. Open it and look for 🧣 in your menu bar.

The app isn't signed with an Apple developer account, so macOS blocks it the first time. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.

### Build from source

Needs Apple's Command Line Tools (`xcode-select --install`), not Xcode.

```sh
git clone https://github.com/fiof25/window-scarves.git
cd window-scarves
./build.sh --install
```

- `./build.sh` builds into `build/`
- `./build.sh --install` also copies the app into `~/Applications` and opens it
- `./build.sh --zip` also makes a release zip

## Use

Press **⌃⌥S** (Control-Option-S) to turn the scarves off and on. Everything else is in the 🧣 menu:

- **Scarf**: Mixed (a different scarf for each app), Shuffle, or one scarf for every window
- **Long End**: on the right or on the left
- **Thickness**: Slim, Cozy or Chunky
- **Windows**: every window, or only the front one
- **Apps**: untick an app to leave its windows bare
- **Keyboard Shortcut ⌃⌥S**: turn the shortcut on or off
- **Start at Login**

Windows that go without a scarf: full-screen windows, and drop-downs, popovers and sheets. Small windows sitting on a bigger window of the same app go without one too, until you move them off.

The scarf never covers the red, yellow and green buttons. If there's no room beside a window when its scarf goes on, the long end goes on the other side. Dragging a window doesn't change its scarf, and resizing it keeps the long end on the same side.

## Developer options

```sh
# Render the preview images in docs/
"build/Window Scarves.app/Contents/MacOS/WindowScarves" --render docs

# Render the 1280x640 picture for link previews (upload it under Settings > Social preview)
"build/Window Scarves.app/Contents/MacOS/WindowScarves" --render-social docs/social-preview.png

# Run the self-test
"build/Window Scarves.app/Contents/MacOS/WindowScarves" --self-test

# Save a picture of each scarf on your screen to a folder
open --env SCARVES_SNAPSHOT=/tmp/scarves "build/Window Scarves.app"
```

## Uninstall

Choose **Quit Window Scarves** from the 🧣 menu and drag the app to the Trash. To clear its settings:

```sh
defaults delete com.fiof25.windowscarves
```

## Credits

Inspired by Sara Gordić's [Window Sweaters](https://github.com/saragordic/window-sweaters). Window Scarves is written from scratch in Swift and shares no code with it.

Released under the MIT License. See [LICENSE](LICENSE).
