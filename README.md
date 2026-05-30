# What's My IP — macOS menu bar app + widget

Shows your **public IPv4, IPv6, country, ISP**, and **live network speed** — right in the menu bar, plus a Notification Center / desktop widget.

## Why this is different from a normal speed checker

Most menu bar tools do *one* of these things. Typical network/speed checkers (iStat Menus, NetSpeed, etc.) show only your **local throughput** — bytes per second in and out of your Mac. They tell you nothing about your identity on the internet.

This app combines both:

- **Public network identity** — your **public IPv4 & IPv6**, the **country** that IP geolocates to, and the **ISP / network operator** behind it. A normal speed checker can't show any of this; it only sees local traffic.
- **Live throughput** — current up/down speed, like a speed checker, but distilled to the **one direction that matters right now** so it fits next to the flag without clutter.

So at a glance you see *who you appear to be on the internet* (IP, country, ISP — instantly revealing whether a VPN/proxy is active and where it exits) **and** *how fast you're moving* — something no plain speed meter gives you. It's a network-identity monitor with a speed readout, not a speed meter with nothing else.

## What you see

**Menu bar (always visible):** the country flag + the dominant transfer direction, e.g. `🇸🇬 ↓1.2 MB/s` while downloading, flipping to `🇸🇬 ↑340 KB/s` when upload dominates. Updates live every 2 seconds.

**Click the icon** (which also triggers an immediate IP refresh):

```
My Public IP
  IPv4:        104.28.156.149
  IPv6:        Not available
  Country:     🇸🇬 Singapore
  ISP:         Cloudflare, Inc.
─────────────
Network Speed
  ↓ Download:  1.2 MB/s
  ↑ Upload:    340 KB/s
─────────────
  Updated 11:52
  Quit
```

Click any IP/country/ISP row to copy that value.

**Widget** (small/medium): public IPv4, IPv6, country (+ ISP on medium), with a manual ↻ refresh button. *Live speed is menu-bar-only* — a widget is a periodic static snapshot the OS renders and can't sample a live rate.

## Project layout

```
project.yml                       # xcodegen spec (source of truth for the Xcode project)
Sources/Shared/IPService.swift    # IP / country / ISP fetch — shared by both targets
Sources/App/AppDelegate.swift     # menu bar app (AppKit)
Sources/App/NetSpeedMonitor.swift # live throughput via interface byte counters
Sources/Widget/                   # WidgetKit extension
```

The `.xcodeproj` is generated. After changing `project.yml` **or adding/removing source files**, regenerate:

```sh
xcodegen generate
```

## Run it

**Option A — Xcode (recommended)**

1. `open WhatsMyIP.xcodeproj`
2. Pick the **WhatsMyIP** scheme (not `IPWidgetExtension`) → Run (⌘R). The flag + speed appears in the menu bar.
3. Add the widget: right-click the desktop (or open Notification Center) → **Edit Widgets** → search **My IP** → drag it in.

If signing complains, select the **WhatsMyIP** target → Signing & Capabilities → pick your Team (a free personal Apple ID works for "Sign to run locally"). Do the same for the **IPWidgetExtension** target.

**Option B — command line**

```sh
./build.sh        # ad-hoc-signed build into ./build
open build/Build/Products/Debug/WhatsMyIP.app
```

## Releasing a signed build

`release.sh` builds a Release version, signs it with **Developer ID** + hardened
runtime, packages a `.dmg`, **notarizes** it with Apple, staples the ticket, and
cuts a GitHub Release with the DMG attached:

```sh
./release.sh 1.0.0
```

Prerequisites (one-time, on the signing machine):

- A **Developer ID Application** certificate in your login keychain.
- A stored `notarytool` keychain profile:
  ```sh
  xcrun notarytool store-credentials notarytool \
    --apple-id "you@example.com" --team-id "YOURTEAMID"
  ```
  (the app-specific password comes from appleid.apple.com → App-Specific Passwords)
- If codesign fails with `errSecInternalComponent`, authorize the key for
  command-line tools once:
  ```sh
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "<login-password>" ~/Library/Keychains/login.keychain-db
  ```

> The `IDENTITY` and team ID near the top of `release.sh` are specific to the
> original author — edit them to your own before running.

## Refresh behaviour

- **Menu bar IP/country/ISP:** auto every 2 min, **and on every menu open** (opening = "show me fresh data now").
- **Menu bar speed:** sampled every 2 s.
- **Widget:** manual ↻ button; auto-refresh requested at ~15 min because **macOS throttles widget updates against a daily system budget** — it won't honor a true 2-minute cadence. The app also nudges the widget to reload whenever it refetches.

## Data sources

- **IPv4 + country + ISP:** one request to `ipapi.co` → falls back to `ipwho.is` → `ifconfig.co` (IPv4 and country/ISP come from a single call).
- **IPv6:** `ipv6.icanhazip.com` → `6.ident.me` → `ipv6.seeip.org` → `api6.ipify.org`.
- **Speed:** the OS per-interface byte counters (`getifaddrs`, same source as `netstat -ib`).

> **Note on accuracy:** IP geolocation reports where the *IP* lives, which for a VPN/proxy is the **exit node**, not your physical location. "IPv6: Not available" means your network has no public IPv6 route — normal on many connections. Speed is **machine-wide**, not per-app.

## Requirements

macOS 14+, Xcode 16+. Project generated with [`xcodegen`](https://github.com/yonaskolb/XcodeGen).
