# Withings Local Bridge

Source for **Withings Health Bridge**, **Mac 0.3.3 (build 11)** and **iOS 0.2.5 (build 6)**: a Mac publisher and an iPhone companion. A Windows 0.1.0 backup publisher is also available; see the [Windows guide](Windows/README.md).

The Mac reads either the databases maintained by the installed Withings app or a completed local iPhone backup, selects supported measurements with verified Withings hardware provenance, and publishes a compact snapshot to your chosen iCloud Drive folder. The iPhone reads that folder and saves missing measurements to Apple Health.

## Windows backup publisher

The [Windows app](Windows/README.md) uses completed local Apple Devices/iTunes backups, including encrypted backups. It does not require Withings on the PC. It follows the Mac backup interface: date/password selection, profile name and ID, output-folder selection, manual publishing, progress, timestamps and the 50 newest published measurements. iCloud for Windows handles delivery; the existing iPhone app and export format are unchanged.

The source and a manually runnable **Build Windows Bridge** workflow are included. The Windows guide covers setup, portable packaging, credential handling and remaining PC verification.

## Setup on Mac and iPhone

1. Choose a Mac data source:
   - **Withings on this Mac:** on an Apple silicon Mac, install Withings (WiScale.app), sign in and let it sync. The bridge detects the standard database folder when accessible. If needed, click **Choose Withings Database Folder** and select `~/Library/Containers/com.withings.wiScaleNG/Data/Library/Application Support/coredata`.
   - **iPhone Backup:** create or select a completed local Finder/iTunes backup. WiScale.app is not required on the Mac. An iCloud Backup alone is not sufficient. Follow the [iPhone backup guide](docs/IPHONE-BACKUP.md) for local-backup creation, passwords and extraction.
2. Open **Withings Health Bridge.app**, choose the source and explicitly select your own profile by name and Withings ID. In backup mode, select the backup date and click **Open Backup**, entering its encryption password if required.
3. Choose a dedicated output folder in iCloud Drive. Click **Sync Now** for the Mac-app source or **Publish Backup** for the backup source. Automatic publishing is available only for the Mac-app source. Folder and chosen-profile preferences are remembered; backup passwords are not.
4. Open `WithingsHealthBridge.xcodeproj` in Xcode. Select the app target, choose your developer team under Signing & Capabilities, and use your own unique bundle identifier. HealthKit capability and its usage descriptions are included. Build and run on your iPhone (iOS 17 or later).
5. In Health Bridge on the iPhone, choose the same iCloud folder, select your own profile by name (the profile number appears below the picker), and tap **Sync to Apple Health**. Grant read access for matching and write access for the metrics you want. The Health permission screen controls which metrics can be written.
6. Optionally enable **Sync while app is open** (checks on activation and every 30 seconds while active), **Sync in Background**, or both. Background processing requests an opportunity after at least an hour; iOS chooses the actual timing and can defer it much longer. It never prompts for Health permission in the background. Open the app for an immediate sync.

Background sync waits when protected Health data is unavailable: checking existing entries is required before writing, so the bridge does not bypass matching while the phone is locked. Interrupted runs can retry using the existing stable identifiers. Background Processing and its permitted task identifier are already configured in the Xcode project, and follow your chosen bundle identifier automatically.

The Mac can publish without the iPhone being open. iCloud delivery can take time. Only one Mac should publish a given profile into a given output folder.

## Measurements supported in this version

- Weight, BMI, body-fat percentage, and whole-body lean mass where explicitly identified.
- Heart rate, blood oxygen saturation, body temperature, and paired systolic/diastolic blood pressure.
- Verified native sleep-stage intervals, respiratory rate, and SDNN heart-rate variability.
- Verified tracker step intervals and heart-rate intervals.

