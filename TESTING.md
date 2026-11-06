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

## Detached-tab focus update — 1 November 2026

- Window-creation notifications now invalidate cached focus for the frontmost app and request a fresh focus sample before window discovery completes. This prevents a quick switch from skipping the original browser window while it is still incorrectly marked current. Creation does not itself promote the new window, since a window can open in the background.
- All 33 XCTest tests passed using `/private/tmp/windowhop-detached-tab-build`. New regression coverage exercises the creation-notification handler and switching history before/after delayed discovery, preserves pending activation intent, and checks delivery of existing focus notifications.
- The release app built and was ad-hoc signed successfully at `build/WindowHop.app`. File-provider metadata in the synced Documents folder prevented strict signature verification there; a copy made with `ditto --norsrc --noextattr` outside that folder passed `codesign --verify --strict`. A subsequent build with persistent signing was installed as described below.
- After installation and permission reapproval, the user reported that the Safari detached-tab switching scenario appears to work. Automated coverage also checks switching back to the detached window once discovery catches up; broader live switching checks remain as listed above.

## Persistent local signing — 1 November 2026

- Created the dedicated `WindowHop Local Signing` identity in the login Keychain. The private key was imported as non-extractable with access assigned to `/usr/bin/codesign`; temporary key and import files were removed. No system trust settings were changed.
- The build script now reads the certificate fingerprint from `~/Library/Application Support/WindowHop/signing-identity`, unless `WINDOWHOP_SIGN_IDENTITY` is explicitly supplied. Invalid saved configuration or an unavailable configured identity fails the build rather than falling back to ad-hoc signing. Machines without saved configuration retain the original ad-hoc default.
- Added `WINDOWHOP_APP_PATH` to allow packaging outside a synced folder. Built from a fresh SwiftPM scratch directory and installed the signed app at `~/Applications/WindowHop.app`. Strict signature verification and comparison with the release executable passed.
- Verified signing continuity using a temporary copy with a changed bundle version: the code-directory hash changed, the certificate-based designated requirement remained identical, and the changed copy passed verification against the original requirement.
- The new app launched with the existing Command+Tab, All Spaces, and preview preferences. After the user re-added WindowHop in macOS settings, verified the app reports “Accessibility enabled”, “Command+Tab is ready”, and 8 available windows. Future permission retention has not yet been verified through a subsequent live update.

## Optional notification switching — 1 November 2026

- Added **Switch to the app that just notified me**, off by default, with **Control+Option+N** and a menu-bar action. Disabling it removes the notification observer/timer, clears the remembered app, and stops intercepting that shortcut. Pause, Accessibility loss, sleep, and session deactivation also stop monitoring.
- All **42 XCTest tests passed** using `/private/tmp/windowhop-notifications-build`. New coverage checks the default-off preference, exact/unambiguous source matching, startup baselining, duplicate/hover events, expired targets, simultaneous apps, unknown arrivals invalidating old targets, disabled shortcut passthrough, extra-modifier passthrough, repeat suppression, and cancellation of an existing window-switch gesture.
- An initial new keyboard test crashed because an XCTest generic assertion outlived the temporary event backing an unretained callback result. Changed the test to compare the result to nil immediately, matching the existing callback tests; the full suite then passed.
- On this Mac (macOS 27.2), a generated Script Editor banner exposed `AXNotificationCenterBanner`, an opaque `AXIdentifier`, and an `AXDescription` beginning with the source app name. `AXExpanded` on Notification Centre was false while the drawer was closed. Production scanning uses these observed attributes, bounded background traversal, Accessibility event hints, and a one-second fallback scan; it never clicks a banner or reads notification databases.
- Ran the production monitor in a temporary harness: it identified `com.apple.ScriptEditor2`, retained that target after detection, and cleared it on stop. A further generated notification after stop produced zero callbacks. The installed app separately displayed **Latest notification: Script Editor** after enabling the Settings toggle.
- Release build, persistent signing, strict signature verification, and executable hash comparison passed. Installed at `~/Applications/WindowHop.app`; the previous app is backed up at `/private/tmp/windowhop-before-notifications.sgE4Vt/WindowHop.app`. The designated requirement stayed unchanged and the installed app retained Accessibility access without reapproval.
- Exported and visually inspected the updated Settings preview and inspected the installed Settings window. Toggled the feature on for verification, then back off; it is left **off**. Closed the disposable Script Editor test document.
- The automation tool's targeted key injection did not establish that the global shortcut fired. Physical Control+Option+N, end-to-end notification-triggered window restoration, Messages/WhatsApp source labels, expanded Notification Centre, multi-display/full-screen arrivals, and older macOS versions remain manual acceptance checks. Existing window activation tests still pass. Notifications are matched only to running regular apps; unsupported/ambiguous source names are not guessed.

### Notification shortcut revision

- Changed the notification shortcut to **Command+Option+N** at the user's request. Labels and README use the new combination. The historical Control+Option+N checks above describe the original implementation.
- All 42 tests pass, including handling Command+Option+N and passing the old Control+Option+N combination through. Release build and strict signature verification passed; updated the installed app and Settings preview without changing the enabled/disabled preference.
- Physical shortcut and app-specific acceptance checks listed above now apply to Command+Option+N.
