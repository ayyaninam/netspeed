# NetSpeed

A speedtest.net-style internet speed test that lives in your macOS menu bar. One click, a live gauge, and honest numbers — including the ones speed tests usually hide (bufferbloat, loaded latency, packet loss) plus plain-English verdicts like *"video meetings: choppy when line is busy."*

**Native SwiftUI · one Swift file · no Electron, no frameworks, no telemetry · powered by the official Ookla® Speedtest® CLI**

![Platform](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

```
   menu bar, always on:   ↓1.2M ▂▄▆█  27
                          ↑340K ▂▄        ms

        ┌────────────────────────────────┐
        │   DOWNLOAD ↓        UPLOAD ↑   │
        │   142.5 Mbps        38.1 Mbps  │
        │                                │
        │        ╭─── ⌁ gauge ───╮       │
        │      0╱   needle sweeps  ╲1000 │
        │      │   with live data   │    │
        │      │      ( GO )        │    │
        │                                │
        │ ┌ LIVE ─────────── Wi-Fi (en0)┐│
        │ │   ↓ 53 KB/s  │  ↑ 18 KB/s  ││
        │ │ gw 1.6 ms · net 27 ms ·     ││
        │ │ today ↓54 MB ↑78 MB         ││
        │ └─────────────────────────────┘│
        │ ┌ LAST TEST ────────── 3 hr ago┐│
        │ │  PING    LOADED  BUFFERBLOAT││
        │ │  15.1 ms 26.6 ms +11.5 ms A ││
        │ │ jitter 3.0 ms · loss 0% · … ││
        │ │ ─────────────────────────── ││
        │ │ Video meetings    ● smooth  ││
        │ │ 4K streaming      ● smooth  ││
        │ │ Gaming            ● low ping││
        │ └─────────────────────────────┘│
        └────────────────────────────────┘
```

## Features

- **Live speedometer gauge** — log-scale (0–1000 Mbps) needle driven by ~9 real measurements per second streamed from the Ookla CLI. The needle shows actual throughput, not an animation.
- **True speedtest.net flow** — ping → download → upload phases, with the live ping shown on the dial during the ping phase.
- **Menu bar live ticker** — the icon becomes `↓142` / `↑38` while a test runs, so you can close the popover and watch from the corner of your eye.
- **Latency under load** — idle ping, loaded latency (Ookla's `iqm` during saturation, worst direction), and a **bufferbloat grade (A+ to F)** on the Waveform scale. This is the number that explains why calls freeze while something downloads.
- **Real-world verdicts** — video meetings, 4K streaming, HD streaming, gaming, and browsing each get a green/yellow/red dot with a one-phrase reason, computed from your measured bandwidth, ping, loaded latency, and packet loss.
- **The details** — jitter, packet loss, test server, and a shareable speedtest.net result link (gear menu).
- **Always-on live monitor in the menu bar** — your Mac's actual ↓/↑ throughput stacked in two tiny rows, each with a colored 4-bar utilization meter, plus internet ping in a small side column. Speeds update every second, ping every 5 s. Three display modes in the gear menu (speeds + ping / speeds only / icon only).
- **The bars mean something** — they show how full your pipe is relative to *your measured line speed* (last test): cyan/purple while normal, **amber past 60%, red when saturated**. Ink flips automatically for light/dark menu bars.
- **LIVE card in the popover** — current rates, gateway ping vs internet ping, network name + interface, today's data totals, and the top 3 apps using the connection right now. Test results live in their own LAST TEST card below it.
- **CSV logs that answer "when was it bad and why"** — one row every 10 s: throughput, both pings, network name, interface, top app. Gear → "Open logs folder".
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

## Live monitor & logs

The monitor is deliberately boring: a 1-second byte-counter poll (`getifaddrs` syscall — no subprocess), pings every 5 seconds, one CSV row every 10 seconds, and per-app sampling (`nettop`) only while the line is actually busy. Idle CPU rounds to zero.

Logs live in `~/Library/Application Support/NetSpeed/netlog-YYYY-MM-DD.csv`, one file per day, auto-pruned after 14 days (~1 MB/day):

```csv
time,down_Bps,up_Bps,ping_gw_ms,ping_inet_ms,network,iface,top_app
2026-08-13 22:35:05,1121346,38402,1.2,27.1,USB 10/100/1000 LAN 2,en8,Google Chrome
```

Reading a bad moment out of the log:

| Pattern | Diagnosis |
|---|---|
| `ping_gw` high | Your Wi-Fi / local hop is the problem |
| `ping_gw` fine, `ping_inet` high | Your ISP or the path beyond the router |
| Both fine but slow | Check `top_app` — something was eating the line |
| `network` column changed | You were on a different network when it happened |

Implementation notes: interface byte counters are 32-bit on macOS, so deltas use wrap-safe math; the primary interface, its human name, and the gateway IP come from SystemConfiguration (no shelling out); per-app rates are deltas of `nettop -P -x` cumulative counters between samples. The menu bar item is a small NSImage redrawn each tick (stacked 8.5 pt rows + bar meter) because multi-line SwiftUI labels are unreliable in `MenuBarExtra`; it reads the effective appearance at render time so text stays legible on light and dark menu bars.

## Why there's no "fix bufferbloat" button

An earlier version shipped a single-Mac traffic-shaping toggle (`dummynet` + `pf`, 90% caps, short queues — the host-side version of router SQM). We then A/B/A-tested it properly: ~2,600 latency samples across idle / download-saturated / upload-saturated scenarios, shield off → on → off, plus localhost-throughput and restore checks. It lost:

| Measured (saturated line, ping to nearest server) | Shield off | Shield on |
|---|---|---|
| p95 latency | 25.2 ms | 22.6 ms |
| p99 latency | 29.5 ms | 23.8 ms |
| Download throughput | 16.0 Mbit/s | 10.1 Mbit/s (**−37%**) |
| Upload throughput | 19.0 Mbit/s | 15.4 Mbit/s (−19%) |

Two structural reasons, beyond one test line:

1. **macOS `dummynet` is droptail-only.** There is no `sched` command on macOS — no fq_codel, no CAKE, no flow queuing. A droptail FIFO short queue controls latency by dropping, which taxes long-RTT TCP flows far harder than the ~10% a real SQM costs.
2. **On a well-managed line there's nothing to win.** This line added only ~4 ms at p95 under full saturation *without* any shaping. If your line grades A on its own, host-side shaping can only subtract bandwidth.

So: NetSpeed *measures* bufferbloat honestly and leaves fixing it where it actually works — the router (OpenWrt/CAKE, MikroTik, Ubiquiti Smart Queues), or capping the bulk apps themselves. If your grade is C or worse, that's the path.

## Uninstall

```sh
rm -rf /Applications/NetSpeed.app
rm -rf ~/Library/Application\ Support/NetSpeed        # monitor logs
rm -f ~/Library/Preferences/com.ayyan.netspeed.plist  # preferences
```

If you enabled Launch at Login, macOS removes the login item with the app.

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
