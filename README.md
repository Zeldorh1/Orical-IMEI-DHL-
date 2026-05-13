# Orical IMEI Tag

Cross-platform Flutter app that renders a phone's IMEI / IMEI2 / EID / MEID / Serial as on-screen CODE128 barcodes, in a layout that mirrors iOS's built-in `Settings → General → About → Device Info` screen. Sideload-only, fully offline, no network code.

## What it does

- First launch: an IT operator types the device's values (IMEI, IMEI2, EID, MEID, Serial, Model), goes through a mandatory "verify match" attestation step (compare each value against `*#06#` on the same phone), and sets an admin passkey. A one-time recovery code is shown and must be stored externally.
- Every launch after that: the device boots straight into a locked white display at 100% brightness, with CODE128 barcodes for each stored value and the "Last verified" timestamp at the bottom.
- Anyone can tap "Verify against `*#06#`" to surface the comparison instructions — no passkey needed. Re-verifying (which updates the timestamp) requires the admin passkey.
- Admin access: long-press the "Device Info" title → passkey or recovery code → edit values, re-verify, change passkey, or factory-reset.

## What it deliberately does NOT do

- **Does not auto-read the device's hardware IMEI.** Modern Android (API 29+) and iOS (any version) do not expose IMEI to non-system / non-MDM apps. Anything advertising otherwise either depends on Device Owner provisioning, requires root, or is misrepresenting what it can do.
- **Does not block screenshots.** This is intentional: anyone downstream of the operator must be able to take a screenshot of the displayed barcode and compare it to `*#06#` on the device, as an after-the-fact audit. Trade-off in favor of verifiability.
- **Does not phone home.** No network permissions, no analytics, no remote license check. Provisioning is fully local.

## Verification model

Because the OS does not let a sideloaded app read the real IMEI, the app cannot automatically prove that the typed IMEI matches the chassis. Two layers of checking are in place:

1. **Automatic — Luhn checksum** at entry time. Catches typos. A 15-digit IMEI whose check digit doesn't match the first 14 is rejected before the form will advance.
2. **Manual — human attestation** before sealing. The operator must read each value off the same phone's `*#06#` or `Settings → About` screen, then tick a checkbox affirming every value matches. The current attestation date is shown on the locked display so any downstream party can see when the device was last verified.

If you need *cryptographic* verification (real IMEI read from the OS and compared automatically), that requires Android **Device Owner** provisioning via MDM, which is a different distribution model (factory-reset / QR enrollment instead of sideload). Not implemented in this branch.

## Build

This is a vanilla Flutter project. You will need:

- Flutter SDK ≥ 3.19
- Android Studio (for Android build) or Xcode 15+ (for iOS build)

### One-time bootstrap

The repo only contains the customized source files (`pubspec.yaml`, `lib/main.dart`, the Android manifest, the Kotlin `MainActivity`, the iOS `Info.plist`). The platform boilerplate (Gradle wrapper, Xcode project, launch screens, icons) is filled in by `flutter create`, which will *not* overwrite the customized files:

```bash
flutter create --org com.orical --project-name orical_imeitag .
flutter pub get
```

### Android APK (sideload-ready)

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk` — drop on a download page, install with "Install from unknown sources" on the target device.

### iOS IPA (sideload-ready)

```bash
flutter build ipa --release
```

Output: `build/ios/ipa/orical_imeitag.ipa` — install via Apple Configurator 2, AltStore, or your enterprise distribution flow. **iOS App Store distribution is not the target for this build.**

## Source layout

```
pubspec.yaml                                         Flutter deps
lib/main.dart                                        Entire app (setup, verify, display, admin)
android/app/src/main/AndroidManifest.xml             No special permissions
android/app/src/main/kotlin/com/orical/imeitag/MainActivity.kt
ios/Runner/Info.plist
analysis_options.yaml
```

## Adjusting the verification level

The IMEI entry validator lives in `luhn15()` in `lib/main.dart`. Add a TAC table and a `tacMatchesModel()` check inside `_EntryStepState._submit()` to fail provisioning when the IMEI's first 8 digits don't correspond to the actual device's `Build.MODEL` / iOS hardware identifier. Asks: ~1 MB TAC table dependency, plus the `device_info_plus` package.

## License / passkey

- Admin passkey is set per device at provisioning. Stretched with SHA-256 over 120,000 iterations + 16-byte random salt. Stored in EncryptedSharedPreferences (Android) / Keychain (iOS).
- One-time recovery code is generated and shown once at provisioning. Hashed with an independent salt. **There is no hardcoded master passkey, no annual expiration, no developer backdoor** — each deployment is a closed loop owned by the customer.
