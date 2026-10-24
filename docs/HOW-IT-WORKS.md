# How OpenDente works

This page is for anyone who wants to know what OpenDente does to their Mac before running it, or who wants to change the charging code. It covers the two processes, how the charging mode is chosen, why macOS updates changed that, and every way charging is restored when something goes wrong.

## Two processes

| | App (`com.opendente.app`) | Helper (`com.opendente.helper`) |
|---|---|---|
| Runs as | You | root, as a launchd daemon registered with `SMAppService` |
| Does | Menu bar UI, reads battery state from IOKit every 2 s, decides when to charge | Writes SMC keys, and nothing else |
| Lives | While you use it | Only while the app is connected: it exits 2 s after the last connection closes, and launchd starts it again when the app connects |

The app talks to the helper over XPC (`Shared/HelperProtocol.swift`): enable charging, inhibit charging, force discharge, set the MagSafe LED, heartbeat.

In release builds the helper only accepts a connection from an app with the identifier `com.opendente.app` that is signed by the **same team** as the helper itself. It reads that team from its own signature at runtime, so no Team ID is compiled in. Debug builds skip the check.

## Choosing a charging mode

At startup the helper probes the SMC and uses the first mode that works:

| Order | Mode | Keys | How charging is held |
|---|---|---|---|
| 1 | Tahoe | `CHTE` (inhibit), `CHIE` (discharge) | `CHTE = 01 00 00 00` |
| 2 | Legacy | `CH0B` + `CH0C` (inhibit), `CH0I` (discharge) | `CH0B = CH0C = 02` |
| 3 | Firmware range | `bfD0` upper %, `bfE0` lower %, `bfF0` mode | A range just below the current charge, then `bfF0 = 02`. The adapter keeps powering the Mac. |
| 4 | Adapter cut | `CHIE` (`08`) or `CH0J` (`20`) | The adapter is disconnected, so the Mac runs on battery |

The app shows the chosen mode in Settings → Battery → Control and in the diagnostic report.

In every mode OpenDente decides when to stop and start charging itself. It doesn't hand the firmware an "80%" target, even where the firmware has a charge range.

## macOS versions and SMC keys

The classic keys (`CHTE`, `CH0B`, `CH0C`) were removed by firmware that came with recent macOS updates. That is why modes 3 and 4 exist.

| macOS | What changed | Mode OpenDente ends up in |
|---|---|---|
| 14 – 15.7, 26 – 26.6 | Nothing: classic keys present | Tahoe or Legacy |
| 26.4 | Apple adds its own charge limit (System Settings → Battery, 80–100 %). The keys stay. | Tahoe or Legacy; both limits apply, the lower one wins |
| 15.8, 26.7 | Firmware update removes the classic keys. `bfD0/bfE0/bfF0` are still present. | Firmware range if the write probe succeeds, otherwise adapter cut |
| 27 beta 4+ (firmware 20457.0.125+) | Both the classic and the `bf*` keys need the private entitlement `com.apple.private.iokit.soc-limit`, which third-party apps can't get. Only the adapter key still works. | Adapter cut |

The key removal is tied to the firmware, not to Apple's charge limit. 15.8 lost the keys but has no charge-limit setting.

Apple hasn't documented any of this. The table is based on reports from other open-source battery tools:

- [actuallymentor/battery PR #480](https://github.com/actuallymentor/battery/pull/480): classic keys gone on macOS 27 and on the firmware shipped with 26.7 and 15.8. A MacBook Air M2 on 15.8 still reads the `bf*` keys.
- [charlie0129/batt PR #154](https://github.com/charlie0129/batt/pull/154): on macOS 27 beta 4+ firmware, all charge keys are gated by `soc-limit`; the adapter key is not.
- [9to5Mac on macOS 26.4](https://9to5mac.com/2026/04/03/macos-26-4-adds-three-new-battery-features-on-mac-heres-how-to-use-them/): Apple's own charge limit.

If your Mac behaves differently, please file a [hardware report](../../../issues/new?template=hardware-report.yml). The firmware version (System Information → Hardware → System Firmware Version) matters more than the macOS version.

## Getting charging back when something goes wrong

The helper records whether it is holding charging in a root-owned state file (`/Library/Application Support/OpenDente/helper-state`). Every path below ends by enabling charging, turning force discharge off and handing the MagSafe LED back to the system.

| Event | What restores charging |
|---|---|
| You quit OpenDente | The app asks the helper to reset, and waits for it, before exiting |
| The app crashes or is killed | The XPC connection closes. If no other app connection is open, the helper resets at once. |
| The app hangs | The app sends a heartbeat every 30 s. After 120 s without one, the helper's watchdog resets. |
| The helper is stopped (`SIGTERM`, `SIGINT`) | Signal handler resets, then exits |
| The helper crashes | On its next start the helper sees "inhibited" in the state file and resets |
| The Mac sleeps | The watchdog pauses so sleep doesn't count as a hang. If "Stop Charging when Sleeping" is on, the helper also holds charging itself from the kernel's sleep notification, in case the app is suspended before its own request gets through. |

## Checking that the helper has quit

After quitting the app, `pgrep -fl com.opendente.helper` should print nothing.
