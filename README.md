# Turn an old iPad or iPhone (iOS 14.8+) into a second display for your Mac (macOS 26), over Lightning or Wi-Fi — free, self-hosted

**Built and running for real** on an iPad mini 4 (iOS 14.8), both over a Lightning cable and over Wi-Fi. H.264 video + touch + two-finger scroll + a real mouse cursor all work reliably.

> Heads-up: the deployment target was raised from 12.0 to **14.8** when the
> SOCKS5 engine moved to hev-socks5-server (its prebuilt static library is
> built with minos 14.8). If you need a true iOS 12 device, stay on the
> commits before that change — the display part itself never needed 14.8.

No cable required: the Mac app auto-discovers the iPad over Bonjour on the
same Wi-Fi network and connects directly. It prefers USB when a cable is
plugged in (lower, steadier latency) and falls back to Wi-Fi automatically
otherwise — you don't have to choose a mode, it just works either way.

## Keywords / What this is

Use an **old iPad on iOS 14.8+** as a **free second display for Mac**
(Apple Silicon or Intel, modern macOS). Open-source alternative to
**Sidecar**, **Duet Display**, and **Luna Display** for devices too old to
run OpenDisplay's own client (which needs iPadOS 17+). Works over
**USB/Lightning** and **Wi-Fi**.

| | This project | Sidecar | Duet Display | Luna Display | OpenDisplay (official client) |
|---|---|---|---|---|---|
| Cost | Free | Free | Free tier + paid | Paid (hardware dongle) | Free |
| Min iOS/iPadOS | **14.8** | 13+ (needs macOS Catalina+ on the Mac side) | 12+ | 12+ | 17+ |
| Open source | iOS client: yes (MIT). Mac app: yes (GPL-3.0, upstream) | No | No | No | Yes (GPL-3.0) |
| Connection | USB/Lightning or Wi-Fi | USB or Wi-Fi | USB or Wi-Fi | USB or Wi-Fi (dongle) | USB or Wi-Fi |
| Needs a companion Mac app you build yourself | Yes | No | No | No | Yes |

## The idea

Skip the paid apps (Duet Display, Luna Display...). Instead:

