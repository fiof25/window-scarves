# window-scarves

A little macOS menu-bar app that gives each of your windows a cosy scarf for autumn. 🧣🍂

Each window wears one soft scarf that hugs it like a neck: a short end hangs down one side, the scarf runs along the top edge, wraps over the corner, and the long end hangs down the other side. Every app gets a different scarf from the collection.

![Four windows, each wearing a different scarf: a lilac mohair check, an oatmeal rib knit, a red fine knit and a cocoa check](docs/hero.png)

## The collection

Eight scarves in three textures, each with its own fringe.

![All eight scarves](docs/colourways.png)

**Brushed mohair** (fuzzy, no visible stitches, long fine fringe)

- **Lilac Check**: lilac, butter and pink
- **Cocoa Check**: cocoa, sky blue and cream
- **Moss Check**: moss, butter and navy
- **Blush**: solid powder pink

**Chunky rib knit** (fat stitches, short tassels)

- **Oat Milk**: heathered oatmeal
- **Camel**: warm camel

**Fine knit** (little V stitches, wispy fringe)

- **Rosehip**: solid soft red
- **Varsity Stripe**: a skinny scarf in navy and cream with a rust thread

**Mixed** (the default) gives each app a different scarf and remembers it. **Shuffle** deals them out again.

Everything is drawn in code. The scarf follows a curved path, its width ripples a little like real fabric, the checks blend where colours cross, and each texture has its own fuzzy halo.

![Close-up of the lilac mohair check](docs/close-up.png)

## Get it

Window Scarves needs macOS 13 or later, and runs on Apple Silicon and Intel Macs.

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

This builds the app, copies **Window Scarves.app** into `~/Applications`, and opens it. Run `./build.sh` without `--install` to build into `build/` only.

## Make yourself cosy

Two shortcuts work anywhere:

- **⌃⌥D** (Control-Option-D) turns the scarves off and on
- **⌃⌥B** (Control-Option-B) turns the sewing buttons off and on

Click 🧣 in the menu bar for the rest:

- **Scarf**: Mixed, Shuffle, or one scarf for every window
- **Long End**: on the right or on the left
- **Thickness**: Slim, Cosy or Chunky
- **Windows**: every window, or only the front one
- **Apps**: untick an app to leave its windows bare
- **Buttons on Window Controls**: see below
- **Keyboard Shortcuts**: turn both shortcuts off if you don't want them
- **Start at Login**: open Window Scarves automatically when you log in

The scarf stays on the window's top edge, so it never covers the red, yellow and green buttons. If there's no room on screen beside a window, the long end moves to the other side, the short end is left off, and as a last resort the long end tucks just inside the window.

### The buttons

Press **⌃⌥B** (or choose **Buttons on Window Controls** in the menu) to turn each window's red, yellow and green buttons into little sewing buttons. They're off until you turn them on. They're only pictures: clicks pass straight through to the real buttons underneath.

This needs Accessibility permission, and the app asks for it the first time you turn the buttons on. Where those buttons sit differs from app to app (16 points in on plain windows, 26 on windows with toolbars, and anywhere at all in apps that draw their own title bars), so the only way to place a sewing button exactly on top is to ask the window, and macOS only allows that with permission. Without it, no sewing buttons are drawn. The scarves never need it. The permission is only used for this.

If you build the app yourself: it's ad-hoc signed, so macOS treats each new build as a different app. After rebuilding, switch Window Scarves off and on again under **System Settings → Privacy & Security → Accessibility**.

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
- Choosing your own keyboard shortcut
- A winter collection

## Credits

Inspired by Sara Gordić's lovely [Window Sweaters](https://github.com/saragordic/window-sweaters), which gives your windows knitted sweaters. Window Scarves is a separate project written from scratch in Swift, and it shares no code with Window Sweaters.

Released under the MIT License. See [LICENSE](LICENSE).
