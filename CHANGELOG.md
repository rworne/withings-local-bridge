# Backup Setup Documentation

- Added a complete guide for creating a local Finder backup, locating it, unlocking it and publishing Withings measurements to the existing iPhone client.
- Clarified iCloud Backup versus iCloud Drive, manual refresh/freshness requirements, password handling and temporary database copies.
- Updated the main setup instructions for both supported data sources.

# iOS 0.2.5 — Profile Names in New iCloud Folders

- Request profile metadata download before inspecting a potentially unmaterialized iCloud file.
- Resolve missing picker names from the validated measurement snapshot without requiring an Apple Health sync.
- Cache resolved names and refresh profile metadata when the selected profile changes.
- Keep the same export format and behavior for Mac-database and iPhone-backup sources; Mac remains 0.3.3.

# Mac 0.3.3 — Shared Session Identifiers

- Identify local session rows by database UUID and Core Data primary key, preserving remote and app track IDs as metadata.
- Handle distinct local session versions sharing a remote track ID without aborting the entire export or silently discarding either row.
- Keep Apple Health measurement identities and type/time duplicate matching unchanged.
- Added regression coverage for shared remote track IDs, corrections and removal of one local session version.

# Mac 0.3.2 — Prepare Extracted Measurement Databases

- Prepare every extracted database as a private writable copy before the regular read-only measurement reader opens it.
- Checkpoint committed WAL measurements, verify DELETE journal mode, and remove obsolete private sidecars.
- Rebuild shared-memory indexes instead of reusing archived SHM files from the phone.
- Keep original backup files untouched and retain the existing exact app-domain/path filtering.
- Added a regression test with measurements present only in a live WAL and replaced text-only extraction fixtures with real SQLite databases.

# Mac 0.3.1 — Backup Index Compatibility

- Open backup indexes as private writable copies so SQLite can initialize WAL/journal state without changing the original backup.
- Preserve a supplied unencrypted index WAL when copying the index.
- Verify the decrypted SQLite header and include SQLite's error code and explanation if querying still fails.
- Remove the private index and journal companions after database extraction.
- Added WAL-mode index coverage to the encrypted/unencrypted backup fixture.

# Mac 0.3.0 — Manual iPhone Backup Source

- Added a source selector for local Withings databases or a completed iPhone backup.
- Added local password unlocking of encrypted backups, dated backup selection, profile selection and manual publication.
- Extracts only required Withings databases and WAL companions, preserving the existing device filtering and iPhone exchange format.
- Backup mode requires neither WiScale.app on the Mac nor automatic polling. Passwords are not saved.
- Allows older backups for testing; documents authoritative snapshot replacement.
- iPhone companion unchanged at 0.2.4.

# Documentation update

- Explained Saved, Already in Health, Unchanged, Not Authorized and Removed sync results.
- Documented source priority, timestamp-based matching, rounding differences, sample counts, read/write permissions and cleanup ownership.
- Clarified the difference between Mac publication and iPhone Apple Health imports.

# Mac 0.2.6 / iOS 0.2.4 — Icons and Mac History

- Added shared icon artwork for the Mac application bundle and iPhone project.
- Added a persistent Mac list of the 50 newest published measurements, showing type and measurement date/time without values.
- Added Recent Measurements to the menu-bar menu.
- Records new/corrected measurements only after successful publication; unchanged checks do not retimestamp or duplicate history.
- Seeds history from an existing validated export on upgrade and keeps it private to the selected configuration.
- Icon Composer builds require Xcode 26 or later.

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

- Standalone Mac producer and minimal iPhone Apple Health app.
- Explicit Withings hardware provenance filter and conservative HealthKit measurement whitelist.
- Coordinated, atomic iCloud snapshots with checksum validation and revision checks.
- Read-only database extraction that includes committed WAL content.
- Remembered folder/profile selection and optional publishing/syncing while each app is open.
- Existing-entry matching, versioned corrections and cleanup restricted to this app's own Health entries.
