# Data-layer conventions

The conventions this data layer establishes. The chunker, the ONNX embedding
spec, and the sources UI plug into these rather than re-deriving them.

## Read this first: `install.sh`

**Host-side `flutter test` cannot open an ObjectBox store until the native
library is present.** `objectbox_flutter_libs` covers *apps*; it does not cover
the Dart VM that runs tests. Without this step every test fails at *load* with a
`dlopen` error, which reads as a broken suite rather than a missing setup step.

```bash
make install_objectbox
```

Run it once per machine checkout. CI runs it too. `lib/*.dylib` and `download/`
are gitignored — they are per-machine artifacts.

### The install script is fetched from a tag, not from `main`

```bash
curl -sL https://raw.githubusercontent.com/objectbox/objectbox-dart/v<version>/install.sh
```

`<version>` is read from `pubspec.yaml`, so it cannot drift from the pinned
package. **Do not fetch this from `main`.** The script on `main` hardcodes
`cLibVersion=6.0.0-beta`, which downloads a **6.0.0-beta C library** to sit
alongside our **5.3.2 Dart bindings**. The script's own header is explicit
about why that is not a harmless mismatch:

> It's important that the generated dart bindings and the c-api library version
> match. Dart won't error on C function signature mismatch, leading to obscure
> memory bugs.

So the failure mode is not an error — it is undefined behaviour that may not
appear until much later. The version-matched tag pins `cLibVersion=5.3.2`, and
the two agree.

## iOS/macOS: CocoaPods vs Swift Package Manager

**CocoaPods is not deprecated-and-removed; it is in maintenance mode.** Its
registry goes permanently read-only on **2 December 2026**. Existing pod
versions stay available indefinitely, so builds keep working — this is a
deadline to migrate before, not a cliff to fall off.

Flutter 3.44+ (we are on 3.47) uses **SwiftPM by default**, falling back to
CocoaPods only for plugins that have not shipped a `Package.swift`.

| `objectbox_flutter_libs` | `Package.swift`? | Distribution |
|---|---|---|
| **5.3.2** (pinned) | **No** — `.podspec` only | CocoaPods |
| 6.0.0-beta | No — `.podspec` only | CocoaPods |
| 6.0.0-preview.3 | **Yes** (ios + macos) | SwiftPM |

**Verified by inspecting the published packages**, not by reading the
changelog. So our pin is CocoaPods-only, and that is fine today: Flutter's
fallback keeps the build green, and the pod stays installable after the
registry freezes.

The escape hatch is `6.0.0-preview.3`, and it is worth taking as a **single**
change, because the same upgrade frees the `build_runner` pin:

- preview.3 widens `objectbox_generator`'s `analyzer` to `<15.0.0`, so
  `build_runner: ^2.16.1` resolves **and codegen runs** — verified, not assumed.
- It requires Dart ≥ 3.12 / Flutter ≥ 3.44. We are on 3.13 / 3.47.

That trades a working pinned release for a preview. Reasonable once the
registry freeze is in view; not worth doing pre-emptively. If you take it,
verify `flutter pub get`, a real `make codegen`, **and** `flutter test` — a
preview's `analyzer` range is exactly the kind of thing that shifts again.

## Dependencies: two pins that are not routine upgrades

```yaml
objectbox: ^5.3.2
objectbox_flutter_libs: ^5.3.2
objectbox_generator: ^5.3.2
build_runner: ">=2.12.0 <2.15.2"
```

**The `build_runner` upper bound is load-bearing.** `objectbox_generator 5.3.2`
allows `analyzer <11.0.0`; `build_runner >=2.15.2` requires `analyzer >=13.3.0`.
The ranges do not overlap, so `build_runner: ^2.16.1` fails the solver outright.
There is no currently-published version of both. Widening the bound is not a
routine upgrade — re-check resolution *and* a codegen run when it changes.

**The three ObjectBox packages ship a shared native core** and must move in
lockstep. A mismatch does not fail at compile time; the store refuses to open at
runtime with `ObjectBox platform-specific library not compatible: is X, expected
Y`. If Android Admin is ever enabled, `objectboxVersion` in
`android/app/build.gradle` must move in the same commit.

## Opening the store on a sandboxed macOS app

**A sandboxed macOS app cannot open an ObjectBox store without an App Group.**
This is not a data-modelling detail — it is the difference between the app
starting and not starting.

```
StorageException: failed to create store: Could not open database environment;
please check options and file system (1: Operation not permitted)  (OBX_ERROR 10199)
```

The message misdirects: the data directory **is** writable. What fails is the
POSIX semaphore namespace ObjectBox uses for its mutexes, and a sandboxed app may
only use semaphores for IPC through an App Group. So the error blames the
filesystem when the problem is entitlements.

Two things are required, and **both** are needed:

1. `com.apple.security.application-groups` in **both**
   `macos/Runner/DebugProfile.entitlements` and `Release.entitlements`.
2. `macosApplicationGroup` passed to `openStore` — see
   `lib/data/objectbox/objectbox_store.dart`.