1. **Mac side**: build and run, unmodified, the open-source
   **[OpenDisplay](https://github.com/peetzweg/opendisplay)** app (GPL-3.0, free).
   It already handles the hard part: creating a virtual display on macOS
   (`CGVirtualDisplay`), capturing it (`ScreenCaptureKit`), hardware-encoding
   H.264 (`VideoToolbox`), and transporting it either over Wi-Fi (discovered
   via Bonjour) or by talking directly to macOS's `usbmuxd` over
   Lightning/USB-C — **no extra tool like `iproxy` needed.**
2. **iPad side**: OpenDisplay requires iPadOS 17+, so it **can't be
   installed on an iPad stuck on iOS 14.8**. That's why the `iOS/` folder in
   this repo is a **purpose-built iOS 14.8 client**: a clean-room reimplementation of
   OpenDisplay's network protocol (read from their public source), so it
   can talk to the unmodified Mac app above without touching it.

Since the Mac side only needs an unmodified build, the only thing you're
actually "writing" yourself is the iPad app — much lighter than
reimplementing the whole pipeline from scratch.

## Repo layout

```
ipad12-second-screen/
  README.md
  LICENSE                 <- MIT, covers iOS/ (code written for this project)
  iOS/                    <- iOS client, original code, MIT
    LegacyPadDisplay.xcodeproj  <- committed and ready to open, no build step
    project.yml           <- xcodegen config (source of truth if you edit the project;
                              re-run `xcodegen generate` after changing it)
    App/
      AppDelegate.swift
      ReceiverViewController.swift  <- fullscreen video view + touch/scroll capture + cursor sprite
      VideoReceiver.swift    <- core: TCP listener, frame deframing, H.264 decode, control message send/recv
      HevSocksProxy.swift    <- in-app SOCKS5 server (hev-socks5-server), started on 127.0.0.1:9001
      AudioKeepAlive.swift   <- silent-audio background keep-alive, gated on charge state
      ControlChannel.swift   <- 9002 control channel: Mac lock-screen sync
    Vendor/
      HevSocks5Server.xcframework  <- prebuilt hev-socks5-server (static lib, minos 14.8)
  Mac/                    <- git submodule, upstream OpenDisplay, UNMODIFIED, GPL-3.0
```

`Mac/` is a **git submodule** pointing straight at the upstream
`peetzweg/opendisplay` repo — nothing copied or edited, so it's clear this
is someone else's code (their GPL-3.0 license stays intact), and it's easy
to `git submodule update --remote` when they cut a new release.

Minimum requirement: **iOS 14.8** (`iOS/project.yml` → `deploymentTarget`),
tested for real on an iPad mini 4 running iOS 14.8.

### Does this work on iPhone too?

Yes, no code changes needed. `TARGETED_DEVICE_FAMILY` is already set to
`"1,2"` (iPhone + iPad), and `VideoReceiver.swift` already reports
`"device": "iPhone"` vs `"iPad"` based on `UIDevice.current.userInterfaceIdiom`
in its `hello` message — this mirrors upstream OpenDisplay itself, which
also targets both (`Mac/project.yml`'s local-network usage description
literally says "connects to your iPad or iPhone"). The Mac side sizes the
virtual display from whatever pixel dimensions the device reports in
`hello`, so it isn't hardcoded to iPad proportions either.

Build/install is the same flow as the iPad steps below — just pick the
iPhone as the destination device in Xcode. If it's also stuck on an old
iOS version, the same DeviceSupport caveat further down applies. The one
real downside: an iPhone screen is a lot smaller, so it's a much less
useful second display in practice than an iPad.

## Step 0 — Clone with submodules

```bash
git clone --recurse-submodules https://github.com/cairy/ipad-iphone-second-monitor-ios12-free.git
cd ipad-iphone-second-monitor-ios12-free
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

## Step 1 — Get the Mac app (OpenDisplay, unmodified)

Two options:

- **Prebuilt (recommended, no Xcode needed)**: grab `OpenDisplay.dmg` from
  the [latest release](https://github.com/peetzweg/opendisplay/releases/latest)
  — signed and notarized by the author. Open it and **drag
  `OpenDisplay.app` into `/Applications` first** — don't run it straight
  out of the mounted `.dmg`. Running it from the disk image works for a
  first test, but the volume unmounts on reboot and takes the app with it,
  and macOS ties the Screen Recording/Accessibility grants to that specific
  app path — moving the app afterward means re-granting both permissions
  again.
- **Build from source**: open `Mac/` in Xcode and run it — see
  [OpenDisplay's own build instructions](https://github.com/peetzweg/opendisplay#readme)
  for details.

Either way, on first launch macOS will ask for **Screen Recording** and
**Accessibility** permissions (System Settings → Privacy & Security) —
grant both, **fully quit the app (Cmd+Q) and relaunch it** (flipping the
toggle isn't enough; the app needs a restart to actually pick up the new
permissions), then run it again.

## Step 2 — Build the iPad app (`iOS/` in this repo)

```bash
open iOS/LegacyPadDisplay.xcodeproj
```

In Xcode:
1. Select target **LegacyPadDisplay** → **Signing & Capabilities** tab →
   set Team to your personal Apple ID.
2. Plug the iPad into the Mac with a Lightning cable, select it as the
   destination device in Xcode's toolbar.
3. Hit Run. On first install, go to **Settings → General → VPN & Device
   Management** on the iPad to "Trust" your developer certificate.

The app should show a fullscreen black screen with "Listening on :9000" at
the bottom — meaning it's waiting for the Mac to connect.

### Xcode says "Failed to prepare the device for development"

Recent Xcode versions don't ship **iOS DeviceSupport** for older iOS builds
anymore (iOS 12/12.5 was the original target of this repo, and this recipe
is kept for anyone who goes back to those commits). You need to add the
matching support folder to
`~/Library/Developer/Xcode/iOS DeviceSupport/`. This repo was actually
brought up using the 12.5 support bundle from
[apptim/iPhoneOSDeviceSupport](https://github.com/apptim/iPhoneOSDeviceSupport):

```bash
curl -L -o /tmp/12.5.zip https://raw.githubusercontent.com/apptim/iPhoneOSDeviceSupport/master/12.5.zip
unzip -o /tmp/12.5.zip -d /tmp/ds125
cp -R "/tmp/ds125/12.5" ~/Library/Developer/Xcode/iOS\ DeviceSupport/
```

It doesn't need to match the exact build number (e.g. 12.5.8/16H88 worked
fine with a plain "12.5" folder) — a close minor version is enough. Other
community repos like
[filsv/iOSDeviceSupport](https://github.com/filsv/iOSDeviceSupport) work
the same way if you need a different version. Copy the folder into place,
fully quit Xcode, reconnect the iPad, and reopen.

### Free Apple ID — the app expires after 7 days

This is an Apple limitation, not something this project can fix. After 7
days, plug the cable back in, open Xcode, and hit Run again to reinstall.
To avoid repeating this, you'd need a paid Apple Developer Program
membership ($99/year) — signs for a full year.

## Step 3 — Connect

1. Make sure both apps are running (Mac app has Screen Recording +
   Accessibility permissions; iPad app is open).
2. Two ways to connect, no mode switch needed on the Mac side — it picks
   automatically:
   - **Cable**: plug the iPad into the Mac over Lightning/USB-C. The Mac
     app recognizes it through `usbmuxd` just like a normal OpenDisplay
     device (same `id`/port 9000 as the original client).
   - **Wi-Fi**: put both devices on the same Wi-Fi network, no cable.
     The Mac app browses for `_opensidecar._tcp` over Bonjour and connects
     directly to the iPad's port 9000. If the iPad asks for **Local Network**
     permission the first time, allow it — Wi-Fi discovery needs it.
   - If both are available at once, the Mac app prefers USB (lower, steadier
     latency) and falls back to Wi-Fi automatically if the cable is pulled.
3. Once connected, the iPad should switch from a black screen to showing
   the macOS desktop (with a real mouse cursor), and a new display should
   appear under System Settings → Displays on the Mac — drag a window over
   to it and you're set.

## Optional — Route Mac traffic through the iPad over USB (SOCKS5 proxy)

The iPad app also runs a small SOCKS5 server (hev-socks5-server, prebuilt as
`iOS/Vendor/HevSocks5Server.xcframework`, started automatically on
`127.0.0.1:9001` when the app launches). Combined with a Mac-side bridge, you
can tunnel Mac traffic through the iPad's Wi-Fi **over the USB cable** — the
tunnel itself needs no Wi-Fi on the Mac side.

Use cases: give the Mac a second egress when it sits on a locked-down /
802.1X network, or run a fully cable-only setup. This is independent of the
display feature and never touches it. Note the iPad still needs its own
internet path, which for a Wi-Fi-only iPad means the same Wi-Fi.

### Run it

The USB bridge now lives in the BarKit repo (it grew a resident thread and
link-probe loop there):

```
barkit/src/barkit/plugins/ipad_tunnel/bridge.py     # --local 1080 --device 9001
```

- `--local 1080` — port the bridge listens on, on your Mac (`127.0.0.1:1080`).
- `--device 9001` — port the SOCKS5 server listens on, inside the iPad app
  (reached through `usbmuxd` over USB).
- `--udid <id>` pins a specific device, `--list` prints connected devices,
  `--wait` keeps retrying until a device appears.

Then point any app (or the macOS system proxy in System Settings → Network →
your interface → Details → Proxies) at `127.0.0.1:1080`. DNS is resolved on
the iPad side, so the Mac's own DNS config is never exposed through the
tunnel.

### How it works

The bridge is pure Python stdlib (no `pip install`). It opens a local
listener, and for each SOCKS5 connection it tunnels the bytes to the iPad
over `usbmuxd` (the same USB multiplexer the display uses), where
hev-socks5-server fulfills the request and sends the reply back the same way.
The iPad app keeps the SOCKS5 server alive across foreground/background
transitions using its own lifecycle and an 8-second watchdog that probes
port 9001 and restarts the engine if iOS ever reclaims the listening socket,
so the display's listener rebuild never kills it.

## If it won't connect — check these first

- **No new virtual display shows up under System Settings → Displays**:
  almost always missing Screen Recording/Accessibility permission for the
  Mac app, or granted but the app wasn't fully quit and relaunched
  afterward (see Step 1).
- Check the Mac app's console log (Xcode → View → Debug Area → Console
  while running the OpenSidecarMac scheme) to see whether it's seeing the
  device over usbmuxd at all.
- If the picture stays black/frozen after switching back from another app,
  give it a second or two — `ensureListening()` reconnects automatically on
  foreground return, which briefly flashes black while the Mac redials.
- If the Mac app sends an `updateRequired`/incompatible-version message —
  a newer OpenDisplay Mac build may have changed the protocol.
  `VideoReceiver.swift` intentionally omits the `pv` (protocol version)
  field, so it's always treated as "protocol 1", which every current
  OpenDisplay Mac release documents as backward-compatible.

## What works / what's missing

Works: video, touch to click/drag, two-finger scroll, **a real mouse
cursor** (position + shape, synced over its own control message, smooth),
**reconnect on foreground return** (the listener/connection can die
silently while backgrounded since no background networking mode is
declared — `ensureListening()` forces a clean reconnect every time the app
comes back, at the cost of a brief flicker).

Missing: an external keyboard, automatic rotation to match the virtual
display, latency measurement.

## License

- `iOS/` (iOS client, min 14.8): MIT, see [LICENSE](LICENSE).
- `iOS/Vendor/HevSocks5Server.xcframework`: prebuilt hev-socks5-server,
  see its own upstream license.
- `Mac/`: submodule pointing at `peetzweg/opendisplay`, GPL-3.0, copyright
  held by its original authors — unmodified, not vendored into this repo.

---

*Keywords: iPad iOS 14 second monitor Mac, old iPad external display,
Sidecar alternative old iPad, Duet Display free alternative, Luna Display
free alternative, OpenDisplay legacy client, Lightning USB second screen,
legacy iPad second monitor, LegacyPadDisplay, SOCKS5 proxy over USB.*
