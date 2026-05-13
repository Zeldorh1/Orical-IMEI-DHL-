# Orical IMEI Tag

Cross-platform Flutter app that holds a phone's IMEI / IMEI2 / EID / Serial and renders them as on-screen CODE128 barcodes, laid out to match iOS's built-in `Settings → General → About → Device Info` screen. Sideload-only, fully offline, no network code, no analytics, no telemetry.

## What it's for

Warehouse / fulfillment-center workflow: each phone, on intake, gets provisioned once by IT. The operator types the IMEI from the device's own `*#06#` / `Settings → About` screen, ticks an attestation that every value matches, and sets an admin passkey. The values are then **sealed** — no one (including the admin) can edit them afterwards. The app shows the barcode on demand for checkpoint scanning. The only way to change a stored value is to factory-reset and re-provision, which requires the admin passkey.

Concretely, the threat this addresses is on-device value substitution: a warehouse associate, even one who somehow obtains the admin passkey, cannot type in a different IMEI to make a phone present as a different device at checkout. The passkey unlocks "wipe and start over," not "edit."

## Flow

1. **First launch.** App walks operator through 3 steps:
   - Enter IMEI (required, Luhn-15 validated), IMEI2, EID, MEID, Serial, Model.
   - Verify match: side-by-side comparison against `*#06#` with an attestation checkbox.
   - Set admin passkey. One-time recovery code is generated and shown — once only.
2. **Normal use.** App opens straight to the barcode screen. Brightness auto-bumps to max. Tap "Verify against `*#06#`" for a reminder of the verify procedure.
3. **Admin access.** Long-press the "Device Info" title → enter passkey or recovery code. Admin can:
   - **Within 15 minutes of initial seal**, edit values once (typo-fix window). Saving re-runs the verify + attest step. The window does not extend when you edit; once the 15 minutes from the *original* seal elapse, the edit option disappears forever.
   - Change the admin passkey.
   - Factory-reset (wipes everything; next launch starts a fresh provisioning).
   
   There is no edit-values option after the typo-fix window closes — by design.

## What it does *not* do

Stated up front so the security pitch isn't oversold:

- **Does not bind the stored IMEI to device hardware.** The operator types the value during provisioning. The defense against substitution rests on (a) the operator doing the attestation honestly at provisioning and (b) values being immutable after sealing. If the wrong IMEI is typed at step 1 and the attestation is ticked anyway, the wrong IMEI gets sealed.
- **Does not prevent photographing the displayed barcode.** Someone can point a second camera at the screen and capture the barcode visually; the resulting image can be displayed on a different phone. The defense against this is workflow, not software — e.g., the checkpoint also dials `*#06#` directly, or visually inspects that the operator is holding one phone, not stacking two.
- **Does not survive a rooted/jailbroken device.** Anything on-device can be tampered with given root.

## Build

This repo contains the customized source. Platform boilerplate (Gradle wrapper, Xcode project, launch screens, icons) is filled in by `flutter create`, which does not overwrite the customized files.

```bash
flutter create --org com.orical --project-name orical_imeitag .
flutter pub get
```

### Android APK

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`. Install with *Install from unknown sources*. The signed APK does not expire — once on the device it runs indefinitely.

### iOS IPA

```bash
flutter build ipa --release   # macOS + Xcode 15 required
```

Output: `build/ios/ipa/orical_imeitag.ipa`. Distribute via Apple Configurator 2, AltStore, or your Apple Developer account. **Not intended for App Store submission.** The IPA must be re-signed when the distribution certificate expires (annually for individual / 3 years for enterprise).

## Source layout

```
pubspec.yaml                                              Flutter dependencies (5 small ones, no native code)
lib/main.dart                                             Full app
android/app/src/main/AndroidManifest.xml                  Minimal manifest, single activity
android/app/src/main/res/values/strings.xml               app_name
android/app/src/main/kotlin/com/orical/imeitag/MainActivity.kt   Plain FlutterActivity
ios/Runner/Info.plist                                     iOS bundle config
analysis_options.yaml                                     Flutter lints
```

## Security model

- **Admin passkey** is stretched with SHA-256 over 120,000 iterations + per-device 16-byte salt. Stored in EncryptedSharedPreferences (Android) / Keychain (iOS). Only used to authorize factory reset or passkey rotation.
- **One-time recovery code** is shown once at provisioning, hashed with independent salt. No hardcoded master passkey, no annual expiration, no developer backdoor.
- **Failed-attempt lockout.** 5 wrong tries → 30 s cooldown, doubling each subsequent failed try up to ~32 min.
- **Stored values are immutable after the typo-fix window closes.** A 15-minute window from the moment of initial sealing allows the admin to correct typos. Editing inside the window re-runs the verify + attest step. The window does not extend on edit. After it closes, the edit path is gone from the UI and no codepath can reach it. The only way to change a stored value is `Store.wipe()` (factory reset), which clears the passkey, recovery, and values together. Re-provisioning requires the operator to attest the new values against `*#06#` again.
- **No network code.** No `INTERNET` permission requested on Android, no networking entitlements on iOS. The app is fully air-gapped after install.
- **No device-identifier permissions.** No `READ_PHONE_STATE`, no `READ_BASIC_PHONE_STATE`, no Privacy Sensitive Info Type declarations. The OS will not grant or even prompt for these.

## Maintenance

- **The code itself does not need updates.** Form input, SHA-256, Code128 rendering, Keychain/EncryptedSharedPreferences — all stable for 10+ years and counting.
- **Android.** Once installed, the signed APK runs indefinitely. The only thing that would ever force an update is the buyer wanting a new feature.
- **iOS.** The IPA must be re-signed when the Apple distribution certificate expires. With an Apple Developer Enterprise certificate that's every 3 years; with a regular Apple Developer Program certificate that's every year. Re-signing requires Xcode and the original signing identity — typically a half-day operation, no code changes.
- **Flutter SDK drift.** Roughly every 3-5 years a full rebuild against current Flutter + Xcode may be needed if the iOS deployment target gets too old to install on new iPhones. Usually 0–10 lines of code touched.