The **whole string** must be **19 characters or fewer**, and macOS's error for
exceeding it does not mention the length. `group.mln.lnb` is 13.

An App Group is a **signing-gated capability**, so a third thing is required:
a `DEVELOPMENT_TEAM` in `macos/Runner/Configs/AppInfo.xcconfig`. Without one,
the build fails with *"entitlements that require signing with a development
certificate"*. The bundle id must also leave the `com.example.*` template
placeholder before any store submission.

### Do not "fix" this by disabling the sandbox

Setting `com.apple.security.app-sandbox` to `false` is the workaround that
appears in most issue threads, and it is a trap: it makes a local build work and
then blocks App Store distribution. `test/production_store_config_test.dart`
asserts the sandbox stays **on**, so the shortcut fails a test rather than
shipping silently.

### iOS does not need this

`macosApplicationGroup` is macOS-only and inert on iOS; an iOS sandboxed app uses
its container and works without an App Group. The parameter is passed
unconditionally so no `Platform.isMacOS` branch is needed (spec NFR1, AC23).

### Why no test caught the original bug

**Every test in this project opens `openTestStore()`** — an in-memory, file-less
store that never touches the filesystem and never goes through `openStore()`.
`openLibraryStore()` had never been executed by anything.

`test/production_store_config_test.dart` asserts the *configuration* (group
present in every entitlements file, matches the Dart constant, fits the length
limit, sandbox still enabled). It cannot prove the store opens: that needs a real
platform channel and a real filesystem. Verify by running the app.

## Generated code is committed



`lib/objectbox.g.dart` and `lib/objectbox-model.json` are generated by
`make codegen` and **committed**. A clean checkout builds without running
codegen (spec NFR3). Never hand-edit them.

Generated files land at the package root — ObjectBox's default output directory
— **not** next to the entities in `lib/data/objectbox/`. That is expected.

## `@TargetIdProperty('publicationRef')` — mandatory, not stylistic

```dart
@Index() int publicationId;          // denormalised, indexed, queried

@TargetIdProperty('publicationRef')   // ← this rename is required
final publication = ToOne<ObPublication>();
```

ObjectBox auto-generates a target-ID property named `<toOneName>Id` for every
`ToOne`. A `ToOne` called `publication` therefore generates `publicationId` —
**the exact name the denormalised column wants** — and codegen fails with a
name conflict.

Renaming either side of this pair is the dangerous move:

- Renaming the **`ToOne`** back to something else frees `publicationId` but
  breaks every `ObChunk_.publicationId` query condition.
- Renaming the **denormalised column** compiles fine and silently breaks scoped
  search, because the queries reference `ObChunk_.publicationId`.

The same trap exists in `ObDocument` (`publicationId` + `documentOwnerId`).

## Two silent failure modes

Both of these are **silent**: nothing throws, nothing crashes, and every surface
except search looks correct.

### 1. A short vector is stored and then unfindable

The HNSW index is declared `dimensions: 256`. ObjectBox **silently ignores any
vector with fewer dimensions** — it stores without throwing, the chunk appears
in every listing and count, and it is simply never returned by search. Verified:
a 128-dimension vector stores successfully against a 256-dimension index.

`validateEmbedding` therefore runs on **every** write path, before `put`, and
throws `InvalidEmbeddingException`. Do not "fix" a wrong-length vector by
padding or truncating — reject it; the caller owns the model contract.
`NaN` and `±inf` are rejected too: they poison the HNSW graph and degrade every
*subsequent* query, not just the bad row.

`VectorGeometry.dimensions` in `lib/data/embedding_validation.dart` is the single
source of truth and must equal the `dimensions:` in `ob_chunk.dart`. Changing it
**triggers a full HNSW re-index**.

### 2. A scoped search silently returns too few results

```dart
ObChunk_.embedding.nearestNeighborsF32(queryVector, fetchCount)
    .and(ObChunk_.publicationId.oneOf(ids))
```

`maxResultCount` bounds the **ANN sub-query only**. The scope filter is applied
to those candidates *afterwards*. So `fetchCount == limit` returns fewer than
`limit` results — **including zero** — whenever the unfiltered nearest
neighbours fall outside the scope. A query scoped to one small publication
inside a large library can return nothing and look like a broken index.

Measured during planning on a 5%-scope corpus:

| Total chunks | `1 / fraction` | Multiplier that actually worked |
|---|---|---|
| 2,000 | 20 | **30** (×1.5) |
| 20,000 | 20 | **15** (×0.75) |

`1 / fraction` is a **lower bound, not a guarantee**, and the shortfall is not a
constant factor — it moved with corpus size.

`FetchBudget.forLimit` implements
`clamp(limit × ceil(2 / fraction), limit, 1000)`. The `×2` clears both
measurements; the clamp bounds the opposite failure, where an unbounded
multiplier on a very narrow scope would request more candidates than the corpus
holds.

`search_repository_test.dart` proves this by running the broken behaviour
through `fetchCountOverride` and asserting it under-delivers. If that test ever
passes, the adversarial corpus has stopped being adversarial — that is the
signal to fix the **test**, not the code.

