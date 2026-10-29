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

## Notes

- Local builds are stamped `<git describe>-local` and never check for updates on their own (a manual check still
  works). Debug builds never update.
- An install in a folder the user can't write to (for example a root-owned `/Applications` copy) reports that it
  can't update itself, and a manual check opens the releases page instead.
- Local release without CI: see [`SHIPPING.md`](../SHIPPING.md).
