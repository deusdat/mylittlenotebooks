# mylittlenotebooks

A local-first Flutter research assistant, in the mold of NotebookLM: collect
source documents into **notebooks**, then work with that material.

Currently this repository contains:

- **The application shell** — a navigation panel plus a centre content page,
  with notebook drill-down and back navigation. See
  [`specs/1790815734133-add-menu/`](./specs/1790815734133-add-menu/).
- **The publication data layer** — durable notebooks, publications, chunks, and
  an embedded vector store with scoped semantic search. See
  [`specs/1790958509972-publication-data-layer/`](./specs/1790958509972-publication-data-layer/).
- **Notes** — add, read, edit, embed, and sync user-authored notes, plus a
  note-scoped retrieval path and the chat panel's display groundwork. See
  [`specs/1791121654000-add-notes/`](./specs/1791121654000-add-notes/).

The note embedding stack (`nomic-embed-text-v1.5` → ONNX → `onnxruntime`) is
active. The model is a **build artifact** (~131 MB, fetched by
`make install_model`), not tracked in git; the tokenizer is committed. See
[`docs/data-conventions.md`](./docs/data-conventions.md#the-model-asset-is-a-build-artifact).
The publication sources UI is still to come.

## Setup

Requires Flutter 3.47.0 / Dart 3.13.0.

```bash
flutter pub get
make setup   # = make install_objectbox + make install_model — once per checkout
```

`make install_model` fetches the embedding model (~131 MB) from a pinned
Hugging Face revision into `assets/models/` and verifies its SHA-256. It is
required before `flutter run`/build, because the asset is declared in
`pubspec.yaml` and Flutter fails a build when a declared asset is missing.

### `make install_objectbox` is not optional

Host-side `flutter test` cannot open an ObjectBox store until the native library
is present. `objectbox_flutter_libs` bundles it for *apps*; it does not cover the
Dart VM that runs tests.

Without this step **every test fails at load** with a `dlopen` error naming
`libobjectbox.dylib`, which reads as a broken suite rather than a missing setup
step. CI runs the same command.

`lib/*.dylib` and `download/` are gitignored — they are per-machine artifacts.

`make install_objectbox` fetches `install.sh` from the **tag matching the pinned
version**, not from `main`. The script on `main` hardcodes a 6.0.0-beta C
library, which would sit alongside our 5.3.2 Dart bindings — and the script's
own header warns that a mismatch produces "obscure memory bugs" rather than an
error. The version is read from `pubspec.yaml`, so it cannot drift.

## CocoaPods / SwiftPM on iOS and macOS

CocoaPods is in **maintenance mode**, not removed: its registry goes read-only
on **2 December 2026**, and existing pod versions stay available after that, so
builds keep working. Flutter 3.44+ (we are on 3.47) defaults to SwiftPM and falls
back to CocoaPods for plugins without a `Package.swift`.

Our pinned `objectbox_flutter_libs 5.3.2` ships **only a `.podspec`**, so it
resolves via that fallback. `6.0.0-preview.3` is the first release with a
`Package.swift`.

Moving off CocoaPods means taking that preview — but it is a **single** upgrade,
because the same bump widens `objectbox_generator`'s `analyzer` range enough to
drop the `build_runner` pin above. Verify `pub get`, `make codegen`, and
`flutter test` if you take it. Details in
[`docs/data-conventions.md`](./docs/data-conventions.md).

## Dependency pins

**These two pins are load-bearing. Widening either is not a routine upgrade.**
Both fail in confusing ways, so the reasoning is recorded here and in
[`docs/data-conventions.md`](./docs/data-conventions.md).

### 1. `build_runner` has an upper bound

```yaml
build_runner: ">=2.12.0 <2.15.2"   # not "^2.16.1"
```

`objectbox_generator 5.3.2` requires `analyzer <11.0.0`. `build_runner >=2.15.2`
requires `analyzer >=13.3.0`. **The ranges do not overlap**, so there is no
currently-published version of both, and `^2.16.1` fails the solver outright:

```
Because build_runner >=2.15.2 depends on analyzer >=13.3.0 <15.0.0 and
objectbox_generator >=5.2.0-dev.0 <6.0.0-preview.3 depends on
analyzer >=8.1.1 <11.0.0, version solving failed.
```

Widening the bound only becomes possible once `objectbox_generator` relaxes its
own `analyzer` range. When you try, verify **both** `flutter pub get` *and* a
successful `make codegen` — resolution alone is not proof, since a widened
`analyzer` constraint could resolve cleanly and then fail codegen.

### 2. The three ObjectBox packages move in lockstep

```yaml
objectbox: ^5.3.2
objectbox_flutter_libs: ^5.3.2
objectbox_generator: ^5.3.2
```

They ship a shared native core that must agree on version. A skew does **not**
fail at compile time — the store refuses to open at runtime:

```
Unsupported operation: ObjectBox platform-specific library not compatible:
is 5.3.1, expected 5.3.2 or newer
```

That is ObjectBox's most-reported issue, and it recurs on every minor bump.
Bump all three in one commit.

If Android Admin is ever enabled, `objectboxVersion` in
`android/app/build.gradle` must move in the same commit, or Android debug builds
break while every other platform is fine.

## Commands

| Command | Does |
|---|---|
| `make analyze` | `flutter analyze` |
| `make test` | `flutter test` |
| `make run_desktop` | `flutter run -d macos` |
| `make codegen` | Regenerate the ObjectBox model |
| `make install_objectbox` | Fetch the native library (once per checkout) |

### Generated code is committed

`lib/objectbox.g.dart` and `lib/objectbox-model.json` are generated by
`make codegen` and committed, so a clean checkout builds without running codegen.
Never hand-edit them; CI regenerates and fails on any diff.

Generated files land at the package root, not next to the entities in
`lib/data/objectbox/` — that is ObjectBox's default output directory.

## Architecture

```
lib/
  models/      pure domain values — no flutter, no objectbox
  data/        repositories; objectbox/ holds the annotated entities
  state/       utopia_hooks State → Hook → View → Coordinator
  shell/       app chrome and navigation panel
  pages/       one file per routed destination
  domain_mapping.dart   the only place entities become domain values
```

Dependencies are constructor-injected; there is no service locator and no `get_it`.
Global state is registered in `HookProviderContainerWidget` and read with
`useProvided`.

Conventions, and the traps that regress silently, are in
[`docs/data-conventions.md`](./docs/data-conventions.md) and
[`docs/shell-conventions.md`](./docs/shell-conventions.md).

## Before changing the data layer

Three things are enforced by tests because each fails *silently* otherwise:

- **A vector shorter than 256 dimensions is stored and then unfindable.**
  ObjectBox ignores it rather than rejecting it. `validateEmbedding` runs on
  every write path.
- **A scoped vector search returns too few results** unless it over-fetches,
  because `maxResultCount` bounds the ANN sub-query before the scope filter is
  applied. See `FetchBudget`.
- **`ToMany.remove` compares by object identity**, so it silently fails to
  detach. Use `removeWhere` on the id.

`search_repository_test.dart` runs the broken behaviour on purpose and asserts it
under-delivers. If that test ever passes, fix the test, not the code.