Availability depends on your hardware and database contents. This is a conservative whitelist, not a promise that every measurement from every device is mapped. Unsupported units, positions, source identities, or interval families are omitted. In particular, RMSSD is not substituted for HealthKit's SDNN, skeletal muscle mass is not substituted for lean mass, and calories/distances with unverified native units are not guessed. No scores, ECG waveforms, audio, maps, workout sessions or arbitrary database fields are transferred.

## Source filtering

Brand alone is insufficient: imported measurements can carry a Withings brand code. The bridge requires an explicit device model from the installed application's native hardware-model list, plus a native/Withings brand code (0 or 1), and excludes Apple bundle sources. Software/import models such as 1051 and above, unknown models, and missing provenance are rejected. This deliberately favors omission over transferring third-party data. New Withings hardware may need a whitelist update.

The measurement snapshot includes only profile ID, measurement identity/type/times/values and limited source-device metadata (model, local device ID, firmware if present). A small `.wprofile` sidecar includes the profile ID and display name for the iPhone picker; no email address or birth date is included. No database copies, account credentials, notes, remote links, GPS or opaque blobs are published. The chosen folder contains sensitive health data; share it only with intended recipients.

## iPhone sync results

The status below **Last Sync** summarizes the most recent completed sync, rather than lifetime totals.

| Status | Meaning |
| --- | --- |
| **Saved** | New samples saved to Apple Health, or updated versions of samples previously saved by this app. |
| **Already in Health** | Matching samples from another app were found, so the bridge skipped importing its own copies. |
| **Unchanged** | Samples previously imported by this app still match the supplied records, so no update was needed. |
| **Not Authorized** | Eligible samples were skipped because this app does not have write permission for their measurement type. This does not mean HealthKit rejects or cannot support the type. |
| **Removed** | This app’s samples were cleaned up because matching samples from another app were found, or because they no longer exist in the current validated export for the same profile. |

Counts represent Health samples/components, not necessarily individual measurements. For example, blood pressure has separate systolic and diastolic samples, so one reading can count as two. A corrected bridge entry is counted under **Saved**; **Removed** reports cleanup. Write permission is checked before matching, so **Not Authorized** does not imply those samples are missing from Health. If a sync fails or is interrupted, some earlier batches may already have been saved; recent import history records those confirmed saves.

### Source priority and duplicate matching

- **Matching entries from other apps take priority over this bridge’s entries.** This includes Withings, Apple and any other app. The bridge does not give Withings a special rank over other existing sources.
- If another app already has a match, the bridge skips its own import. If the bridge imported first and a matching entry appears later, it removes only its own duplicate when that match is found.
- Matching uses the Health measurement type and whole-second start and end timestamps. Sleep also requires the same sleep stage. Numerical values do not have to be identical, which avoids duplicates caused by rounding or precision differences.
- The bridge never edits or deletes entries created by another app, including duplicates between Withings and Apple or between two other sources. When duplicate bridge entries are the only matches, duplicate cleanup keeps one bridge entry.
- These rules govern the bridge’s imports and cleanup. They do not change Apple Health’s own source-order settings.

The bridge needs Health **read access** to discover matches from other apps. iOS does not let the app verify whether read access was granted, so denied read access can lead to missed matches and duplicate imports. Grant read access to the supported types before syncing or cleaning duplicates.

The Mac’s recent-measurement history confirms a successful write into its local export snapshot. The iPhone’s **Saved** count and recent-import history confirm Health saves. A Mac publish alone is not confirmation that iCloud delivered the file or that the iPhone imported it.

## Matching, corrections and removal

