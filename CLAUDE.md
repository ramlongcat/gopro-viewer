# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

GoProViewer — a SwiftUI/AppKit macOS app that browses, previews and copies media off a GoPro over its USB network link, using the [Open GoPro](https://gopro.github.io/OpenGoPro/) wired HTTP API. SwiftPM package (`GoProOffload`), no Xcode project, no dependencies.

**The camera is strictly read-only.** There is deliberately no delete code anywhere in the app. Don't add any.

## Commands

```bash
swift build                 # fast compile check while iterating
./build.sh --open           # release build → dist/GoProViewer.app, then launch it
./build.sh --zip            # also produce dist/GoProViewer.app.zip (release asset)
```

`build.sh` stamps the bundle version from the `VERSION` file, compiles `tools/usb_launcher.c` into the bundle, and ad-hoc signs. There is no test target and no linter.

To restart the running app after a change:

```bash
pkill -x GoProOffload; ./build.sh --open
```

The process name is the binary, `GoProOffload`, not the bundle name `GoProViewer`.

### Developing without a camera

```bash
python3 tools/gopro_emulator.py --library ~/Movies/GoPro
```

Serves the Open GoPro endpoints the app uses on `127.0.0.1:8080` (Python 3, stdlib only; thumbnails via `sips`/`qlmanage`). The app auto-discovers it within seconds — no settings needed; a real camera always wins, and localhost is only trusted if it answers the version endpoint with valid JSON. Flags: `--throttle` MB/s and `--latency` ms simulate a slow USB link, `--fake N` adds items that are never at the destination, `--battery`, `--quiet`.

When adding a feature that reads a new camera field or endpoint, teach the emulator to serve it too — otherwise that path is untestable without hardware.

### Diagnostics

- `~/Library/Logs/GoProOffload.log` — connection and transfer log (`AppLog.log`).
- `~/Library/Caches/GoProOffload/thumbs/` — thumbnail disk cache.
- The camera answers plain HTTP, so `curl http://172.2x.x.51:8080/gopro/media/list` is often the fastest way to check what it actually reports.

## Release discipline

Every user-facing change bumps `VERSION` (semver), mirrors it in the README's `Version **x.y.z**` header, and updates the README `## Changelog`.

The changelog is **release notes for users, not a work log**: each version has a `**New**` and/or `**Fixed**` section, plain language, no class or framework names. One entry per released feature — while iterating within a session, amend the current version's entry rather than minting a version per round, and never add an entry for a revert or an experiment.

## Architecture

### Connection lifecycle

`AppModel` (`AppModel.swift`) is the single `ObservableObject` store: connection state, camera info/status, the media list, selection, viewer target, and the downloaded-file index. It owns discovery — enumerate interfaces, derive candidate IPs (`172.2x.x.51`), probe them plus a manual override and localhost, then `connect()`. A keep-alive ping doubles as liveness detection, so unplugging (or quitting the emulator) disconnects the app. `GoProClient` is created per connection and vends every HTTP call; `client.cacheKey` (the camera serial once known) namespaces the thumbnail cache.

### Media model

The camera returns a flat file list. `Models.swift` folds it into `MediaEntry` values, which is what the whole UI works with: chapters of one clip (`GX01…`, `GX02…`) become a single `.video` entry, bursts/time-lapses become `.photoGroup`, and each entry knows its proxy (`.LRV`) path, RAW sibling and total size. Anything that needs "the files behind this item" goes through `MediaEntry`, never the raw list.

`ThumbnailLoader` caches to memory + disk and gates concurrent camera requests. It also trims letterbox padding off decoded video thumbnails: firmware renders the frame into a fixed box and pads the rest with black, and the grid's fill-crop would keep those bars. The trim is deliberately conservative (near-black, symmetric borders only) — don't remove it thinking the bars come from the layout.

`MediaInfoLite` is the per-item detail (duration, w/h, fps, EIS, HiLights) fetched lazily by `fetchInfo` and cached on disk; `mediaInfoRaw` returns the camera's full JSON for the inspector.

Field names in `/gopro/media/info` are undocumented in GoPro's HTTP spec but fully named in their own Kotlin SDK (`wsdk/.../entity/operation/Media.kt` in the OpenGoPro repo) — that is the reference `MediaDetailView`'s label table follows.

### Two windows

The browser is the SwiftUI `WindowGroup` (`ContentView` → sidebar + `MediaBrowserView` grid + trailing `.inspector` column holding `MediaDetailView`).

The viewer is **not** a sheet: `ViewerWindowController` (`ViewerWindow.swift`) hosts `ViewerView` in its own borderless `NSWindow`. Two AppKit constraints drove that and both still hold — a window with a sheet attached refuses to enter full screen, and only a real window can be sized to the media's aspect ratio. The controller owns the window, its full-screen state, the idle-pointer timer that fades the floating controls, and `fit(aspect:)`, which sets the content size and locks `contentAspectRatio` so nothing letterboxes. `ContentView` opens and closes it by observing `model.viewer`.

`ViewerView` must keep `.ignoresSafeArea()`: the window hides its titlebar but SwiftUI still insets for it, which reintroduces bars inside an exactly-fitted window.

Keyboard in that window runs on `.keyboardShortcut`, not `.onKeyPress` — nothing in an `NSHostingView` holds SwiftUI focus reliably, so shortcuts with no visible control (←/→ seeking, `,`/`.` navigation) hang off zero-size hidden buttons. Shortcuts match modifiers exactly, so a shifted variant (`<`, `>`) needs its own button.

### Playback quality split

Grid hover previews play the camera's low-res `.LRV` proxy (`HoverPlayback` in `MediaBrowserView.swift`, driven by a tracking area — see below). The viewer always streams the full-quality file. Transfers are unaffected; `.LRV`/`.THM` are only copied when Settings says to include proxies.

`VideoPane` uses an `AVQueuePlayer` over `AVPlayerView` with `controlsStyle = .none`, because AVKit's scrub bar cannot carry the HiLight marks. SwiftUI's `VideoPlayer` is off-limits: it fails to resolve `AVPlayerView` metadata at runtime in this SwiftPM build and aborts the process.

### Mouse handling in the grid

Each cell is overlaid by `ClickCatcher`, an `NSViewRepresentable`. Because it sits on top, AppKit resolves clicks, cursor, tooltips **and hover** against it — SwiftUI's `.onHover` and `.help()` underneath are unreliable and were the cause of a silent hover-play failure. Route new per-cell mouse behaviour through `ClickCatcher`, not through SwiftUI modifiers on the cell.

**Never derive grid behaviour from NSView frame geometry.** SwiftUI's scrolling does not keep the overlay NSViews' frames current: after a scroll, `convert`/`visibleRect` math once showed 25 cells all "containing" the pointer, and tracking areas (which AppKit computes from those frames) strew phantom enter events across cells during every scroll. The only truthful accounts of a scrolled layout are a window **hit-test** (`contentView.hitTest`, which routes through SwiftUI's own geometry — clicks work for the same reason) and SwiftUI's `onGeometryChange`. This is why hover previews stop via a scroll-wheel event monitor plus settle-time hit-test reconciliation in `ClickCatcher`, not via geometry checks — see `settleMonitor`.

### Transfers

`TransferManager` runs one sequential queue, publishing progress/speed for the sidebar, over `Downloader` — a delegate-based `URLSession` client (not `URLSession.bytes`) so per-chunk progress stays cheap, writing to a `.part` file and re-requesting with a `Range` header to resume, falling back to a restart if the camera ignores the header. It enables GoPro *turbo transfer* for batches (which makes the camera unresponsive to everything else — `ThumbnailLoader` and hover previews deliberately stand down while `transfers.isActive`), resumes interrupted files by HTTP range, writes per-day folders, restores capture timestamps, and suffixes `(2)` when GoPro's recycled filenames collide. `AppModel.rebuildDestIndex` scans the destination by name+size so already-copied items show a check and can be excluded.

### Auto-launch agent

`AutoLaunch` writes a per-user LaunchAgent that runs `GoProUSBLauncher` (from `tools/usb_launcher.c`, built into the bundle) when a GoPro USB device attaches. The plist is rewritten on every launch while the setting is on, so it follows the bundle — meaning a dev build points the agent at `dist/GoProViewer.app`. Worth knowing when the app seems to open itself from an unexpected place.

### Telemetry

`GPMF.swift` is a hand-rolled parser for the GPMF track (`/gopro/media/gpmf`), extracting the GPS track that `MediaDetailView` draws on a MapKit map.

## Conventions

- Comments explain *why*, especially where a choice looks odd — several workarounds exist because the obvious API is broken (see the AVKit and sheet/full-screen notes above). Match that density; don't narrate what the code already says.
- Tahoe-only polish goes behind `if #available(macOS 26.0, *)` with a material fallback (`glassEffect` → `.ultraThinMaterial`). Deployment target is macOS 14.
- Camera timestamps carry no timezone, so all display formatting uses UTC (`Fmt` in `Support.swift`) to show what the camera clock showed.
- Numbers from the camera arrive as strings on some firmware and bare numbers on others — decode through `FlexInt`.
- Settings are read two ways from the same `UserDefaults` keys: `Prefs.x` statics for non-View code, `@AppStorage(Prefs.kX)` inside views. Add the key to `Prefs` (and to `register()` if it needs a non-zero default) rather than writing a bare string in a view.
- Grid cells keep the thumbnail in an `.overlay`, never as a layout child: an image of an unexpected shape (8:7 stills, vertical video) would otherwise inflate the cell and overlap its neighbours.
