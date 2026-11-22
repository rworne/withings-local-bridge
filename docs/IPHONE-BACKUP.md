# Import Withings measurements from an iPhone backup

Use this method when you want to extract Withings measurements from your iPhone without running the Withings app on the Mac. It uses the same iCloud delivery format and iPhone Health Bridge app as the live Mac-database method.

## You need a local backup

If your iPhone uses automatic **iCloud Backup**, you may not have a backup stored on your Mac. This bridge reads completed **local Finder/iTunes backups**. It cannot read an iCloud Backup directly or download one from Apple's servers.

**iCloud Backup and iCloud Drive are separate things.** You first create a local iPhone backup for the Mac bridge to read. The bridge then places only its filtered measurement export in an iCloud Drive folder for the iPhone companion. You do not need to put the entire iPhone backup in iCloud Drive.

Plan for enough free Mac storage and time to create a full local backup. Only data present in that backup can be exported. To get newer measurements, let the Withings iPhone app finish syncing, make another local backup, then open and publish it again. There is no automatic backup polling or iPhone-backup creation in the bridge.

## 1. Create a local backup on your Mac

1. Open Withings on your iPhone and let it finish syncing.
2. Connect the iPhone to your Mac, open Finder and select the iPhone in the sidebar. Complete any Trust or passcode prompts.
3. In the **General** tab, choose the option to back up the iPhone to this Mac.
4. Enable **Encrypt local backup**, choose a password and keep it somewhere safe. Apple requires encryption to include Health and Activity data in a computer backup; using an encrypted backup is recommended here too.
5. Click **Back Up Now** and wait until Finder shows that it completed. Check the displayed backup date.

The bridge can also open an existing unencrypted backup, but it cannot recover data that the backup omitted. Creating a backup does not make the bridge responsible for your ongoing backup schedule; check that your iPhone's iCloud Backup settings remain as you intend afterward.

See Apple's [Mac backup instructions](https://support.apple.com/en-us/108796) and [explanation of encrypted backups](https://support.apple.com/en-us/108353).

## 2. Locate the backup folder

In Finder's iPhone **General** tab, click **Manage Backups**, right-click the completed backup and choose **Show in Finder**. Alternatively, use Finder's **Go → Go to Folder** with:

```text
~/Library/Application Support/MobileSync/Backup/
```

Select the complete backup folder with the long device identifier, or its parent folder. A modern backup contains `Manifest.plist`, `Manifest.db`, `Status.plist` and subfolders holding its files. Keep that structure intact; do not select an individual database or rename the hashed files. A complete backup stored on an external drive can also be selected.

Apple provides more detail in [Locate and manage backups](https://support.apple.com/en-us/108809).

## 3. Extract and publish with the Mac bridge

1. Open **Withings Health Bridge**. Under **Data Source**, select **iPhone Backup**.
2. Click **Choose iPhone Backup…** and select the folder described above. If several backups are listed, choose the intended backup by its displayed date.
3. If encrypted, enter its **backup encryption password** and click **Open Backup**. This is the password set when local backup encryption was enabled, not necessarily your Apple Account password, Withings password or iPhone passcode.
4. Select your own Withings profile by name and number. An explicitly chosen profile is remembered for that backup path; verify it before publishing.
5. Choose a dedicated output folder in **iCloud Drive**. This must be the folder selected in the iPhone Health Bridge app.
6. Click **Publish Backup**. Wait for successful publication and allow iCloud time to deliver the files.

The Withings Mac app is not required in this mode. Publication is manual. Reopen and publish each new local backup when you want updated measurements.

## 4. Sync on the iPhone

Open Health Bridge, choose the same iCloud Drive folder, select your own profile and tap **Sync to Apple Health**. Grant read access for duplicate matching and write access for the supported measurement types you want to save.

Both Mac sources produce the same `.whealth` measurement snapshot and `.wprofile` name file. No special iPhone import mode is needed. The existing matching and cleanup rules apply; see [sync results and source priority](../README.md#iphone-sync-results). A profile number can appear temporarily while iCloud delivers the name information.

## Encrypted-backup password handling

- Enter the password only into the Mac bridge's password field. The field clears when opening starts.
- The password and derived encryption keys are used in local process memory to unlock the index and extract the needed databases. The bridge does not save them in preferences, the Keychain, logs or export files, and does not send them to the developer, Apple or Withings.
- You must enter the password again when reopening an encrypted backup. Remembered folders and profile selections do not store the password.
- The original backup is not modified or decrypted in place. The bridge uses private temporary copies, then publishes only supported measurements with verified Withings-device provenance and the profile display name.
- The decrypted index is removed after extraction. Private database copies are removed when that backup is closed or the app quits normally. A crash or forced termination can leave temporary copies until system cleanup. Passwords and keys are not written into those copies. This is not a promise that process memory or deleted files are securely erased.

The bridge cannot recover a forgotten backup password. Apple's [encrypted-backup guidance](https://support.apple.com/en-us/108353) explains the available options; resetting the password does not unlock an older encrypted backup.

## Freshness and limitations

**Use a current backup.** The exported snapshot is authoritative for this bridge and profile. Publishing an older backup is currently allowed, including for testing: a later iPhone sync can restore earlier values or remove this bridge's own entries missing from that older snapshot. It never removes entries owned by another app. When switching between the Mac-app and backup methods, publish the freshest data; avoid two publishers overwriting the same profile's output folder.

Only supported Apple Health measurement types originating from verified Withings devices are exported. The bridge reads only the required Withings database families and their WAL files, plus profile-name metadata, under `AppDomain-com.withings.wiScaleNG/Library/Application Support/coredata` in the backup. It does not export the whole backup, unrelated apps' files, account secrets, audio, waveforms or GPS data. Shared-memory indexes are rebuilt locally, and committed WAL measurements are checkpointed in private copies before extraction.

Some app versions or backups may omit the Withings databases or use an unsupported schema. The bridge reports an error rather than deliberately publishing an incomplete replacement. Modern `Manifest.db` backups are supported; legacy `Manifest.mbdb` backups are not.

The exported iCloud Drive folder still contains personal health information. Keep both the original backup and the export folder under your control, outside this source repository.
