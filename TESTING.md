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
