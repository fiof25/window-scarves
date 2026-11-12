# window-scarves

A little macOS menu-bar app that drapes a cosy knitted scarf over each of your windows for autumn. 🧣🍂

Each window wears one soft, flowy scarf: a loose end pokes out above one corner, the scarf sags across the top of the window, goes up and over the other corner, and hangs down the side with a fringe. The window's red, yellow and green buttons become little sewing buttons.

![Four windows, each with a knitted scarf draped across the top and hanging down one side](docs/hero.png)

## The colourways

![All seven colourways](docs/colourways.png)

- **Rosehip** (the default): a soft, warm red with cream stripes at the ends
- **Candy Stripe**: wide rosehip and cream stripes
- **Pumpkin Patch**: warm pumpkin with the odd cream stripe
- **Marigold**: honey yellow with burnt-orange tips
- **Buffalo Check**: soft red and charcoal lumberjack checks
- **Evergreen**: mossy pine green with cream stripes
- **Raspberry**: dusty berry pink with thin blush stripes

**By App** gives each app its own scarf from the collection, and it stays the same every time.

Every stitch is drawn in code. The scarf follows a curved path, its width ripples a little like real fabric, and it has a fuzzy mohair halo and a wispy fringe at both ends.

![Close-up of the rosehip scarf's stitches, stripes and fringe](docs/close-up.png)

## Get it

You need macOS 13 or later and Apple's Command Line Tools (`xcode-select --install`). Xcode itself isn't needed.

```sh
git clone https://github.com/fiof25/window-scarves.git
cd window-scarves
./build.sh --install
```

This builds a universal app (Apple Silicon and Intel), copies **Window Scarves.app** into `~/Applications`, and opens it. Look for 🧣 in your menu bar.

Run `./build.sh` without `--install` to build into `build/` only.

The app isn't notarized. If macOS blocks it, open **System Settings → Privacy & Security** and choose **Open Anyway**.

## Make yourself cosy

Press **⌘D** anywhere to turn the scarves off and on.

> ⌘D is a system-wide shortcut, so while Window Scarves is running it replaces ⌘D in other apps (for example Bookmark in browsers and Duplicate in Finder). To use a different key, change the `HotKey(...)` line in `Sources/main.swift`.

Click 🧣 in the menu bar for the rest:

- **Colourway**: one scarf for every window, or By App
- **Hangs Down**: on the right or on the left
- **Thickness**: Slim, Cosy or Chunky
- **Windows**: every window, or only the front one
- **Apps**: untick an app to leave its windows bare
- **Buttons on Window Controls**: show or hide the sewing buttons
- **Line Up Buttons Exactly…**: see below

If there isn't room on screen beside a window for the hanging end, the scarf hangs down the other side instead.

### The buttons

The sewing buttons are only pictures. Clicks pass straight through to the real close, minimise and zoom buttons underneath.

macOS only tells an app exactly where another window's buttons are if it has Accessibility permission. Without it, Window Scarves puts the buttons where they usually are, which is right for most windows but can be a few points off in apps with unusual title bars. Choose **Line Up Buttons Exactly…** to grant permission, and each button then sits exactly on the real one. The permission is optional and is only used for this.

## How it works

Window Scarves uses only public macOS APIs.

- `CGWindowListCopyWindowInfo` reports where every window is and how they're stacked. This needs no permission.
- Each scarf is its own transparent, click-through window, ordered directly above the window it's draped over. Windows in front still cover it, just like real fabric.
- The app checks every 0.2 seconds, and more often while you drag a window, so scarves follow along.
- Scarves are knitted into images on a background thread and cached, so the app idles at under 1% CPU.

Render the preview images without touching your real windows:

```sh
"build/Window Scarves.app/Contents/MacOS/WindowScarves" --render docs
```

## Ideas for later

- Falling leaves drifting past the active window
- Choosing a colourway per app
- A choice of keyboard shortcut in the menu
- A winter collection

## Credits

Inspired by Sara Gordić's lovely [Window Sweaters](https://github.com/saragordic/window-sweaters), which gives your windows knitted sweaters. Window Scarves is a separate project written from scratch in Swift, and it shares no code with Window Sweaters.

Released under the MIT License. See [LICENSE](LICENSE).
