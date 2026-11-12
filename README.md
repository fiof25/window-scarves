# window-scarves

A little macOS menu-bar app that ties a cosy knitted scarf around each of your windows for autumn. 🧣🍂

Each window gets a knitted band draped across its top edge, a knot at one corner, and two fringed tails hanging down the side. The tails sway gently in an autumn breeze.

![Four windows wearing knitted scarves in maple plaid, forest zigzag, pumpkin spice and harvest fair isle](docs/hero.png)

## The colourways

![All seven colourways](docs/colourways.png)

- **Pumpkin Spice**: pumpkin, cream and cinnamon stripes
- **Maple Plaid**: red and charcoal tartan with a mustard thread
- **Harvest Fair Isle**: rust with cream diamonds and a mustard border
- **Forest Zigzag**: pine green with a cream zigzag and moss edges
- **Cranberry Fleck**: cranberry with cream flecks and rosy stripes
- **Apple Cider Check**: mustard and toffee checks
- **Oatmeal Heather**: soft oat with walnut and cream flecks

**By App** (the default) gives each app its own scarf from the collection, and it stays the same every time.

Every stitch is drawn in code: little V-shaped loops with a touch of heathering, tube shading so the scarf looks puffy, and fringe tied on at the ends.

![Close-up of the maple plaid scarf's stitches and fringe](docs/close-up.png)

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

Click 🧣 in the menu bar:

- **Scarves On**: pause or resume all the scarves
- **Colourway**: By App, or the same scarf on every window
- **Knot**: tie it on the right or the left
- **Thickness**: Slim, Cosy or Chunky
- **Windows**: every window, or only the front one
- **Apps**: untick an app to leave its windows bare
- **Autumn Breeze**: turn the swaying tails on or off

If there isn't room beside a window for the tails, the knot moves to the other side. When a window fills the screen, the tails tuck in along its edge instead.

## How it works

Window Scarves uses only public macOS APIs, and it doesn't need Accessibility or Screen Recording permission.

- `CGWindowListCopyWindowInfo` reports where every window is and how they're stacked.
- Each scarf is its own transparent, click-through window, ordered directly above the window it's wearing. Windows in front still cover it, just like real fabric.
- The app checks every 0.2 seconds, and more often while you drag a window, so scarves follow along.
- Scarf pieces are knitted once into images and cached. The breeze is a Core Animation rotation, so the app idles at well under 1% CPU.

Clicks always pass through to the window underneath.

Render the preview images without touching your real windows:

```sh
"build/Window Scarves.app/Contents/MacOS/WindowScarves" --render docs
```

## Ideas for later

- Falling leaves drifting past the active window
- Choosing a colourway per app
- Mittens on the traffic lights 🧤
- A winter collection

## Credits

Inspired by Sara Gordić's lovely [Window Sweaters](https://github.com/saragordic/window-sweaters), which gives your windows knitted sweaters. Window Scarves is a separate project written from scratch in Swift, and it shares no code with Window Sweaters.

Released under the MIT License. See [LICENSE](LICENSE).
