# Ecash App Release Process

## Release Candidates

- Create release branch (if new major/minor): `git checkout -b releases/vX.Y`
- Run the release script: `./scripts/release.sh X.Y.Z-rc.N`
  - Updates `pubspec.yaml` to `version: X.Y.Z-rc.N+VCODE`
  - Updates `rust/ecashapp/Cargo.toml` to `version = "X.Y.Z-rc.N"`
  - Updates `rust/ecashapp/Cargo.lock`
  - Updates `android/app/build.gradle.kts` to production package ID
  - Commits and creates signed tag `vX.Y.Z-rc.N`
- Verify build: `just build-linux` and `flutter analyze`
- Push: `git push upstream releases/vX.Y && git push upstream vX.Y.Z-rc.N`
- Verify GitHub release created with APK, AppImage and DMG
- Verify the iOS build reached TestFlight (see [iOS / TestFlight](#ios-testflight))

## Final Release

- On release branch: `git checkout releases/vX.Y`
- Add F-Droid changelog (optional, can also be done via release script prompt):
  - `metadata/en-US/changelogs/VCODE.txt` (max 500 chars)
- Run the release script: `./scripts/release.sh X.Y.Z`
  - Updates `pubspec.yaml` to `version: X.Y.Z+VCODE`
  - Updates `rust/ecashapp/Cargo.toml` to `version = "X.Y.Z"`
  - Updates `rust/ecashapp/Cargo.lock`
  - Updates `android/app/build.gradle.kts` to production package ID
  - Adds appstream release entry to `linux/appstream/org.fedimint.app.appdata.xml`
  - Prompts for F-Droid changelog (creates `metadata/en-US/changelogs/VCODE.txt`)
  - Commits and creates signed tag `vX.Y.Z`
- Push: `git push upstream releases/vX.Y && git push upstream vX.Y.Z`
- Verify GitHub release created with APK, AppImage and DMG
- Verify the iOS build reached TestFlight (see [iOS / TestFlight](#ios-testflight))

## Post-Release

- Add branch protection to `releases/vX.Y` (first release only)
- PR the appstream release entry cherry-pick to `releases/vX.Y`
- PR to bump master to next alpha:
  - `pubspec.yaml`: `version: X.(Y+1).0-alpha`
  - `rust/ecashapp/Cargo.toml`: `version = "X.(Y+1).0-alpha"`
  - Include the appstream release entry cherry-pick

## iOS / TestFlight

Pushing a `v*` tag runs `.github/workflows/ios-release.yml`, which builds the
Rust static library for `aarch64-apple-ios`, archives and signs the app, exports
an `.ipa`, and uploads it to App Store Connect. There is nothing to attach to the
GitHub release page: an App Store-signed `.ipa` only installs through TestFlight,
so the `.ipa` and its dSYMs are kept as workflow artifacts instead.

The workflow checks every signing secret before it starts building, so a tag
either produces a TestFlight build or fails immediately — it never goes green
having skipped the upload.

Version numbers come from the same `pubspec.yaml` line as Android:

- `CFBundleVersion` is the version code (`0.11.0-rc.1+110001` -> `110001`).
- `CFBundleShortVersionString` is the version with the pre-release suffix
  stripped (`0.11.0-rc.1` -> `0.11.0`), because App Store Connect rejects a
  marketing version that is not plain `X.Y.Z`.

Because the version code already increases across a release train, RCs and the
final release can share a marketing version without App Store Connect
complaining.

After the upload, TestFlight distribution is manual: the build has to finish
processing, then be assigned to a tester group. External testing needs Apple's
review; internal testing does not.

The signing credentials, and the one-time Apple Developer Program setup needed
before the first tagged iOS release, are held outside this repository. The
workflow itself is the reference for which secrets it reads.

## F-Droid Testing

Before submitting to F-Droid, test the build locally:

```bash
# Scan APK for Google Play Services dependencies
just scan-apk
```

## Version Code Reference

The version code (VCODE) is calculated by `scripts/release.sh` and included in `pubspec.yaml` after a `+` suffix. This is required for F-Droid auto-update detection.

- RC: `VCODE = major*1000000 + minor*10000 + patch*100 + rc_num`
- Final: `VCODE = major*1000000 + minor*10000 + patch*100 + 90`

Examples:
- `0.5.0` -> `version: 0.5.0+50090`
- `0.5.0-rc.1` -> `version: 0.5.0-rc.1+50001`
- `1.0.0` -> `version: 1.0.0+1000090`
