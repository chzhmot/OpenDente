# Review log

## 2026-10-24: Phase review of the firmware/menu-bar phase, and cleanup

- **Baseline:** `5d4c5a1`. **Reviewed:** `919ed6f` plus uncommitted cleanup in the working tree.
- **Verdict:** Go with conditions. The code builds and all 276 tests pass with 0 warnings. Conditions: the hardware checks in REVIEW.md, and team-ID caller verification before any public binary.

### REVIEW.md checked against the code

- Fixes #2 (menu bar refresh) and #4 (dead assignment) are correct.
- Fix #1 (helper exit) was incomplete. The lock was released before `exit(0)`, and timers could stack. Fixed in this cleanup.
- Fix #3 (window observers) was partial. Observers stayed registered when the view left its window. Fixed in this cleanup.
- All "Open" and "left as is" items are still accurate.
- REVIEW.md missed four things:
  - The helper reset charging on every disconnect, including the old connection during a reconnect. Fixed.
  - `KeepAlive` was removed from the helper plist.
  - The firmware hold point is recomputed below the current charge on every inhibit.
  - The release-build caller check matches the bundle identifier only, with no team ID.

### Cleanup done (uncommitted)

- Helper exit:
  - The lock is held through `exit(0)`.
  - A connection counter cancels a stale exit timer.
  - Removed the dead `watchdog.stop()`.
  - Charging is reset only when the last client disconnects.
- `SettingsView`: observers are removed when the view leaves its window. The 2 MainActor warnings are fixed.
- `SMCChargingAPI` now has a `String` raw value and a `displayName`. Five string switches across 5 files were removed.
- `MenuBarBatteryIcon`:
  - `Content` (Equatable) replaces the string cache key and the duplicated image build in AppDelegate and SettingsView.
  - Removed `image(percentage:)`, which had no callers.
  - Split the bolt drawing out of `draw`.
- Force discharge: merged the identical `.firmware` and `.adapter` cases.
- Tests: fixed 82 MainActor warnings with sync `setUp`/`tearDown`. Async versions cost about 23 s per run.
- `project.yml`: the test target reads `${DEVELOPMENT_TEAM}` instead of a hard-coded ID.
- README:
  - The key list now includes the firmware range and adapter cut.
  - Corrected the "no firmware stop" paragraph.
  - Corrected the Team ID sentence.
  - Added how to run the tests without signing.

### Follow-up the same day: building without the Xcode IDE, docs

- **Team ID:**
  - The real Team ID is `NU2N8HU5QM`, the certificate's OU. `XM72L9P3TU`, in the certificate's name, is the certificate's own ID. That mix-up caused the earlier signing failures.
  - The Team ID now lives in the git-ignored `.team-id`.
  - New `Makefile` targets: `generate`, `build`, `test`, `team-id`.
  - `make generate` writes the Team ID into the generated `.xcodeproj` for SweetPad.
  - `OpenDente.xcconfig` is deleted.
  - The old local `.xcodeproj` was regenerated, which removed the drift.
- **Helper:** in release builds the helper requires `anchor apple generic`, the app identifier, and the same team as its own signature, which it reads at runtime. Checked with `codesign -R`: the right team passes, a wrong team fails.
- **Docs:**
  - New `docs/HOW-IT-WORKS.md`, with the table of macOS versions and the SMC keys each one has.
  - New `.github/ISSUE_TEMPLATE/hardware-report.yml`.
  - README: Status, How it works, Build and Tests updated.
- **VSCodium:** tasks in the workspace `.vscode/tasks.json`. That file is outside this repo.
- **Verified:**
  - `make test`: 276 pass, 0 warnings.
  - `make build`: signed, app and helper `TeamIdentifier=NU2N8HU5QM`.
  - Release build compiles.

### Open items

- Decision needed on "Charging Mode Icon": remove the toggle or restore per-mode icons. `ChargingMode.batteryIconName` stays until then.
- This M1 Max has firmware 20457.1.29. batt PR #154 reports that firmware as gating the `bf*` keys. If so, firmware mode here can't work, which would explain the battery still powering the Mac while charging is held. Check whether `firmwareRangeIsWritable()` gives a false positive (REVIEW.md, "Firmware detection without a write probe").
- The helper's signing identifier is `com.opendente`, not `com.opendente.helper`. Cosmetic: nothing checks it today.
- Not done:
  - Moving `MenuBarBatteryIcon` into its own file needs `xcodegen generate`.
  - Finishing the statusBar → menuBar rename.
- Hardware checks still open (from REVIEW.md):
  - Battery holds in firmware mode.
  - Helper exits after quit.
  - Light/dark menu bar ink.