- Existing readable entries from other apps are matched by measurement type and whole-second start/end times; sleep also requires the same stage. They are left untouched.
- Read permission cannot be inspected by an iOS app. If you deny it, matching cannot reliably detect existing entries, and duplicates are possible. Grant read permission before syncing.
- Every saved entry is attributed to this app. Stable sync identifiers and increasing versions allow corrections to replace this app's earlier values.
- When an existing third-party entry later matches, the bridge removes its own duplicate. A validated current snapshot can also remove obsolete entries owned by this app for that same profile. Source schema changes or missing/replaced databases stop Mac publishing rather than publishing a partial replacement.
- **Remove Duplicate Bridge Entries** scans this app’s entries directly in Health, across all imported profiles. It does not need the iCloud file. When a matching third-party entry exists, it deletes only this app’s entry; if several bridge entries match each other, it retains one. Read access is needed to find third-party matches. Each cleanup requires confirmation.
- **Remove This App’s Health Entries** deletes only entries created by this app and turns both foreground automatic syncing and background syncing off. A subsequent manual sync can recreate them.

Never select another person's profile for your Apple Health store.

## Privacy

The bridge has no Withings web login, API credentials, developer server, analytics or advertising. Database processing is local. Apple handles the iCloud transfer and Apple Health storage. Your existing Withings app still communicates with Withings to populate its own databases. Health Bridge is an independent application and is not affiliated with or endorsed by Withings.

## Build the Mac app

From the source directory, run `zsh Mac/build-app.sh`. It creates the app and optional command-line tool in `Mac/dist`. The build script ad-hoc signs the Mac app for local testing. This repository contains source only. Configure your own signing and distribution settings as needed; no developer team or signing credentials are included.

`project.yml` can regenerate the iOS project using XcodeGen, but the generated project is already included. No third-party Swift packages are required.

See `VALIDATION.md` for checks performed and remaining device testing.

