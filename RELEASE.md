# Release Checklist

WhisperNote releases should be signed and notarized before attaching builds to GitHub Releases.

## Prerequisites

- Apple Developer ID Application certificate.
- Apple notary credentials configured for `xcrun notarytool`.
- Valid RecordKit license for distribution.
- Version updated in `MARKETING_VERSION` and `SettingsView.swift` changelog.

## Build

```bash
xcodebuild -scheme WhisperNote -configuration Release -archivePath build/WhisperNote.xcarchive archive
```

Export or copy the built `.app` from the archive, then sign it with your Developer ID if Xcode did not sign it during archive.

## Package

```bash
ditto -c -k --keepParent WhisperNote.app WhisperNote-macOS.zip
```

## Notarize

```bash
xcrun notarytool submit WhisperNote-macOS.zip --keychain-profile <profile-name> --wait
xcrun stapler staple WhisperNote.app
```

Upload the notarized `.zip` or a signed `.dmg` to a GitHub Release tagged with the app version.
