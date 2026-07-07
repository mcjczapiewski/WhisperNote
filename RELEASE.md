# Release Checklist

WhisperNote ships as a free, **unsigned** build — no Apple Developer Program account required.
Users accept a one-time Gatekeeper warning on first launch instead.

## Prerequisites

- Version updated in `MARKETING_VERSION` (`WhisperNote.xcodeproj/project.pbxproj`) and the
  fallback version in `SettingsView.swift`.
- `CHANGELOG.md` updated. The packaged app bundles this same file for the in-app changelog.

## Build

```bash
xcodebuild -scheme WhisperNote -configuration Release -derivedDataPath build
```

The `.app` bundle is under `build/Build/Products/Release/WhisperNote.app`. (`swift run` runs the
app but doesn't produce a distributable bundle — use `xcodebuild` for releases.)

## Package

Wrap it in a `.dmg` (`brew install create-dmg && create-dmg WhisperNote.app`) or a plain zip:

```bash
ditto -c -k --keepParent WhisperNote.app WhisperNote-macOS.zip
```

Attach the `.dmg`/`.zip` to a GitHub Release tagged with the app version.

## Document the Gatekeeper workaround

Because the build is unsigned, macOS quarantines it on first launch. The release notes and
`README.md` should tell users to either:

- Right-click the app → **Open** → **Open** (this offers an Open button a normal double-click
  doesn't), or
- Run once: `xattr -dr com.apple.quarantine /Applications/WhisperNote.app`

## Optional: signing and notarization

If you have an Apple Developer ID Application certificate and notary credentials, you can instead
sign the archive during `xcodebuild archive`, then notarize:

```bash
xcrun notarytool submit WhisperNote-macOS.zip --keychain-profile <profile-name> --wait
xcrun stapler staple WhisperNote.app
```

This removes the Gatekeeper warning for users but isn't required to publish a release.
