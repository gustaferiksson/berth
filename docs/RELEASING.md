# Releasing Berth

Berth ships as a Developer ID signed and notarized app through GitHub Releases and a Homebrew cask. Installed
copies update themselves: `AppUpdater` checks `releases/latest` on launch, every 24 hours and on wake, downloads
`Berth-<version>.zip`, verifies its code signature (team `82K3YC8HVF`, identifier `dev.gustaf.berth`), stages it
next to the installed app and swaps it in on quit or on "Install Berth <version> and Relaunch".

## How the pipeline works

`.github/workflows/release.yml` runs on a `v*` tag and calls the shared `gustaferiksson/macos-release` workflow:

```
git tag v0.2.0  →  push  →  [release.yml]
                              ├─ build.sh         (Developer ID, hardened runtime, timestamp)
                              ├─ notarytool       (Apple ID + app-specific password)
                              ├─ ditto → Berth-0.2.0.zip
                              ├─ gh release create (attaches the zip)
                              └─ bump Casks/berth.rb in gustaferiksson/homebrew-tap
```

The tag sets the version (`v0.2.0` → `CFBundleShortVersionString` `0.2.0`); the build number is the Actions run
number. The updater depends on three things staying in lockstep: the repo `gustaferiksson/berth`, the tag format
`v<version>`, and the asset name `Berth-<version>.zip` (the workflow's `name: Berth`).

## One-time setup

1. Create the GitHub repo `gustaferiksson/berth` and push `main`. Releases must be public for the updater to see them.
2. Add `Casks/berth.rb` to `gustaferiksson/homebrew-tap` (copy an existing cask, placeholder `version`/`sha256`).
   The workflow only rewrites those two lines and fails if the file is missing.
3. Add the secrets in the berth repo (the same values as the other Developer ID apps):

   ```sh
   gh secret set APPLE_CERT_P12 < <(base64 -i ~/Downloads/DeveloperID.p12)
   gh secret set APPLE_CERT_PASSWORD
   gh secret set NOTARY_APPLE_ID
   gh secret set NOTARY_PASSWORD
   gh secret set TAP_GITHUB_TOKEN
   ```

   The preflight step fails the run if any is empty, and the tag must be on `main`.

## Every release

```sh
git tag v0.1.0 && git push origin v0.1.0
gh run watch
```

Existing installs pick it up within a day, or immediately via Berth ▸ Check for Updates….

## Berth Remote (iOS)

The same tag also ships Berth Remote as an Ad Hoc IPA, installable over the air on registered devices only:

```
git tag v0.2.0  →  push  →  [release.yml]
                              ├─ release   (the Mac pipeline above)
                              ├─ ios       package-ios.sh: archive BerthRemote (Apple Distribution, profile
                              │            "Berth Remote Ad Hoc"), export with Signing/ExportOptions-AdHoc.plist
                              │            → BerthRemote.ipa + manifest.plist
                              └─ publish   (after both) gh release upload BerthRemote-0.2.0.ipa + manifest.plist,
                                           deploy pages/ + IPA + manifest to GitHub Pages
```

Install page: <https://gustaferiksson.github.io/berth/> (open it in Safari on the device, tap Install). Only the
latest IPA is installable from Pages; older ones stay attached to their releases. The app reads the Pages
`manifest.plist` on launch and at most once per 24 hours on foreground, and shows "Install Berth Remote <version>"
when its `bundle-version` is newer. Debug builds and `-local` builds never offer an update.

If `ios` or `publish` fails after `release` succeeded, fix it and use "Re-run failed jobs"; phones see no update until
Pages is deployed.

### One-time setup

1. Developer portal: register an explicit App ID `dev.gustaf.berth.remote` (no capabilities) and make sure every
   iPhone or iPad is registered under Devices.
2. Profiles > +: **Ad Hoc** for `dev.gustaf.berth.remote` with the Apple Distribution certificate and all devices,
   named exactly `Berth Remote Ad Hoc`. Download it.
3. 1Password: add `Berth_Remote_Ad_Hoc.mobileprovision` next to Crew's `AppleDistribution.p12` and its password (the
   same Apple Distribution certificate signs both apps).
4. Secrets in the berth repo:

   ```sh
   gh secret set IOS_DIST_P12 < <(base64 -i AppleDistribution.p12)
   gh secret set IOS_DIST_P12_PASSWORD
   gh secret set IOS_ADHOC_PROFILE < <(base64 -i Berth_Remote_Ad_Hoc.mobileprovision)
   ```

   The `ios` job fails its preflight if any is empty.
5. Settings > Pages > Source: **GitHub Actions**. Settings > Environments > `github-pages` > Deployment branches and
   tags: add a tag rule `v*`, or the tag-triggered deploy is refused.

To build the IPA locally, put the profile at `.secrets/Berth_Remote_Ad_Hoc.mobileprovision` (gitignored) and run
`./package-ios.sh` with the Apple Distribution identity in the login keychain. It is stamped `<git describe>-local`
unless `VERSION` is set.

### Adding a device

Register the device in the portal, edit `Berth Remote Ad Hoc` to include it, download it again, replace the file in
1Password, update `IOS_ADHOC_PROFILE` and tag a release. Devices that already have the app are unaffected; the new
one installs from the Pages link.

### Device UDIDs are public

The IPA embeds the Ad Hoc profile, which lists every registered device's UDID, and it is downloadable by anyone from
Pages and the releases. That is the cost of public OTA hosting.

## Notes

- Local builds are stamped `<git describe>-local` and never check for updates on their own (a manual check still
  works). Debug builds never update.
- An install in a folder the user can't write to (for example a root-owned `/Applications` copy) reports that it
  can't update itself, and a manual check opens the releases page instead.
- Local release without CI: see [`SHIPPING.md`](../SHIPPING.md).
