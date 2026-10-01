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