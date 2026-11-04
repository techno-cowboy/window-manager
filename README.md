<img src="assets/icon.svg" width="64" height="64" alt="">

# Window Manager

Version 0.2.0

A small macOS menu bar app: you decide which app goes on which display. As soon as monitors are connected (including via DisplayLink docks), it moves the windows there automatically.

Requires macOS 15 or later.

## Download

Grab the latest `Window-Manager-*.zip` from [Releases](https://github.com/techno-cowboy/window-manager/releases), unzip it and move **Window Manager.app** to `/Applications`.

The app is not notarized, so macOS blocks it on first launch. Either right-click it → **Open**, or remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine "/Applications/Window Manager.app"
```

## Build & install

```sh
./build.sh install     # builds, copies to /Applications and launches
swift test             # unit tests (window matching, data format)
```

On first launch macOS asks for **Accessibility** access (System Settings → Privacy & Security → Accessibility). The app needs it to move windows.

> Without a developer certificate the app is signed ad hoc, so macOS asks for the permission again after every rebuild. A stable certificate avoids that:
> `CODESIGN_IDENTITY="Apple Development: Your Name (XXXX)" ./build.sh install`

## Usage

1. Arrange your windows the way you want them.
2. Menu bar → **Save Current Arrangement → As New Layout…** → enter a name (e.g. "Office", "Meeting").
3. Repeat for other setups. Each layout remembers, per app, the display and the exact window position.
4. In **Settings…**, give your displays names (**Identify** shows which one is which) and adjust the placement per app: saved position, keep position, maximize, left/right half, center.
5. Turn on **Launch at login**.

To apply a layout, click it in the menu bar or press **⌃⌥⌘1 … 9** (in the order shown in Settings). The most recently applied layout is the *active* one. It is applied automatically when displays are connected, the Mac wakes up, or an app launches. **⌃⌥⌘W** applies it again.

### Multiple windows of one app (e.g. two browser windows)

Every window is saved separately, with its own display and position, and shows up as its own row below the app in Settings. When a layout is applied, each window is recognized by:

1. its macOS **window number**. It stays the same as long as the window is open, including when you undock and redock.
2. **Title contains…**, if you filled it in (e.g. "sellerboard"). Useful after restarting the browser, because window numbers change then.
3. the **same title** as when the layout was saved.
4. otherwise, the **window order**.

When a window is found through 2–4, the app remembers its new number. Extra windows that aren't part of the layout go to the app's main display.

### Updating a layout

Saving under the name of an existing layout (or choosing **Save Current Arrangement → Into “…”**) overwrites it: for every open app, displays, window positions and placement ("saved position") are replaced. Only on/off and the "Title contains" filters are kept. Apps that aren't running stay in the layout.

### Apps that aren't running

Apps that aren't running are skipped when a layout is applied; Window Manager doesn't launch them. If such an app is started later and auto-apply is on, the active layout is applied to it 1, 3 and 6 seconds after launch.

## How it works

- Displays are identified by **vendor, model and serial number**, not by the display ID, which DisplayLink assigns anew on every reconnect. That keeps three identical monitors apart.
- After a display change the app waits for a configurable delay (default 3 s), because DisplayLink monitors come up step by step and macOS moves windows around on its own afterwards.
- Windows are moved through the Accessibility API (`AXUIElement`). The window number comes from the private but long-stable function `_AXUIElementGetWindow`, which Rectangle, yabai and others use as well. Minimized windows, full-screen windows and windows on other Spaces are ignored.

## License

[MIT](LICENSE) © 2026 Nils Rosemann
