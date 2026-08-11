# GoProViewer

Native Apple Silicon macOS app to browse, preview, and transfer media from a GoPro over USB — no Quik, no MTP. Talks to the camera's built-in HTTP server via the Open GoPro wired API. Built and tested with a HERO13 Black, but nothing in it is model-specific: any camera that speaks Open GoPro over USB should work — HERO10 Black and everything after (HERO11 Black / Mini, HERO12, HERO13, MAX 2, …).

## Features

- **The app never deletes anything from the camera.** There is deliberately no delete code at all — the camera is treated as strictly read-only.
- Thumbnail grid grouped by capture day; filters for videos/photos. Chaptered videos and burst/time-lapse groups appear as single items.
- Finder-style selection: click selects one item, **⌘-click** toggles, **⇧-click** extends the range, the corner circle toggles without clearing, ⌘⇧A selects everything visible.
- Double-click to preview. Photos load instantly (camera's preview JPEG, with full-res on demand) and **zoom with trackpad pinch** or ⌘+ / ⌘− / ⌘0, panning by scroll. Videos **stream straight off the camera** without downloading — low-res proxy by default, full quality a click away; chaptered videos play through in sequence, with arrow keys free for seeking. **`<` / `>`** (or `,` / `.`) move between items with a slide animation.
- Select → Download: sequential queue with progress + speed, HTTP-range resume of interrupted files, GoPro *turbo transfer* mode for batches, per-day destination folders, original capture timestamps, already-downloaded detection (green check), and `(2)` suffixing when GoPro's recycled filenames collide.
- Optional per Settings: include `.GPR` raws, include `.LRV`/`.THM` proxies, and the day-folder naming pattern (`YYYYMMDD` by default; try `YYYY-MM-DD`, or `YYYY/MM/DD` to nest).
- Live battery / SD-card status in the sidebar; distinguishes "camera asleep" from "not plugged in".
- Displayed times are the camera's own clock (GoPro timestamps carry no timezone).
- If discovery fails, set a manual IP in Settings — also works over Wi-Fi/COHN if the camera is reachable on your LAN. (HERO9 Black's USB mode is older RNDIS networking, which macOS doesn't support natively — use the Wi-Fi route for that one.)
- Thumbnails cache in `~/Library/Caches/GoProOffload/`; transfer activity is logged to `~/Library/Logs/GoProOffload.log`.
- Default destination is `~/Movies/GoPro` (changeable in the sidebar or Settings).

## How to connect your GoPro ?

1. Plug the camera into the Mac with USB-C.
2. On the camera (only once): swipe down → **Preferences → Connections → USB Connection → GoPro Connect** (not MTP).
3. Wake the camera (tap any button). macOS brings up a network interface named after the camera (e.g. "HERO13 Black") and the app finds the camera automatically at `172.2x.x.51`.

## How to install ?

Apple Silicon, macOS 14+. Paste this in Terminal — it downloads the [latest release](https://github.com/ramlongcat/gopro-viewer/releases/latest), installs it to `/Applications`, and launches it:

```
curl -fsSL https://raw.githubusercontent.com/ramlongcat/gopro-viewer/main/install.sh | bash
```

First launch triggers macOS's **Local Network** permission prompt — allow it; that's the USB link to the camera.

## Advanced

### Manual install

Prefer installing it by hand? Grab `GoProViewer.app.zip` from the [latest release](https://github.com/ramlongcat/gopro-viewer/releases/latest), unzip, drop `GoProViewer.app` into `/Applications`, then clear the quarantine flag (the app is ad-hoc signed — macOS would otherwise report it as "damaged"):

```
xattr -dr com.apple.quarantine /Applications/GoProViewer.app
```

### Build & run from source

```
./build.sh --open
```

Builds with the system Swift toolchain and produces `dist/GoProViewer.app` (ad-hoc signed). The same **Local Network** prompt applies on first launch.
