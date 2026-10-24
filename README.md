# OpenDente

Battery charge limiter for macOS. Menu bar app - pick a target level (e.g. 80%), the system stops charging when it gets there.

Open-source alternative to AlDente, GPL-3 licensed. Built to stay out of the way: 2-second SMC poll, no animated UI in the background, no telemetry.

## Status

Beta. Tested on two Macs so far: an M4 MacBook on macOS Tahoe (26), and an M1 Max MacBook Pro on macOS Sequoia 15.8.1. Everything else is unverified. If you run it on something else, a [hardware report](../../issues/new?template=hardware-report.yml) would be very welcome.

### Which macOS versions need which mode

Recent macOS updates changed which SMC keys exist, so OpenDente was adapted to fall back when the classic charging keys are gone:

| macOS | Charging keys | OpenDente's mode |
|---|---|---|
| 14 – 15.7, 26 – 26.6 | `CH0B`/`CH0C` or `CHTE` | Legacy or Tahoe: gates charging directly |
| 15.8, 26.7 | Classic keys removed with the firmware update; charge-range keys `bfD0/bfE0/bfF0` still present | Firmware range if they can be written, otherwise adapter cut |
| 27 (beta 4+) | Both sets locked behind a private Apple entitlement; only the adapter key is left | Adapter cut: the Mac runs on battery while charging is held |

The key removal comes with the firmware in those updates, not with Apple's own charge limit (that arrived in 26.4, and 15.8 doesn't have it). These versions come from reports by other battery tools, not from Apple; details and sources are in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md#macos-versions-and-smc-keys).

The app writes to the SMC. It tries to fail safe (charging is restored on quit, on helper crash, and via watchdog), but you use it at your own risk. No warranty.

## Compared to AlDente

Core charging features overlap with what AlDente puts behind its Pro tier: charge limit, sailing mode, heat protection, force discharge, MagSafe LED control, sleep handling.

What's different here:

- Open source, GPL-3. No Pro tier, no paywalled features.
- No telemetry, no analytics, no auto-update server. The app talks to your battery and nothing else.
- Fixed 2-second polling and no animated power-flow visualization - AlDente's drain on the battery itself was the original motivation to write this.
- Smaller in scope. No calibration mode, no auto-update, English-only UI, no fancy onboarding.

## Apple's native charge limit (macOS 26.4)

In macOS 26.4, Apple shipped their own charge limit in System Settings → Battery (80% up to 100% in 5% steps). OpenDente works fine alongside it, system limit on or off.

The two are independent firmware gates - both have to be open for charging to happen, so the effective ceiling is whichever is lower. There is no fight loop and no override cycle: set the system to 90% and OpenDente to 80%, you get 80%. Turn the system limit off, OpenDente still works on its own.

OpenDente also detects when it's the system limit (rather than its own write) that's blocking charging, via `NotChargingReason` bit 24, and labels it in the panel so it's clear which gate is holding the line.

## Features

- Charge limit, 50–100%
- Sailing mode - let the battery drain to a lower threshold before topping up, instead of trickle-charging at the cap
- Force discharge while plugged in
- Heat protection - pause charging above a configurable temperature
- Sleep handling - stop charging during sleep; optionally inhibit sleep until the limit is reached
- MagSafe LED reflects actual charging state
- Per-event native notifications

## What it shows

Even if you don't care about charge limiting itself, the panel surfaces a fair amount of data read directly from the SMC and IORegistry that's otherwise awkward to get at:

- Real-time adapter power, system power draw, and battery charge/discharge wattage
- Battery temperature, cycle count, design and current capacity, health percentage
- Adapter info: manufacturer, model, serial, rated wattage, voltage, current
- Decoded `NotChargingReason` when something pauses charging - so you can tell whether it's heat, sleep, the system limit, or OpenDente itself

If you've ever wanted to see exactly how many watts your charger is delivering vs. how much your machine is actually pulling, that view is there.

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon Mac
- Admin password once, to install the privileged helper

## How it works

Battery state is read via IOKit (no privileges needed). Charging is controlled by writing SMC keys, which requires root, so the app ships a small XPC daemon (`com.opendente.helper`) installed via `SMAppService`. Main app handles UI and reads; the helper handles writes.

Which SMC keys exist depends on the Mac and on its firmware (see the table under Status):

- Legacy: `CH0B`, `CH0C` to gate charging; `CH0I` to force discharge
- Tahoe: `CHTE` to gate charging; `CHIE` to force discharge
- Firmware range: `bfD0` (upper %), `bfE0` (lower %), `bfF0` (mode)
- Adapter cut, the last resort when only `CHIE` or `CH0J` is left: the adapter is disconnected, so the Mac runs on battery

OpenDente probes them in that order at startup and uses the first one that works. Settings → Battery → Control shows which one it picked.

OpenDente decides when to stop and start charging itself, flipping the gate as the battery crosses the threshold. With the charge-range keys it doesn't use the range as an "80%" setting: to stop, it sets a range just below the current charge and the adapter keeps powering the Mac.

More detail, including every way charging is restored when something goes wrong: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Build

Builds run from the command line; the Xcode IDE isn't needed, but Xcode.app must be installed (`xcodebuild` and the macOS SDK come with it). The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not checked in.

```
brew install xcodegen
make team-id > .team-id   # your signing Team ID, read from your "Apple Development" certificate
make build                # signed Debug build in build/DerivedData
```

`.team-id` is git-ignored, so every contributor keeps their own; `project.yml` only has the placeholder `YOUR_TEAM_ID`. `make generate` regenerates `OpenDente.xcodeproj` with your Team ID filled in, for editors that build the project directly (e.g. SweetPad in VS Code / VSCodium). Run it after adding or removing Swift files.

The release helper only accepts connections from an app signed by the same team as itself, so app and helper must be built with the same Team ID.

## Tests

```
make test
```

The tests don't need signing or a Team ID.

Unit tests cover the charging state machine, SMC value decoding (sp78/sp96 fixed-point), display logic, polling, and notification gating.

## Layout

```
OpenDente/         main app (SwiftUI menu bar)
OpenDenteHelper/   privileged XPC helper tool
Shared/            XPC protocol + shared constants
OpenDenteTests/    unit tests
docs/              how it works, tested hardware
project.yml        XcodeGen config
Makefile           generate, build, test
```

## Acknowledgements

This project leans on prior reverse-engineering work, in particular:

- [mhaeuser/Battery-Toolkit](https://github.com/mhaeuser/Battery-Toolkit) - XPC architecture, helper installation patterns
- [beltex/SMCKit](https://github.com/beltex/SMCKit) - SMC struct definitions and IOKit selector usage
- [actuallymentor/battery](https://github.com/actuallymentor/battery) - practical SMC key reference across Apple Silicon generations
- [charlie0129/batt](https://github.com/charlie0129/batt) - Apple Silicon charging behavior

## License

GPL-3.0. See [LICENSE](LICENSE).
