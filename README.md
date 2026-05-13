# Orical IMEI Tag

Cross-platform Flutter app that captures a phone's IMEI / IMEI2 / EID / Serial and renders them as on-screen CODE128 barcodes, laid out to match iOS's built-in `Settings → General → About → Device Info` screen. Sideload-only, fully offline, no network code.

## Use case

Warehouse / fulfillment-center workers need to produce a scannable IMEI from each phone they are processing, in a form bound to the physical device so a worker cannot present a screenshot of someone else's phone at a checkpoint. This app provides three input paths (two automatic on Android, manual+attestation on iOS) and seals the captured value so it cannot be edited later by anyone — including the admin — without a destructive factory reset.

## Capture modes

The mode is chosen once at first launch and is part of the sealed state. Changing modes requires factory-resetting the app and re-provisioning the device.

### 1. Accessibility scrape (Android, recommended)

- One-time setup: enable the bundled `AccessibilityScrapeService` in `Settings → Accessibility → Installed services`. Android shows its standard warning about what an accessibility service can see — that warning is required by design and cannot be hidden.
- Per capture: the app launches `Settings → About` via intent. The accessibility service reads visible text from the Settings page (its `android:packageNames` is restricted to settings packages — the service cannot observe any other app), filters with the IMEI regex + Luhn check, and stores the first one or two valid IMEIs it sees.
- Throughout normal use the service does nothing — it only collects text while a capture is actively in progress, and disables itself again afterwards.

### 2. Screenshot + on-device OCR (Android, fallback)

- No accessibility setup ever.
- Per capture: app starts a foreground `MediaProjection` service. The standard Android *"Start recording or casting?"* system dialog appears — this dialog cannot be suppressed; Google enforces user consent every time.
- After the user taps *Start now*, the app launches `Settings → About`, waits ~1.8 s for the page to render, captures a single frame, encodes it as JPEG to private cache storage, then stops projection.
- Flutter side runs offline OCR (Google ML Kit text recognition, packaged in the APK) over the saved JPEG, extracts 15-digit Luhn-valid IMEI patterns, and deletes the JPEG.

### 3. Manual entry + match attestation (iOS, and Android fallback)

- iOS has no equivalent of either Android capture path. No app on iOS — first-party, sideloaded, MDM-deployed, or enterprise-signed — can read another app's screen or any non-resettable hardware identifier. So iOS uses the manual path: an IT operator reads each value off the phone's own `Settings → About` (or `*#06#`), types it into the app, and ticks an attestation checkbox affirming every value matches.
- Auto-validation: the form runs Luhn-15 over the typed IMEI before allowing the form to advance, catching typos. Also available as a third option on Android if the customer doesn't want accessibility or projection.

## Immutability

After sealing on initial provisioning, stored values are **immutable**:

- There is no "edit" feature in the admin pane.
- Admin can **re-capture** (auto modes only — re-runs the configured capture path against this device's hardware, so substitution is impossible — the captured value is whatever the OS itself shows on this phone).
- Admin can **re-verify** to refresh the `Last verified` stamp without changing values.
- Admin can **factory reset**, which wipes all stored values, passkey, recovery code, and capture-mode choice. The next launch goes back to the capture-mode chooser.

This means a warehouse associate, even if they obtain the admin passkey, cannot type in a different IMEI to make a phone present as a different device. They can only re-read from hardware or wipe everything.

## What this does *not* protect against

The threat model addressed is **on-device value substitution** by someone with admin-passkey access. The following threats are explicitly out of scope:

- **Photographing the displayed barcode with another camera.** Even without screenshot capability, a person can point a second phone at the screen and capture the barcode visually. Real mitigations require a checkpoint workflow that does not trust a static, app-rendered barcode — e.g., dial `*#06#` directly at the checkpoint, or use a server-issued time-bound nonce embedded in the barcode that the checkpoint scanner can validate. Neither is provided here.
- **Rooted / jailbroken devices.** Anything on-device can be tampered with given root.
- **The iOS manual path** depends on the IT operator typing the *correct* IMEI at provisioning. There is no way to verify this against hardware on iOS, period; manual + attestation is the strongest assertion the platform allows.

## Build

This is a vanilla Flutter project — the repo only contains the customized source files. Platform boilerplate (Gradle wrapper, Xcode project, launch screens, icons, etc.) is filled in by `flutter create`, which will not overwrite the customized files.

```bash
flutter create --org com.orical --project-name orical_imeitag .
flutter pub get
```

### Android APK

```bash
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`. Install with *Install from unknown sources*.

### iOS IPA

```bash
flutter build ipa --release   # macOS + Xcode 15 required
```

Output: `build/ios/ipa/orical_imeitag.ipa`. Distribute via Apple Configurator 2, AltStore, or your Apple Business Manager / enterprise account. **This build is not intended for App Store submission.**

## Source layout

```
pubspec.yaml                                              Flutter deps (incl. ML Kit OCR)
lib/main.dart                                             Full app: chooser, setup, capture, display, admin
android/app/src/main/AndroidManifest.xml                  Permissions, accessibility service, projection service
android/app/src/main/res/xml/accessibility_service_config.xml   Scope-restricted accessibility config
android/app/src/main/res/values/strings.xml               App + accessibility service strings
android/app/src/main/kotlin/com/orical/imeitag/
    MainActivity.kt                                       MethodChannel for capture commands
    AccessibilityScrapeService.kt                         Settings-only text reader
    ScreenCaptureService.kt                               MediaProjection foreground service
ios/Runner/Info.plist                                     iOS bundle config
analysis_options.yaml                                     Flutter lints
```

## Security knobs

- Admin passkey: stretched with SHA-256 over 120,000 iterations + per-device 16-byte salt. Stored in EncryptedSharedPreferences (Android) / Keychain (iOS).
- One-time recovery code: shown once at provisioning. Hashed with independent salt. **No hardcoded master passkey, no annual expiration, no developer backdoor.**
- Failed-attempt lockout: 5 wrong tries → 30 s cooldown, doubling each subsequent failed try up to ~32 min.
- No `INTERNET` permission requested. No `READ_PHONE_STATE`. No `READ_BASIC_PHONE_STATE`.
