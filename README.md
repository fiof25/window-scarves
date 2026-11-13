# window-scarves

A little macOS menu-bar app that gives each of your windows a cozy scarf for autumn. 🧣🍂

![Four windows, each wearing a different scarf: a lilac mohair check, a cream cable knit, a red fine knit and a cocoa check](docs/hero.png)

## The collection

![All six scarves: Lilac Check, Cream Cable, Rosehip, Cocoa Check, Moss Check and Blush](docs/colourways.png)

Every app gets a different scarf. Choose **Shuffle** in the menu to deal them out again, or pick one scarf for every window.

![Close-up of the lilac mohair check](docs/close-up.png)

## Get it

Window Scarves needs macOS 13 or later. It's built for both Apple Silicon and Intel Macs, and so far it has been tested on Apple Silicon.

### Download

1. Download **Window-Scarves.zip** from the [latest release](https://github.com/fiof25/window-scarves/releases/latest).
2. Unzip it and drag **Window Scarves.app** into your Applications folder.
3. Open it. Look for 🧣 in your menu bar.

The first time you open it, macOS will block it, because the app isn't signed with a paid Apple developer account. To allow it, open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**. You only need to do this once.

### Build it yourself

You need Apple's Command Line Tools (`xcode-select --install`). Xcode itself isn't needed.

```sh
git clone https://github.com/fiof25/window-scarves.git
cd window-scarves
./build.sh --install
```

This builds the app, copies **Window Scarves.app** into `~/Applications`, and opens it. Run `./build.sh` without `--install` to build into `build/` only, or `./build.sh --zip` to also make a zip for a release.

## Make yourself cozy

Press **⌃⌥S** (Control-Option-S) anywhere to turn the scarves off and on.

Click 🧣 in the menu bar for the rest:

- **Scarf**: Mixed, Shuffle, or one scarf for every window
- **Long End**: on the right or on the left
- **Thickness**: Slim, Cozy or Chunky
- **Windows**: every window, or only the front one
- **Apps**: untick an app to leave its windows bare
- **Keyboard Shortcut ⌃⌥S**: turn the shortcut off if you don't want it
- **Start at Login**: open Window Scarves automatically when you log in

Not every window gets one. A window that fills the whole screen goes bare. So does anything attached to another window, whatever its size: drop-downs (like a browser's address-bar suggestions), popovers and sheets. macOS keeps those glued directly above their parent window, and the app checks for exactly that. Some apps draw their pop-ups as ordinary windows instead, so small ones sitting on a bigger window of the same app are also left bare, judged by size and position. That means a genuinely small window that opens on top of a bigger one from the same app goes bare too, until you move it off. Once a window has worn a scarf it keeps it, even when you click it in front of a bigger window of the same app.

The scarf stays on the window's top edge, so it never covers the red, yellow and green buttons. When a window first puts its scarf on, the scarf is fitted to the room on screen beside it: if there's no room, the long end moves to the other side, the short end is left off, and as a last resort the long end tucks just inside the window's right edge. After that the scarf stays as it is when you drag the window around and let go, even right up to the edge of the screen. Resizing a window fits its scarf again but keeps the long end on the same side, unless that would tuck it in over the window's buttons.

When you click the desktop and macOS sweeps your windows to the edges of the screen, the scarves slip off while the windows are in flight and settle back on once they land, both on the way out and on the way back.

## How it works

Window Scarves uses only public macOS APIs, and it doesn't need any permissions.

- `CGWindowListCopyWindowInfo` reports where every window is and how they're stacked.
- Each scarf is a few small transparent, click-through windows, ordered directly above the window it's worn by. They cover only the scarf, so nothing invisible sits over the app's own content, and windows in front still cover the scarf, just like real fabric.
- The app checks the windows 10 times a second when nothing is happening, and 120 times a second while anything is moving, so scarves keep up with drags and resizes without wasting power.
- Pressing on a window, to drag it, resize it or just click in it, makes macOS put that window in front of everything at its level, its own scarf included, and for a frame or two the scarf would be covered: a flash. So while the pointer is moving over a window, that window's scarf is lifted just above the ordinary windows, where a press can't cover it, and it settles back a couple of seconds after the pointer stops or leaves. This only happens when nothing in front overlaps the scarf, so lifting it changes nothing you can see.
- Switching tabs in a tabbed window (Finder, Terminal and others) swaps in a different window at exactly the same place. The scarf is handed across to the new window instead of being taken off and knitted again, so it stays put as you click from tab to tab.
- Scarves are made into images in the background and remade as a window is resized. The knitted ones are made in several strips at once on separate processor cores. The mohair ones are mostly see-through drawing, which macOS can't safely do on several cores at once, so they're made in one go. Scarves fade in rather than popping, and the app idles at about 1 to 2% CPU.

Render the preview images without touching your real windows:

```sh
"build/Window Scarves.app/Contents/MacOS/WindowScarves" --render docs
```

To check the scarf-making code without touching any windows (thousands of checks, including that scarves knitted in parallel pieces match ones knitted whole):

```sh
"build/Window Scarves.app/Contents/MacOS/WindowScarves" --self-test
```

To see exactly what the app is drawing on your real windows, start it with `SCARVES_SNAPSHOT` set to a folder. A few seconds later it saves a picture of each scarf there:

```sh
open --env SCARVES_SNAPSHOT=/tmp/scarves "build/Window Scarves.app"
```

## Taking it off

Choose **Quit Window Scarves** from the 🧣 menu and drag the app to the Trash. To clear its saved settings as well:

```sh
defaults delete com.fiof25.windowscarves
```

## Ideas for later

- Sewing buttons over the red, yellow and green window buttons
- Falling leaves drifting past the active window
- Choosing a scarf for each app by hand
- More textures: bouclé, a blanket scarf
- Choosing your own keyboard shortcut
- A winter collection

## Credits

Inspired by Sara Gordić's lovely [Window Sweaters](https://github.com/saragordic/window-sweaters), which gives your windows knitted sweaters. Window Scarves is a separate project written from scratch in Swift, and it shares no code with Window Sweaters.

Released under the MIT License. See [LICENSE](LICENSE).
