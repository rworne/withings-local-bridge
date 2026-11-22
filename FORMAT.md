# Snapshot format, version 1

One UTF-8 JSON file per profile: `profile-<numeric ID>.whealth`.

Envelope fields: `format` (`WithingsHealthBridge`), `version` (1), `profileID`, `revision` (monotonically increasing Int64), `publishedAt` (Unix seconds), `recordsSHA256`, `records`.

Records contain `id` (64-character SHA-256 identity), `profileID`, `metric`, Unix `start`/`end`, numeric `value`, optional `secondValue`, native `brand`, `deviceModel`, optional `deviceID` and `firmware`. Times remain fractional seconds. Blood pressure uses systolic value and diastolic secondValue. Body mass/lean mass use kg; body fat/oxygen use fractions; temperature uses Celsius; rates use counts per minute; SDNN uses seconds; steps use counts. Sleep values 0/1/2/3 map to awake/core/deep/REM.

The records checksum is SHA-256 of Swift JSONEncoder sorted-key, unescaped-slash encoding of the records array. Records are sorted by identity. IDs derive from profile, metric, precise start/end and whole-body position, excluding values so corrections preserve identity. Native stores are reconciled by metric/time, preferring WTHealth over Measure over interval stores. This is an integrity checksum, not a digital signature: the user-selected folder is trusted input.

The Mac uses read-only SQLite transactions that honor WAL. Publication uses NSFileCoordinator and atomic replacement. The iPhone coordinates reads, validates the envelope, source whitelist, uniqueness, ranges and checksum before any Health writes, and rejects revisions older than that profile's last successful sync. Files larger than 128 MB are rejected. Incomplete iCloud files are retried on a later check.

The current snapshot is authoritative for this bridge/profile; it is not a deletion instruction for any other app's Health data. Folder files contain health information, so do not include them in public bug reports or source packages.

## Profile-name sidecar (optional)

`profile-<ID>.wprofile` is a small coordinated, atomically replaced JSON document containing `format: WithingsHealthBridgeProfile`, `version: 1`, `profileID`, and optional `name` (up to 160 characters). It is display metadata and does not influence measurement provenance or Health writes. The iPhone can read this without decoding the large measurement file. Existing version-1 measurement snapshots remain compatible. The sidecar can change when names change even if no measurements changed.

Version 0.2.3 adds optional envelope field `profileName` (maximum 160 characters) without changing the version-1 records format or checksum. Name-only changes republish the envelope with a new revision. Decoders accept previous snapshots with this field absent.
