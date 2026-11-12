# window-scarves

A little macOS menu-bar app that gives each of your windows a cosy scarf for autumn. 🧣🍂

Each window wears one soft scarf that hugs it like a neck: a short end hangs down one side, the scarf runs along the top edge, wraps over the corner, and the long end hangs down the other side. Every app gets a different scarf from the collection.

![Four windows, each wearing a different scarf: a lilac mohair check, an oatmeal rib knit, a red fine knit and a cocoa check](docs/hero.png)

## The collection

Nine scarves in three textures, each with its own fringe.

![All nine scarves](docs/colourways.png)

**Brushed mohair** (fuzzy, no visible stitches, long fine fringe)

- **Lilac Check**: lilac, butter and pink
- **Cocoa Check**: cocoa, sky blue and cream
- **Moss Check**: moss, butter and navy
- **Blush**: solid powder pink

**Chunky rib knit** (fat stitches, short tassels)

- **Oat Milk**: heathered oatmeal
- **Camel**: warm camel

**Fine knit** (little V stitches, wispy fringe)

- **Rosehip**: soft red with cream stripes at the ends
- **Heather Grey**: grey melange with charcoal stripes at the ends
- **Varsity Stripe**: a skinny scarf in navy and cream with a rust thread

**Mixed** (the default) gives each app a different scarf and remembers it. **Shuffle** deals them out again.

Everything is drawn in code. The scarf follows a curved path, its width ripples a little like real fabric, the checks blend where colours cross, and each texture has its own fuzzy halo.

![Close-up of the lilac mohair check](docs/close-up.png)

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

- **Scarf**: Mixed, Shuffle, or one scarf for every window
- **Long End**: on the right or on the left
- **Thickness**: Slim, Cosy or Chunky
- **Windows**: every window, or only the front one
- **Apps**: untick an app to leave its windows bare
- **Buttons on Window Controls**: see below

The scarf stays on the window's top edge, so it never covers the red, yellow and green buttons. If there's no room on screen beside a window, the long end moves to the other side, the short end is left off, and as a last resort the long end tucks just inside the window.

### The buttons

Window Scarves can turn each window's red, yellow and green buttons into little sewing buttons. They're only pictures: clicks pass straight through to the real buttons underneath.

This needs Accessibility permission. Where those buttons sit differs from app to app (16 points in on plain windows, 26 on windows with toolbars, and anywhere at all in apps that draw their own title bars), so the only way to place a sewing button exactly on top is to ask the window, and macOS only allows that with permission. The app asks once when it first opens, and there's a menu item to ask again. Without permission the scarves work as normal and no sewing buttons are drawn. The permission is only used for this.

The app is ad-hoc signed, so macOS treats each new build as a different app. After rebuilding, switch Window Scarves off and on again under **System Settings → Privacy & Security → Accessibility**.

## How it works

Window Scarves uses only public macOS APIs.

- `CGWindowListCopyWindowInfo` reports where every window is and how they're stacked. This needs no permission, so the scarves work without any.
- Each scarf is its own transparent, click-through window, ordered directly above the window it's worn by. Windows in front still cover it, just like real fabric.
- The app checks every 0.2 seconds, and more often while you drag a window, so scarves follow along.
- Scarves are knitted into images on a background thread and cached, so the app idles at under 1% CPU.

Render the preview images without touching your real windows:

```sh
"build/Window Scarves.app/Contents/MacOS/WindowScarves" --render docs
```

## Ideas for later

- Falling leaves drifting past the active window
- Choosing a scarf for each app by hand
- More textures: cable knit, bouclé, a blanket scarf
- A choice of keyboard shortcut in the menu
- A winter collection

## Credits

Inspired by Sara Gordić's lovely [Window Sweaters](https://github.com/saragordic/window-sweaters), which gives your windows knitted sweaters. Window Scarves is a separate project written from scratch in Swift, and it shares no code with Window Sweaters.

Released under the MIT License. See [LICENSE](LICENSE).
