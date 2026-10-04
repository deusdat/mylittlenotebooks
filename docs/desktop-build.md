# Desktop builds

The app is desktop-first. This file records the exact prerequisites and commands
for all three desktop targets, because two of them cannot be built from a single
developer machine — which is why CI (`.github/workflows/ci.yml`) is the actual
verification for AC20, not a local build.

No code generation is involved. There is no `build_runner`, no `.g.dart`, and no
`part` directives in `lib/`.

## Prerequisites

| Target | Needs |
|---|---|
| macOS | Xcode with the command line tools, CocoaPods (`sudo gem install cocoapods`) |
| Windows | Visual Studio 2022 with the "Desktop development with C++" workload |
| Linux | `clang cmake ninja-build libgtk-3-dev pkg-config liblzma-dev` |

Verify the host with `flutter doctor -v`.

## Commands

```sh
flutter pub get
flutter analyze
flutter test

flutter build macos            # --debug for a faster loop
flutter build windows
flutter build linux --release
```

Run against a device or the desktop shell:

```sh
make run_desktop               # flutter run -d macos
```

## What each platform stores where

`shared_preferences` backs the one persisted panel value
(`nav_panel.collapsed`):

| Platform | Location |
|---|---|
| macOS | `NSUserDefaults` |
| Windows | roaming `AppData` |
| Linux | `XDG_DATA_HOME` |

To reset the panel to its expanded default, delete that key or remove the app's
preferences file. Notebook data is in-memory only, so a relaunch always returns
to the three seeded notebooks — that is expected, not data loss.

## Verifying behaviour is identical across platforms

Presentation depends on the **window width**, never on the platform, so the way
to compare is to resize windows to the same logical width and confirm the panel
matches:

| Window width | Panel |
|---|---|
| ≥ 1600 px | 320 px |
| 900–1600 px | 20% of the window |
| < 900 px | 56 px rail |

The only platform-conditional code in the app is the collapse shortcut modifier
(`Cmd+B` on Apple platforms, `Ctrl+B` elsewhere). Nothing about the layout varies.

## AI endpoint tokens (the keychain)

AI endpoint tokens are stored with `flutter_secure_storage`, **not** in
`shared_preferences` or the ObjectBox file. Per platform:

| Platform | Mechanism | Build/runtime need |
|---|---|---|
| macOS | Keychain (legacy; data-protection keychain disabled) | none |
| Windows | Credential Manager / DPAPI | none |
| Linux | libsecret | `libsecret-1-dev` to build; `libsecret-1-0` + a keyring (`gnome-keyring`/`kwallet`) to run |

**macOS trap.** If the data-protection keychain is used while the app also
carries an App Group, a token can appear to write successfully and never
actually land unless the App Group is in `keychain-access-groups` — a silent
failure. This app disables the data-protection keychain
(`MacOsOptions(usesDataProtectionKeychain: false)`) and so needs no extra
entitlement. Verify on a real run: write a token, restart, read it back. No
automated test can cover it. See [`settings-conventions.md`](./settings-conventions.md).