Apple background execution and Health protection references: [Background Tasks](https://developer.apple.com/documentation/backgroundtasks), [HealthKit privacy and encrypted data](https://developer.apple.com/documentation/healthkit/protecting-user-privacy).

## Recent imports (0.2.2)

Below Last Sync, **Last Imported Metric** shows the newest successfully imported measurement’s type and measurement date/time. Tap its chevron to see up to 50 newest imported measurements for the selected profile. No measurement values are shown. Entries already in Health do not count as new imports. The history persists locally in the iPhone’s protected application storage and is updated only after a successful Health save, including successful batches before an interrupted sync. It starts with imports made by this update; it does not reconstruct earlier imports.

Update both apps for profile names, then publish once on the Mac. The sidecar is added even when the measurements have not changed. Older export folders remain usable; the picker falls back to the profile number when no display name is available.

### Profile name fix (0.2.3)

The name reader now coordinates iCloud reads rather than requiring the file’s download status to equal `current`. The main measurement snapshot also carries the optional display name, providing another path to restore it during a sync. Update both apps, publish once on the Mac, then tap Sync to Apple Health on the iPhone. Existing names are cached when metadata is temporarily unavailable; older exports still work without names.

## Repository layout

- `Mac/` — Swift package, Mac UI, command-line publisher and fixture tests.
- `iOS/` — iPhone UI, iCloud reading, background scheduling and HealthKit sync.
- `Shared/` — the portable exchange types, matching policy and recent-import definitions.
- `Windows/` — local-backup Windows UI, publisher, portable-executable build and synthetic compatibility tests.
- `WithingsHealthBridge.xcodeproj/` — generated, committed iOS project; ready to open without XcodeGen.
- `project.yml` — optional XcodeGen input for regenerating the project.
- `scripts/check-shared.sh` — checks that the Mac package mirrors match the shared definitions.
- `.github/workflows/ci.yml` — manually runnable Mac tests and unsigned iOS build.

The Mac package currently keeps copies of the three `Shared/` Swift files under `Mac/Sources/BridgeCore`. When editing these definitions, update both copies and run `scripts/check-shared.sh`.

## Developer checks

From the repository root:

```sh
zsh scripts/check-shared.sh
swift test --package-path Mac
xcodebuild -project WithingsHealthBridge.xcodeproj -scheme WithingsHealthBridge \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Use macOS with Xcode 26 or later and its command-line tools selected. For the Mac application bundle, run `zsh Mac/build-app.sh`. For iPhone installation, choose your own development team and unique bundle identifier in Xcode. Keep that bundle identifier consistent across upgrades so existing Health entries remain owned by the same app. The Background Tasks identifier follows the bundle identifier automatically.

Tests construct synthetic SQLite fixtures in temporary directories. They do not require Withings to be installed or access your live databases or Apple Health. Real device/iCloud verification is described in `VALIDATION.md`.

## License

Released under the [MIT License](LICENSE).

## Mac check and publish status (0.2.4)

**Last checked** advances on every automatic database check, including when the file signature is unchanged. **Last published (local)** shows the snapshot file’s last modification time and is not an iCloud-delivery receipt. The status explicitly says when no database file changes were detected. The bridge still relies on the Withings app to update its local databases first.

Polling belongs to the app model, not a window’s view. It runs while the app remains open, including after its window closes, and checks immediately at startup, when automatic publishing is enabled, on Mac wake and on returning to the app. Turning automatic publishing off prevents those callbacks from publishing. A missing output snapshot is republished even when source files are unchanged. No Withings network requests or wake-from-sleep prevention were added.

## Menu bar (Mac 0.2.5)

The Mac application bundle runs as a menu-bar utility, with a heart/status icon and no Dock icon. Click the menu-bar item for **Sync Now**, **Last checked**, **Last published (local)** and **Open Withings Health Bridge**. The menu and main window share the same model and timestamps. Sync is disabled until folders/profile are configured, and while a sync is already running.

Close the main window to leave the bridge running in the menu bar. **Open Withings Health Bridge** brings back the single settings window. **Quit Withings Health Bridge** exits the process and stops automatic checks. This changes only the Mac app; no iPhone update is needed.

## Icons and Mac recent history

Both app projects share the Icon Composer artwork in `Artwork/AppIcon.icon`. The Mac bundle includes the compiled icon and the iPhone project references the same source. The menu-bar status symbol stays monochrome.

On the Mac, expand **Recent Measurements → Last Published Metric** to see up to 50 newest measurements successfully written into the export snapshot. The menu bar also has **Recent Measurements…** to open this section. Rows show only measurement type and measurement date/time. History is retained privately per source/output/profile configuration in `RecentPublished.json`, not written to iCloud or included in Git.

New and corrected records update the history after a successful publish. Unchanged checks and name-only metadata updates do not create new history events. When upgrading, the first successful check can initialize the list from the existing validated snapshot, using its original publish time. A malformed history can be rebuilt, and a history-write failure is reported without preventing a valid snapshot from being published. The Mac list confirms local publication, not an Apple Health import; the iPhone’s separate list confirms its Health saves.

## Importing from a local iPhone backup

See the [complete iPhone backup guide](docs/IPHONE-BACKUP.md). It covers creating a local backup when you normally use iCloud Backup, finding the folder, encrypted-backup password handling, choosing the profile, publishing and syncing to Apple Health. The bridge cannot read iCloud Backups directly. Both sources use the same iPhone client and export format.

Backup mode is manual and does not require Withings on the Mac. Use a fresh backup: an older authoritative snapshot can replace or remove this bridge's own newer Health entries. The guide explains this behavior and the temporary database copies.

Format reference: [iphone_backup_decrypt](https://github.com/jsharkey13/iphone_backup_decrypt) describes the Finder backup keybag and file-key layout. This implementation uses Apple's CommonCrypto directly and does not bundle that library.

## iOS 0.2.5 profile names in newly selected folders

Both Mac data sources publish the same profile metadata. The iPhone now requests the small profile file before checking whether it is locally available. If that file is delayed and the name is not cached, it reads the name from the validated measurement snapshot, without requesting Health permissions or importing measurements. Readable profile metadata refreshes cached names, and a cached name avoids repeatedly parsing the larger snapshot. Profile-number identity and all Health matching rules are unchanged.
