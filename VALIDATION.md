# Validation — November 21, 2026

Completed:

- Mac debug and release builds; signed the supplied Mac app with an ad-hoc signature.
- Generic iOS device build with code signing disabled, using the installed Xcode SDK.
- Seven passing Swift tests: hardware source filtering; supported metric whitelist and source precedence; stable correction identities; sleep-stage/SDNN mapping without substituting RMSSD; envelope integrity and invalid-value rejection; blood-pressure pairs; read-only WAL-aware publishing, unchanged snapshots, corrections and removals; schema-change rejection. Some concerns are combined within individual tests.
- Export against the saved November database copy: 23,246 eligible normalized measurements, 20,390 non-Withings/unverified source records excluded. This sample contained weight, BMI, body fat, blood pressure, oxygen saturation, temperature, heart rate, sleep stages, respiratory rate and SDNN. Final snapshot about 4.5 MB.
- Second export of the same saved data reported no changes and did not replace the snapshot.
- Shared iOS/Mac exchange definitions are identical.

Not yet device-tested:

- End-to-end iCloud folder permission restoration and placeholder downloading on an iPhone.
- Apple Health authorization, matching, corrected-entry replacement, BP correlations and own-entry removal against a real Health store.
- Devices and interval families absent from the saved database sample, including tracker step intervals.

No live Apple Health records were created or deleted for these checks. No Withings server requests were made. The supplied package contains no personal measurements, databases, login sessions or credentials. Start with a small set of write permissions on the iPhone and inspect the resulting entries before enabling additional types. Keep the same bundle identifier across rebuilds so Health source ownership remains consistent.

macOS file coordination needed the test process to run outside the restricted command environment. This was an environment restriction; the standalone publisher succeeded with normal macOS coordination access. Fixture tests used only temporary databases.

## iOS update 0.2.1 (build 2)

- Generic iOS device build passed after adding background scheduling and cleanup controls.
- Three additional duplicate-policy tests passed: only app-owned entries can be selected for deletion; foreign duplicates are preserved; one own entry survives an own-only duplicate group; type, whole-second start/end and sleep-stage distinctions are honored.
- Inspected the built application plist: `processing` background mode is present, the permitted task identifier matches the app bundle identifier plus `.sync`, and both Health usage descriptions remain present.
- Background expiry cancels the task; cancellation checks precede later saves/deletes and revision commits. Interrupted partial imports can be reconciled on retry.
- Background operation does not request Health authorization, and defers when protected data is unavailable. The scheduler remains discretionary.
- Runtime background wake/expiry and real Health cleanup still require an iPhone test. No real Health records were modified during development.
- The Mac binary remains version 0.2.0; its behavior is unchanged in this iOS update.

## Both apps 0.2.2 (build 3)

- Mac release build and generic iOS device build passed.
- All 14 Swift tests passed, including new checks for newest-first history ordering, the 50-entry cap, correction identity/serialization, valid profile metadata, and publishing changed profile names when measurements are unchanged.
- Names are read from the existing profile catalog and written only to a small profile sidecar. Shared history/profile definitions are identical between Mac and iOS.
- Import-history callbacks occur after successful Health saves, including individual batches before a later interruption. Matched/skipped entries produce no new history events.
- Actual iPhone UI, protected history restoration, iCloud name-file delivery and Health save reporting remain device tests. No real Health records were written or deleted for this update.

## Profile-name fix 0.2.3 (build 4)

- Confirmed the existing local iCloud profile sidecar contains a nonempty name (without changing it).
- Removed the iOS requirement that the sidecar have downloading status exactly `current`; use a coordinated read instead.
- All 15 tests passed, including name-file reading/profile-ID validation, changed names in the main snapshot, and decoding old snapshots without a name.
- Mac release build and generic iOS device build passed. The fix still needs confirmation on the iPhone/iCloud delivery path; no real Health writes were used for verification.

## Source repository preparation

The 0.2.3 source was copied into a standalone repository tree, independent of the development workspace and binary delivery folders. No application behavior was changed. The repository copy passed all 15 Mac fixture tests and an unsigned generic iOS device build. Shared definitions match, and the generated iOS project includes a shared scheme. The staged source list was checked to exclude personal databases/exports, credentials, user settings and compiled outputs. The GitHub workflow is manual and has not been run on GitHub.

## Mac 0.2.4 automatic check status

The previous UI timestamp was updated only after a publish attempt, and automatic polling skipped that path when the source signature was unchanged. The timestamp alone therefore did not indicate that polling had stopped. The revised UI distinguishes a database check from a local snapshot write. Its local-write timestamp is filesystem metadata and does not assert delivery to iCloud.

All 16 Mac tests pass, including the new window-independent timer, injected workspace-wake/application-activation notification checks, and stopping/cancelling scheduled callbacks. Existing fixture tests still confirm unchanged snapshots are not rewritten. A Mac release build is included in the update. Real long-running background/wake behavior should be observed on the user’s Mac. The iPhone code was not changed.

## Mac 0.2.5 menu bar

The menu-bar release build passed, and the signed app bundle was verified with `LSUIElement` enabled and version/build 0.2.5/6. All 16 Mac regression tests passed. The menu shares the existing model for sync readiness and both timestamps, and opens the unique `bridge-main` window scene. No live database exports or Health writes were performed during verification. Menu clicks/window activation still need confirmation in the user’s normal Mac session.
