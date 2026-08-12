# NetSpeed

A speedtest.net-style internet speed test that lives in your macOS menu bar. One click, a live gauge, and honest numbers — including the ones speed tests usually hide (bufferbloat, loaded latency, packet loss) plus plain-English verdicts like *"video meetings: choppy when line is busy."*

**Native SwiftUI · one Swift file · no Electron, no frameworks, no telemetry · powered by the official Ookla® Speedtest® CLI**

![Platform](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

```
        ┌────────────────────────────────┐
        │   DOWNLOAD ↓        UPLOAD ↑   │
        │   142.5 Mbps        38.1 Mbps  │
        │                                │
        │        ╭─── ⌁ gauge ───╮       │
        │      0╱   needle sweeps  ╲1000 │
        │      │   with live data   │    │
        │      │      ( GO )        │    │
        │        Last test 2 min ago     │
        │                                │
        │   PING     LOADED   BUFFERBLOAT│
        │   15.1 ms  26.6 ms  +11.5 ms A │
        │   jitter 3.0 ms · loss 0% · …  │
        │                                │
        │   Video meetings    ● smooth   │
        │   4K streaming      ● smooth   │
        │   HD streaming      ● smooth   │
        │   Gaming            ● low ping │
        │   Browsing          ● snappy   │
        └────────────────────────────────┘
```

## Features

- **Live speedometer gauge** — log-scale (0–1000 Mbps) needle driven by ~9 real measurements per second streamed from the Ookla CLI. The needle shows actual throughput, not an animation.
- **True speedtest.net flow** — ping → download → upload phases, with the live ping shown on the dial during the ping phase.
- **Menu bar live ticker** — the icon becomes `↓142` / `↑38` while a test runs, so you can close the popover and watch from the corner of your eye.
- **Latency under load** — idle ping, loaded latency (Ookla's `iqm` during saturation, worst direction), and a **bufferbloat grade (A+ to F)** on the Waveform scale. This is the number that explains why calls freeze while something downloads.
- **Real-world verdicts** — video meetings, 4K streaming, HD streaming, gaming, and browsing each get a green/yellow/red dot with a one-phrase reason, computed from your measured bandwidth, ping, loaded latency, and packet loss.
- **The details** — jitter, packet loss, test server, and a shareable speedtest.net result link (gear menu).
- **Menu bar citizen** — no Dock icon, last result persists across restarts, optional Launch at Login, Stop button mid-test.
- **Self-archiving** — the installed app embeds its own source code (`NetSpeed.app/Contents/Resources/`), so any installed copy can rebuild itself.

## Install

**One-liner** (builds from source on your machine, ~30 seconds):

```sh
curl -fsSL https://raw.githubusercontent.com/ayyaninam/netspeed/main/install.sh | bash
```

**Or manually:**

```sh
git clone https://github.com/ayyaninam/netspeed.git
cd netspeed
./build.sh
cp -R build/NetSpeed.app /Applications/
open /Applications/NetSpeed.app
```

Then click the speedometer icon in the menu bar and hit **GO**.

### Requirements

| | |
|---|---|
| macOS | 13 Ventura or newer (uses SwiftUI `MenuBarExtra`) |
| Xcode Command Line Tools | `xcode-select --install` (for `swiftc`) |
| Architecture | Builds natively for your machine — Apple Silicon and Intel both fine |

### Why is there no prebuilt download?

Two reasons, both real:

1. **Ookla's license doesn't allow redistributing their CLI binary**, so a prebuilt app containing it can't be shipped here. `build.sh` downloads the engine straight from Ookla's servers onto your machine instead. By building you accept [Ookla's EULA](https://www.speedtest.net/about/eula).
2. An unsigned prebuilt app downloaded from GitHub would be blocked by Gatekeeper anyway. Building locally produces a locally-signed app that just runs.

## How it works

```
MenuBarExtra (SwiftUI, one file)
   └─ Process → Contents/Resources/speedtest --accept-license --accept-gdpr -f jsonl
        └─ JSONL stream, parsed line-by-line on a background reader:
             {"type":"ping",     "ping":{"latency":13.5,"jitter":0.4,…}}      → live ping on the dial
             {"type":"download", "download":{"bandwidth":2350649,…}}          → needle (bytes/s × 8 ÷ 1e6 = Mbps)
             {"type":"upload",   "upload":{"bandwidth":…}}                    → needle, purple phase
             {"type":"result",   …}                                           → final numbers + analysis
```

The final `result` event carries everything the analysis needs:

| Field | Used for |
|---|---|
| `ping.latency`, `ping.jitter` | PING stat, jitter caption |
| `download.bandwidth`, `upload.bandwidth` | headline Mbps (bytes/sec, converted) |
| `download.latency.iqm`, `upload.latency.iqm` | **loaded latency** — RTT while that direction is saturated |
| `packetLoss` | verdicts for meetings/gaming |
| `server.name`, `server.location` | caption |
| `result.url` | "Open last result on speedtest.net" |

**Bufferbloat** = worst-direction loaded latency − idle ping, graded on the [Waveform](https://www.waveform.com/tools/bufferbloat) scale:

| Added latency | < 5 ms | < 30 ms | < 60 ms | < 200 ms | < 400 ms | ≥ 400 ms |
|---|---|---|---|---|---|---|
| Grade | A+ | A | B | C | D | F |

**Activity verdicts** are computed from measured numbers against public vendor guidance (Zoom group-HD ≈ 4 Mbps each way; Netflix 4K = 15 Mbps, HD = 5 Mbps; gaming wants < 60 ms ping). Loaded latency decides the "…when line is busy" downgrades; packet loss hits realtime traffic (meetings, gaming) first. All thresholds live in one function — `activities(for:)` in `Sources/main.swift` — tune them to taste.

## Ping here vs. Apple's `networkquality` — why they disagree

Run Apple's built-in `networkquality` and you may see an "idle latency" 20–50× higher than the ping NetSpeed shows. Both are correct; they answer different questions:

| | NetSpeed (Ookla) | Apple `networkquality` |
|---|---|---|
| Target | Nearest test server (often your own city, peered with your ISP) | Apple's CDN — possibly on another continent |
| Math | Ping to one nearby host | *Mean* of ~24 TCP/TLS/HTTP probes — a few congestion spikes drag the average way up |
| Answers | "How good is my line?" | "How do far-away servers feel through my line?" |

NetSpeed reports the speedtest.net-style number because that's what isolates *your line and ISP* from the rest of the internet.

## Uninstall

```sh
rm -rf /Applications/NetSpeed.app
```

If you enabled Launch at Login, macOS removes the login item with the app. Preferences (last result) live in `~/Library/Preferences/com.ayyan.netspeed.plist` if you want a truly clean sweep.

## Development

| File | What it is |
|---|---|
| `Sources/main.swift` | The entire app (~700 lines): engine process management, JSONL parser, gauge, analysis, UI |
| `build.sh` | Fetches the Ookla engine (first run only), compiles, assembles + signs `build/NetSpeed.app` |
| `install.sh` | The curl-able installer: checks toolchain, builds, installs to `/Applications` |
| `Info.plist` | `LSUIElement` menu-bar-only app manifest |

Iterate with `./build.sh && pkill -x NetSpeed; cp -R build/NetSpeed.app /Applications/ && open /Applications/NetSpeed.app`.

To bump the engine, edit `ENGINE_VERSION` in `build.sh` and delete the cached `speedtest` binary.

## License

Code: [MIT](LICENSE) © Ayyan Inam.

The Ookla Speedtest CLI is downloaded separately at build time and remains under [Ookla's own terms](https://www.speedtest.net/about/eula). Speedtest® is a registered trademark of Ookla, LLC. This project is not affiliated with, sponsored by, or endorsed by Ookla.
