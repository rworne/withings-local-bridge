# Withings Health Bridge for Windows — 0.1.0

A manual local-iPhone-backup publisher for the existing Health Bridge iPhone app. No Withings installation is needed on the PC. This first version targets 64-bit Windows 11.

## Requirements

- **Apple Devices** (or iTunes for Windows) to create a completed local iPhone backup.
- **iCloud for Windows**, signed into your Apple Account with iCloud Drive enabled, to deliver exports.
- The existing **Health Bridge** iPhone app, configured to read your export folder and write the desired Apple Health metrics.

The packaged application includes its own runtime. You do not need Python, Xcode or a .NET installation to run it. Extract the whole ZIP; keep the executable and its supporting `_internal` folder together.

## Using the bridge

1. Open Withings on the iPhone and let it finish syncing. Connect the iPhone to the PC and create a local backup with Apple Devices or iTunes. Encryption is recommended; keep its password. Wait until the backup is complete.
2. Open **Withings Health Bridge.exe**, click **Choose iPhone Backup…**, and select the complete backup folder or its parent. Select the intended backup by date.
3. For an encrypted backup, enter its backup encryption password and click **Open Backup**. This is not necessarily your Apple Account, Withings or Windows password. The bridge clears the password field immediately and does not save the password.
4. Select your own Withings profile. The picker shows its name and ID; the number also appears beneath it. No profile is automatically selected on first use. Explicit selections and folders are remembered.
5. Choose a dedicated folder inside **iCloud Drive** as the output. Select the same folder in Health Bridge on the iPhone.
6. Click **Publish Backup**. Progress shows extraction and publication work. The last-checked and last-published timestamps refer to this PC, not confirmed cloud delivery. The recent list contains the 50 newest successfully published measurements, showing type and measurement time, without values.
7. Let iCloud deliver the export, then sync in the iPhone app. Existing duplicate matching and own-entry cleanup rules are unchanged.

**Updates are manual.** Make a new local backup, reopen it, and publish again for newer readings. The bridge does not create backups, poll for changes or talk to Withings servers. iCloud Backup cannot be opened directly: a local backup is required. iCloud Backup and the iCloud Drive output folder are separate services.

Apple's Windows backup locations usually are:

```text
%USERPROFILE%\Apple\MobileSync\Backup
%APPDATA%\Apple Computer\MobileSync\Backup
```

Use Apple Devices' **Manage Backups / Show in Explorer** if your backup is elsewhere. Do not rename the hashed files or select a single database. The Mac-oriented [backup guide](../docs/IPHONE-BACKUP.md) also explains freshness, encryption and the extraction format; on Windows use Apple Devices instead of Finder.

## Privacy and compatibility

All backup unlocking and database processing occur locally. The bridge never asks for Apple Account or Withings credentials. Sign into iCloud only through Apple's iCloud for Windows software. Backup passwords and derived keys exist in process memory while opening/extracting the backup; they are not persisted in settings, logs, the Keychain or exported files. Reopening an encrypted backup requires the password again. There is no promise of secure erasure of process memory.

Private extracted databases, preferences and recent history are stored under `%LOCALAPPDATA%\WithingsHealthBridge\Windows`. Extracted databases are cleaned up when closing/changing the backup or quitting normally. A crash or forced termination can leave private copies; close the bridge before removing its `Sessions` subfolder to clean those up. The app waits for an active operation before closing. It never modifies the original backup.

The bridge publishes only the existing supported HealthKit metrics from verified Withings hardware and the profile display name. It excludes unknown/import devices and Apple bundle sources. It produces the same `.whealth` and `.wprofile` format as the Mac bridge; the iPhone app needs no Windows-specific changes.

**Use the freshest source.** Publishing an old backup can replace or remove this bridge's own newer Health entries, because the snapshot is authoritative. Entries owned by other apps are untouched. Avoid multiple publishers overwriting a profile in the same output folder. See the main [sync-results documentation](../README.md#iphone-sync-results).

This is an independent project, not affiliated with or endorsed by Withings. The first Windows package is unsigned; Windows may show its usual unrecognized-publisher notification. Interactive Windows use, real backup unlocking and iCloud delivery should be verified by a tester before wider distribution.

## Building from source

Install 64-bit Python 3.12 on Windows, then run from this directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

The script installs pinned build dependencies, builds a folder-based executable, verifies that the packaged UI and libraries initialize, then creates `dist/WithingsHealthBridge-Windows-0.1.0-x64.zip`. `-ExecutionPolicy Bypass` applies to this build process only; no machine-wide setting is changed.

For development without packaging:

```powershell
python -m pip install -r requirements.txt
$env:PYTHONPATH = '.'
python -m unittest discover -s tests -v
python main.py
```

The Windows build can also be run manually using the repository's **Build Windows Bridge** GitHub Actions workflow. It uses synthetic tests and an isolated packaged-UI startup test, never personal backups or Apple Health. Download its ZIP artifact after a successful run.

## Compatibility checks

Tests cover encrypted and unencrypted backup extraction, wrong passwords, incomplete backups, WAL preservation, native-device filtering, precision, store priority, profile names, corrections/removals, source safeguards, history and the existing Swift-generated checksum/identifier fixture. On macOS, setting `SWIFT_BRIDGE_BIN` when running the tests compares both complete publishers using the same synthetic databases. The Mac tests also validate the fixture using the iPhone's real Swift exchange implementation.

Upstream references: [Apple Devices backup instructions](https://support.apple.com/en-us/108967), [Windows backup locations](https://support.apple.com/en-us/108809), [iCloud Drive for Windows](https://support.apple.com/guide/icloud-windows/icwddbc813bd/icloud), [PyInstaller packaging](https://pyinstaller.org/en/stable/), and [PyCryptodome key wrapping](https://www.pycryptodome.org/src/cipher/modern).
