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

## Mac 0.2.6 / iOS 0.2.4 icons and Mac history

All 19 Mac tests passed. New checks cover the 50-entry cap, newest-measurement ordering, persistence, corrections without duplicates, unchanged checks not rewriting the log, migration from an existing snapshot, malformed-history recovery and nonfatal history-write failure. History serialization excludes measurement values and device/profile names. The existing publisher/source-schema safeguards continue to pass.

The iOS device build passed with the shared Icon Composer document compiled as AppIcon; the built plist includes CFBundlePrimaryIcon/AppIcon. Apple’s compiler also rendered the Mac icon successfully. The Mac release is ad-hoc signed for local testing. No live measurements or Apple Health records were read/written during verification; synthetic fixtures were used. Real menu/history presentation and OS icon caching remain checks on the user’s Mac/iPhone.

## Mac 0.3.0 manual iPhone backup source

- All 21 Mac tests passed, including an RFC3394 known-answer test and a synthetic encrypted Finder backup with wrapped class/file keys, encrypted Manifest.db, database and WAL files, and an unrelated app domain.
- Verified wrong-password failure, exact-domain/file filtering, WAL preservation, temporary extraction cleanup, both NSData metadata encodings, unencrypted extraction and incomplete-backup rejection.
- Existing provenance, publication, schema guards, correction/removal and history tests remain passing. Shared Swift definitions match; the iPhone code and exchange format are unchanged.
- Inspected only the supplied backup's unencrypted metadata: it is a completed encrypted modern backup and lists the Withings application. Its password was not supplied. Real database extraction, phone schema compatibility and end-to-end Health import remain unverified until the user opens it locally in the app.
- Release Mac app built and ad-hoc signature verified. No live Health records, iCloud outputs or original backup files were changed during development.

## Mac 0.3.1 backup index compatibility

A synthetic WAL-mode index reproduced a SQLite 14 query failure with read-only access. Indexes are now opened as private writable copies, including unencrypted backups. The complete 21-test suite passes with the WAL-mode fixture. Actual supplied-backup unlocking remains a user test; no password was supplied to the agent. Failures now distinguish invalid decrypted headers from SQLite query errors and show SQLite's code/message.

## Mac 0.3.2 extracted measurement database preparation

The complete 22-test suite passes. A new regression fixture copies a real SQLite main file and its active WAL (containing a committed measurement), prepares only the private copies, then reads the measurement using the production read-only Database class. It verifies DELETE journal mode and byte-for-byte preservation of the original main file and WAL. Encrypted/unencrypted extraction fixtures now contain real SQLite databases. Original backups, live iCloud exports and Apple Health records were not modified. The user's encrypted database schemas still require local testing after password entry.

## Mac 0.3.3 shared track identifiers

- Inspected the already-unlocked temporary iPhone database copies read-only and found five pairs of active session rows sharing remote track IDs but differing in local IDs and session details. This was an intra-database collision, not a conflict between Mac and iPhone exports.
- Track source identities now use database UUID and Core Data primary key; remote/app track IDs remain metadata. Health measurement identities still depend on profile, metric and precise times.
- All 23 tests passed, including distinct session versions sharing a remote ID, stable identities after correction, and deletion of just one version.
- A full local publication from the unlocked iPhone copies succeeded with 21,057 eligible records. It used an isolated private temporary output/state folder, deleted immediately after verification. No live delivery folder, original backup or Apple Health records were changed.

## iOS 0.2.5 profile name discovery

- Compared the user's Mac-database and iPhone-backup delivery folders directly: profile sidecars were byte-identical; both snapshots carried the same profile name and ID. No files in either folder were changed.
- All 24 tests passed, including metadata priority, missing-sidecar snapshot fallback, cached-name avoidance of repeated snapshot parsing, blank-name handling and rejection of another profile's name.
- Unsigned generic iOS build succeeded with the updated project version 0.2.5/build 6. Shared definitions match. No simulator/device runtime was available; actual iCloud placeholder behavior must be confirmed on the user's phone.
- No Health records, delivery folders or authentication settings were changed during testing.

## User confirmation — November 22, 2026

The user confirmed both publishing methods and the iOS profile-name fix work on their devices. This complements the 24 passing automated tests, successful Mac release builds and successful unsigned generic iOS build. No new executable changes were made for the documentation/check-in update.
