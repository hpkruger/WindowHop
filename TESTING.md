# Validation — 6 September 2026

- Release build succeeded on Apple silicon, macOS 26, Swift 6.3.3.
- All 10 XCTest tests passed. Coverage includes forward/reverse cycling, missing/current/empty targets, frozen ordering, modifier-release commit, paired key-up suppression, cancellation, unrelated shortcuts, and typing/outside-click dismissal.
- Installed app at `~/Applications/WindowHop.app` and launched/relaunched it successfully.
- Enabled Accessibility through System Settings with the user's approval. Confirmed the app reports Accessibility enabled and Option+Tab ready.
- Inspected setup and picker visually. Fixed truncated setup copy and hid Settings during picker preview.
- Observed individual windows, hidden apps, and minimized windows in the live catalog.
- Opened a separate three-window fixture. Minimized test window 3 through the native UI, selected its minimized picker row, and confirmed that exact window was restored and focused.
- Fixed a preview-dismissal issue found during UI testing and added a regression test.

Limitations: the Computer Use tool's targeted key injection did not reliably exercise the global event tap (its Return key also behaved differently from keypad Enter in a system dialog). Physical hold/release Option+Tab and Escape remain manual acceptance checks. Full-screen, multiple-display, cross-Space behaviour, and performance with unresponsive apps were not validated. Automated keyboard tests exercise the production callback without posting events to the desktop.

Ad-hoc rebuilds invalidated Accessibility trust. Removing the stale WindowHop entry and re-adding the current installed bundle restored access; simply toggling the stale entry was insufficient.

## Configurable shortcut update

- All 13 tests passed after adding Option/Command selection. New tests cover both modifiers, Shift release without premature activation, paired Tab key-up suppression, canceling a gesture when the shortcut changes, and persisted preferences with invalid-value fallback.
- Selected Command+Tab in the installed app's Settings and verified it remained selected after a rebuild/relaunch.
- Refreshed the existing Accessibility grant for the new ad-hoc signature and verified “Command+Tab is ready.”
- Inspected Settings and the picker; the controls, help text, and release hint reflect the selected modifier. Fixed clipped help text.
- Physical Command+Tab interception of the macOS switcher remains a manual check; the callback logic and native configuration UI were tested.


## Switching consistency update — 7 October 2026

- All 30 XCTest tests passed with Xcode's macOS 27 SDK. Added regression coverage for rapid A → B → A selection before activation completes, stale completion rejection, intermediate app-window focus suppression, failure rollback, brief focus visits, startup seed order, Space preferences, ambiguous Window Server matches, verified-focus timeouts, superseded retries, restoration failures, and cancellation on unrelated input.
- Focus/selection state is owned by the main thread. Discovery cannot overwrite MRU history. Background focus queries carry revision/request checks; focus work is separated per app. Activation has its own worker and no fixed 120 ms delay.
- Release build and ad-hoc signing succeeded. Verified the installed app signature and matching SHA-256 hashes between the build and `~/Applications/WindowHop.app`.
- Rendered and visually checked Settings and picker previews. Settings includes Current Space / All Spaces and uses a scrollable container on smaller displays. Installed app launches with Current Space selected and preserves the existing Command+Tab preference.
- Xcode's build system hit a file-provider metadata signing error for the test bundle under the synced Documents folder. Tests passed with an isolated `/private/tmp/windowhop-switching-build` scratch directory. The build script now resolves the executable using SwiftPM's `--show-bin-path` and supports `WINDOWHOP_BUILD_PATH`.
- Installing the rebuilt ad-hoc app invalidated the old Accessibility signature. With the user authenticating the Privacy & Security prompt, removed the stale entry and added the installed app again. A restart was needed; verified “Accessibility enabled” and “Command+Tab is ready.”

Live verification: opened a temporary second Finder window, minimized it, confirmed both windows appeared separately in the picker, selected the minimized entry, and observed that exact window restored and focused. Closed both Finder windows opened for verification. Targeted Computer Use Command+Tab injection did not exercise the global tap reliably.

Remaining live acceptance checks: physical rapid Command+Tab/Option+Tab gestures, cross-Space/full-screen transitions, multiple displays, and a genuinely unresponsive background app. Automated activation tests use an injected driver and do not claim to validate macOS focus behavior.

Current Space intentionally retains minimized, hidden, and unmatched windows because public macOS APIs cannot reliably identify their Space. Startup stacking order approximates prior usage; exact pre-launch focus history cannot be recovered.
