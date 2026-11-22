# Build and download the desktop apps on GitHub

The repository has separate, manually started workflows for each desktop app. No signing certificates, Apple passwords, personal backups or iCloud credentials are needed by these workflows.

## Start a build

1. Open the [repository's Actions tab](https://github.com/rworne/withings-local-bridge/actions).
2. Choose **Build Mac Bridge** or **Build Windows Bridge** in the left sidebar.
3. Click **Run workflow**, leave the branch set to `main`, then click the green **Run workflow** button.
4. Open the newly created run and wait for its green completion check.
5. Scroll to **Artifacts** at the bottom of the run's summary and click the platform's download.

The Actions artifact download is itself a ZIP. Inside it is the platform-specific ZIP to distribute. Artifact downloads generally require signing into GitHub with access to the repository. These build artifacts are retained for 30 days; use a GitHub Release for ongoing public downloads.

### Mac

**Build Mac Bridge** tests the Swift package and exchange compatibility, builds the app and optional command-line tool on an Apple silicon runner with Xcode 26 or newer, verifies the app's ad-hoc signature, and creates:

```text
WithingsHealthBridge-Mac-<version>-arm64.zip
```

The inner ZIP preserves the Mac app's executable permissions and bundle structure. Extract it and move **Withings Health Bridge.app** to Applications. The current build is for M-series Macs running macOS 13 or later. It does not include an Intel build.

**Signing:** the app is ad-hoc signed so its executable is valid for local use. It is not Developer ID signed or notarized, and no Apple signing secrets are uploaded to GitHub. If macOS blocks opening the downloaded app, try opening it once, then use **System Settings → Privacy & Security → Open Anyway** and confirm. See Apple's [instructions for opening an unverified app](https://support.apple.com/en-us/102445).

### Windows

**Build Windows Bridge** runs synthetic backup/export tests, builds a portable Windows application and checks that the packaged UI, encryption and SQLite libraries initialize. It creates:

```text
WithingsHealthBridge-Windows-0.1.0-x64.zip
```

Extract the entire inner ZIP and run **Withings Health Bridge.exe**. Keep its `_internal` folder and other supporting files together with it. Users do not need Python or .NET installed. The package is unsigned and is intended for 64-bit Windows 11. See the [Windows guide](../Windows/README.md).

## Publish desktop downloads on the Releases page

Actions performs the builds; Releases provides a public download page associated with a version.

1. Download the successful Mac and Windows build artifacts and extract their outer ZIPs.
2. In the repository, open **Releases**, then **Draft a new release**.
3. Choose or create a version tag and select the tested commit or branch. Add a title and release notes. The Mac and Windows app version numbers may differ; name each attached ZIP accurately.
4. Attach the **inner platform ZIPs**, not their extracted executable files or the Actions wrapper ZIPs.
5. Publish the release. For a test release, select the pre-release option.

Public-repository release assets can be downloaded without creating a GitHub account. Creating a release does not automatically run these manual build workflows. Build the intended source revision first and confirm the run's commit matches the release target. The Mac ZIP includes a `BUILD-INFO.txt` recording its source commit.

References: [GitHub workflow dispatch](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow), [workflow artifacts](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts), and [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).

## iPhone app

The existing **Build and Test** workflow checks an unsigned iOS build. It does not produce an installable IPA or upload to TestFlight. iPhone distribution still requires an appropriate signing/distribution route. A desktop GitHub release can include the TestFlight invitation link separately; these desktop workflows do not change the iPhone app or its signing.