## `null` scope and `[]` scope are different requests

```dart
search(publicationIds: null)   // no scope — search everything (FR13)
search(publicationIds: [])     // a scope that matches nothing — return nothing (FR16)
```

Conflating them makes a search scoped to a deleted notebook, or to a notebook
with no publications, return the **entire corpus**. `resolveNotebookScope`
returns `List<int>`, so an empty notebook yields `[]`, not `null` — pass it
straight through and the distinction survives.

## Scores are distances

ObjectBox's `score` is a **distance**: **smaller means nearer**. The domain type
is `SearchResult.distance`, never `score`, so a caller cannot accidentally
invert the ordering. Results arrive ordered by ascending distance and only
`findWithScores()` guarantees that order.

## The document text lives in its own row

`ObPublication` is metadata; `ObDocument` holds the markdown.

ObjectBox loads **whole objects**, so a document stored on the publication row
would be read by every publication *list* — turning "render 50 titles" into
"read 50 documents". Spec NFR6 forbids that, and separating the rows is the
only way to make it true rather than aspirational.

Consequently:

- List methods return **`PublicationSummary`**, a type with no `sourceMarkdown`
  field. A list caller *cannot* read the document.
- `byUuid` is the only read that returns the full `Publication`.
- `deletePublication` removes the document row too, or orphaned text would grow
  without bound and could resurface under a re-used uuid.

## Domain values are framework-free

`lib/models/` holds pure values: no `package:flutter`, no `package:objectbox`.
`test/domain_model_purity_test.dart` greps the **import directives** (not the raw
source — the doc comments here discuss the rule in prose) and fails if either
appears.

Annotated entities live in `lib/data/objectbox/`. Every conversion is in
`lib/domain_mapping.dart` and nowhere else; a conversion inside a repository is
a layering leak.

`PublicationSummary` is not a domain *value* — it is a projection, so the strict
Flutter ban does not apply to it, but the ObjectBox ban does.

## `ToMany.remove` compares by identity — use `removeWhere`

```dart
// Wrong: silently returns false, detach appears to work and changes nothing.
notebook.publications.remove(publication);

// Right.
notebook.publications.removeWhere((p) => p.id == publication.id);
```

`ToMany` is a `ListMixin` and ObjectBox entities have **no value equality**, so
`List.remove` compares object identity. The entity you queried is a different
instance from the one inside the relation. This cost a real bug during
implementation; `removeWhere` on the id is what actually expresses the intent.

## The transaction rule

**Any write that would leave an inconsistency if interrupted runs in one
`store.runInTransaction(TxMode.write, …)`.**

| Operation | Contents |
|---|---|
| `create` | publication row + document row |
| `replaceChunks` | remove stale → insert new → update `chunkCount` |
| `deletePublication` | chunks + document + publication |
| `attach` / `detach` | the `ToMany` mutation |
| `deleteNotebook` | the association only |

`chunkCount` is written **only** inside `replaceChunks`. Nothing forces it to
stay correct — nothing outside that transaction touches it.

Cascade rules, and the one that matters most: **`deleteNotebook` never deletes
publications or chunks.** They may be attached to another notebook, and a shared
publication deleted here is data loss the user cannot undo.

## Every `Query` is closed

ObjectBox holds native resources until `close()` and explicitly discourages
relying on finalizers. Every repository method wraps its query in
`try`/`finally`.

## Testing

```dart
final store = openTestStore('some-tag');   // file-less, in-memory
```

The **timestamp in the directory name is not optional**.
`Store.inMemoryPrefix` alone resolves to the same in-memory database for every
call in an isolate, so state leaks between tests and failures become
order-dependent.

Production opens exactly once, in `bootstrap.dart`, before `runApp`:
ObjectBox refuses to open the same directory twice, and hot restart re-runs
`main()`.

## Entity files import each other

A cross-file relation type needs an explicit import. Omitting it produces a
cryptic `Null check operator used on a null value` from the generator — but
`flutter analyze` reports it clearly as `non_type_as_type_argument`. Run
`flutter analyze` before blaming the generator.

## Extension points

| Add | Where |
|---|---|
| A new chunk field | `ObChunk` + `ChunkDraft`, then `make codegen` |
| A new query | `SearchRepository`, keeping `FetchBudget` in the path |
| A different embedding model | `embeddingModelId`; `byEmbeddingModel` finds what needs re-indexing |
| The chunker | `ChunkDraft` is the contract — it produces drafts, nothing more |
| Embedding inference | `validateEmbedding` is the boundary it must satisfy |

### Not built, deliberately

- **Hybrid search.** `content` is stored unindexed. Adding a text index later is
  cheap and non-breaking.
- **Reactive queries.** `Query.watch()` is the natural fit for a live sources
  list; nothing consumes it yet.
- **ObjectBox Sync.** The `ToMany` edge would synctractable nearly free. Out of
  scope.
- **A migration path.** No user data exists. Needed before the first *shipped*
  schema, not the first working one.
