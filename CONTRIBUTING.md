# Contributing

Thanks for taking the time to contribute!

## Setup

1. Install Flutter 3.47.7 (stable). On Linux or WSL, `./setup_linux.sh`
   installs it together with the build tools.
2. Start Tor (Tor Browser, the Tor service or Orbot).
3. Fetch the packages and run the app:

    ```bash
    flutter pub get
    flutter run
    ```

Windows builds need Developer Mode and the C++ ATL component of the Visual
Studio Build Tools.

## Tests

```bash
flutter analyze
flutter test
```

The tests need neither network access nor Tor.

## Guidelines

- All network access goes through `lib/core/tor.dart`; `test/network_guard_test.dart` enforces this.
- User-visible texts use `tr('…')` and need a German translation in `lib/i18n_de.dart`.
- Changes to `sync.json`, the delivery format or the cryptography must update `WHITEPAPER.md`.
- Never commit keys, passwords, keystores or real group data.

## Releases

Pushing a tag `vX.Y.Z` that matches `pubspec.yaml` builds, signs and publishes
all platforms via GitHub Actions. Required secrets are listed in the README.
