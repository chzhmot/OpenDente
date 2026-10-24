# OpenDente review: commit 6b5673b

Range reviewed: `5d4c5a1..6b5673b`. Fixes are in `919ed6f` (local, not pushed). Tests: 276 pass.

## Fixed in 919ed6f

| # | Where | Problem | Fix |
|---|-------|---------|-----|
| 1 | `OpenDenteHelper/HelperDelegate.swift` | The helper exited on the last client disconnect. The app drops its old XPC connection and opens a new one on every reconnect, so the old connection's invalidation could arrive first and the helper quit under the new connection. The client count was also raised after `resume()`. | The count is raised before `resume()`. After the last disconnect the helper waits 2 s and re-checks before `exit(0)`. |
| 2 | `OpenDente/App/AppDelegate.swift` | Toggling or reordering menu bar items updated the Settings preview but not the real item until the next battery poll (about 2 s). | The menu bar subscribes to `settings.objectWillChange` and refreshes on the next run loop turn. |
| 3 | `OpenDente/Views/SettingsView.swift` | Window observers (`didBecomeKey`, `willClose`) were added on every `viewDidMoveToWindow` and never removed, so they could stack. | Old observers are removed before new ones are added. |
| 4 | `OpenDente/Models/AppSettings.swift` | Dead assignment in `moveMenuBarItem`. | Removed. |

## Open: needs a decision

- **"Charging Mode Icon" toggle does nothing.** `MenuBarBatteryIcon.glyph(state:mode:showMode:)` ignores `mode` and `showMode`. The glyph comes only from `isCharging` (bolt) and `isPluggedIn` (plug). This predates the review. Either remove the toggle or bring back per-mode icons.

## Open: edge cases, left as is

- **Saved panel items reset.** The setting key changed from `popoverDetailItems` to `panelDetailItems` with no migration, on purpose, because every "popover" mention was to go. The old key stays in the defaults, unused.
- **Firmware mode without an adapter key.** `.firmware` counts as discharge-capable, but force discharge needs `CHIE` or `CH0J`. On a Mac with the `bf*` keys but neither adapter key, the Discharge button is offered and then fails. Not the case on the M1 Max.
- **Firmware detection without a write probe.** `firmwareRangeIsWritable()` returns true without testing when `bfF0` is already non-zero. If the keys are read-only for the process, every inhibit fails. The app-side `hasFirmwareChargeRange` also has no writability check, so before the helper connects the UI can show "firmware" where the helper would pick "adapter".
- **Firmware inhibit retries.** `inhibitFirmwareLocked` writes `bfF0=00`, then the bounds, then `bfF0=02` on every call. A retry (up to 3) or the sleep hook briefly opens a normal-charging window. This follows the PR #469 flow, and it can't be changed safely without write tests on the keys.
- **Menu bar image position.** The image view is positioned from `button.bounds` right after `statusItem.length` changes, and the button may resize a moment later. The autoresizing mask corrects it, and it looked right on the test Mac. If the item ever sits off-centre, this is where to look.

## Not verified on hardware

- Whether the battery really holds at the firmware upper limit while the adapter carries the load. The last readings (18:40–18:43) still showed the battery supplying the load.
- Whether the helper process is gone after quitting the app (`pgrep -fl com.opendente.helper` should print nothing).
- The menu bar item in a light vs dark menu bar (solid black or white ink).

## Left out of the commit

`Compare Source Codes/` (AlDente and Battery Toolkit sources), `Symbols/` (SF Symbol exports), `apply_adapter_patch.py`, `opendente-adapter-fallback.patch`.
