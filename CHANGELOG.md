# Mac 0.2.5 — Menu Bar Utility

- Added a persistent menu-bar icon with Sync Now, Last checked, Last published (local), Open Withings Health Bridge and Quit.
- Main settings use a single window that can be reopened from the menu bar.
- The bundled Mac app runs without a Dock icon; closing its window leaves automatic checks running.
- Menu sync uses the same model, configuration and in-progress guard as the main window.
- iPhone app and measurement/Health mappings unchanged.

# Mac 0.2.4 — Automatic Check Status

- Last checked now advances on every automatic check, even when the local databases have not changed.
- Shows Last published (local) separately, with a clear no-database-changes status.
- Moved polling out of the window view into the application model; added immediate startup, enable, wake and app-activation checks.
- Republish a missing output snapshot even when source file metadata is unchanged.
- iPhone app and measurement/Health mappings unchanged.

# 0.2.3 — Profile Name Loading Fix

- Fixed iCloud name-file loading: coordinate reads instead of waiting indefinitely for a specific download status.
- Added the profile display name to the main measurement snapshot as another way to populate the picker during sync.
- Retain an already known name when incomplete profile metadata arrives.
- Kept compatibility with older snapshots that contain no name.

# 0.2.2 — Profile Names and Recent Imports

- iPhone profile picker displays the user’s name, with the selected profile number underneath.
- Mac publishes a small name sidecar, including when only the profile name changes.
- Added Last Imported Metric below Last Sync, showing metric type and measurement date/time.
- Tap the row to view up to 50 newest successfully imported measurements; no values shown.
- History persists on the iPhone and records successful batches even if a later batch fails or is interrupted.
- Older exports remain usable with a profile-number fallback.

# iOS 0.2.1 — Background Sync and Cleanup

- Added an optional Sync in Background switch using iOS Background Processing.
- Deferred locked-device syncs so duplicate checks can run before imports; added expiration/cancellation handling and rescheduling.
- Added confirmed cleanup of duplicate bridge-owned Health entries, independently of the iCloud file.
- Kept the confirmed delete-all action restricted to this app’s Health records; it now disables background sync as well as foreground automatic sync.
- Preserved a chosen profile while its iCloud file is temporarily unavailable.
- Mac app behavior unchanged.

# 0.2.0 — Standalone Health Bridge

- Separate Mac producer and minimal iPhone Apple Health app; no changes to CSV Explorer or the original Local Bridge.
- Explicit Withings hardware provenance filter and conservative HealthKit measurement whitelist.
- Coordinated, atomic iCloud snapshots with checksum validation and revision checks.
- Read-only database extraction that includes committed WAL content.
- Remembered folder/profile selection and optional publishing/syncing while each app is open.
- Existing-entry matching, versioned corrections and cleanup restricted to this app's own Health entries.
