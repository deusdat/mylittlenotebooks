# Plan: Local-First Publication Data Layer

**Spec directory:** `1790958509972-publication-data-layer`
**Plan date:** 2026-10-02
**Target toolchain (verified on this machine):** Flutter 3.47.0 stable · Dart 3.13.0 · macOS 26.6.2 (arm64)
**Spec:** revision 1 — unchanged by this plan. Every correction below is either an implementation detail the spec deliberately left open, or a **spec defect found by verification** and routed back per AGENTS.md.

---

## Approach

Five milestones. The work is mostly mechanical — three entity classes, three repositories, a codegen step — with three places where the obvious implementation is wrong and the cost of being wrong is a silent bug rather than a crash.

### The shape of the work in one paragraph

Three ObjectBox entities. `Notebook` and `Publication` are many-to-many via `ToMany` + `@Backlink`. `Chunk` hangs off `Publication` one-to-many and carries a 256-dimension HNSW vector. Domain models live in `lib/models/` with no ObjectBox import; annotated entity classes live in `lib/data/objectbox/` and map to them. The repositories sit behind the existing `NotebookRepository` seam so the shell is untouched. Scoped search is one function that filters a vector query by a denormalised indexed `publicationId`.

### Verification performed before planning

This plan's load-bearing claims were **executed**, not assumed. A scratch package was built outside the repo, resolved, code-generated, and run. Findings are folded into the milestones and risks below; the two that change the spec are in [Spec defects found by verification](#spec-defects-found-by-verification).

| Claim | Method | Result |
|---|---|---|
| `objectbox` 5.3.2 resolves on Dart 3.13 | `flutter pub get` on a copy of `pubspec.yaml` | ✅ resolves |
| Codegen runs on this toolchain | `dart run build_runner build` | ✅ with a version conflict (R1) and a name collision (**D1**) |
| `ToMany` + `@Backlink` round-trips | in-memory store test | ✅ AC2 works |
| HNSW `nearestNeighborsF32` + `.and()` on a scalar condition | in-memory store test | ✅ compiles and runs |
| Scoped search is orderable by distance | in-memory store test | ✅ ascending |
| Empty scope returns empty, not everything | in-memory store test | ✅ FR16 holds |
| **Naive scoped search breaks on a narrow scope** | 2,000 chunks, 20 publications, adversarial query vector | ❌ **returned 0 of 10** — FR15 confirmed necessary |
| Over-fetch ×20 recovers it | same corpus | ✅ exactly 10 |
| **A short vector is silently ignored by HNSW** | stored a 128-dim vector against a 256-dim index | ⚠️ **stored without throwing** — FR8 confirmed necessary |
| In-memory stores work in host tests | `flutter test` on macOS | ✅ but needs a native library (**R2**) |

The last two rows are why FR8 and FR15 are requirements rather than nice-to-haves: **both failure modes are silent.** Neither throws. A short vector produces a chunk that exists, counts, and is unfindable. A narrow scope produces an empty result set that reads as "no matches" rather than "broken query".

---

## Architecture & Design Decisions

### A. Packages

| Package | Version | Why |
|---|---|---|
| `objectbox` | `^5.3.2` | Store + HNSW vector index. Dart SDK `>=2.17.0 <4.0.0` |
| `objectbox_flutter_libs` | `^5.3.2` | Native libs for iOS/Android/macOS/Linux/Windows |
| `path_provider` | `^2.1.6` | Store directory (NFR2). Requires Flutter `>=3.38.0`; we have 3.47.0 |
| `objectbox_generator` | `^5.3.2` | **dev** — codegen |
| `build_runner` | `>=2.12.0 <2.15.2` | **dev** — see R1. The upper bound is load-bearing |

`objectbox`, `objectbox_generator`, and `objectbox_flutter_libs` must be pinned to the **same** version. They ship a shared native core and a version mismatch is the single most common ObjectBox failure (see R2).

### B. Directory layout

```
lib/
  models/
    notebook.dart              # EXISTING — gains nothing ObjectBox-ish (NFR5)
    publication.dart           # NEW: pure domain value, no objectbox import
    chunk.dart                 # NEW: pure domain value
    search_result.dart         # NEW: chunk + distance
  data/
    notebook_repository.dart   # EXISTING — interface unchanged, impl swapped
    in_memory_notebook_repository.dart  # EXISTING code MOVED here, kept as test double
    publication_repository.dart          # NEW
    library_repository.dart             # NEW: transactional chunk-set writes (FR10)
    search_repository.dart              # NEW: scoped + unscoped, one path (FR13)
    objectbox/
      ob_notebook.dart          # NEW: @Entity class
      ob_publication.dart       # NEW: @Entity class
      ob_chunk.dart            # NEW: @Entity class
      objectbox_store.dart      # NEW: openStore + in-memory test factory
  objectbox.g.dart              # GENERATED, committed (NFR3) — package root
  objectbox-model.json          # GENERATED, committed (NFR3) — package root
  domain_mapping.dart           # NEW: entity <-> domain, in both directions
test/
  ...
docs/
  data-conventions.md           # NEW: what later specs consume
```

**Why `InMemoryNotebookRepository` moves.** It currently lives inside `notebook_repository.dart` alongside the interface. AC22 requires the existing shell tests to pass unmodified, and those tests import the concrete class. Moving it to its own file is a **non-breaking** refactor only if the test import is updated — so instead it **stays where it is** and is simply retained. Deviation from this sketch, recorded in D2 below.

### C. Entities, with the one thing that does not work as sketched

```dart
// lib/data/objectbox/ob_chunk.dart
@Entity()
class ObChunk {
  @Id() int id = 0;

  int chunkIndex;
  String content;
  int tokenCount;

  /// Denormalised from ObPublication. Indexed. Load-bearing — see below.
  @Index() int publicationId;

  @HnswIndex(
    dimensions: 256,
    distanceType: VectorDistanceType.cosine,
    neighborsPerNode: 16,
    indexingSearchCount: 100,
  )
  @Property(type: PropertyType.floatVector)
  List<double> embedding;

  /// ⚠️ The rename is mandatory, not stylistic. See D1.
  @TargetIdProperty('publicationRef')
  final publication = ToOne<ObPublication>();

  ObChunk({required this.chunkIndex, required this.content, required this.tokenCount,
           required this.publicationId, required this.embedding});
}
```

The `ToOne` is still declared because the relation is real and `Publication.chunks` needs a `ToMany` to navigate from. It is **not** used for querying — FR7's flat `publicationId` is. Both are written in the same transaction (FR10) and AC9 asserts they never diverge.

### D. The two verification findings that change the spec

#### D1 — `publicationId` collides with the generated target-ID property. **Spec defect.**

ObjectBox auto-creates a virtual property named `<toOneName>Id` for every `ToOne`. A `ToOne` named `publication` therefore generates `publicationId` — **the exact name FR7 specifies**. Codegen fails:

```
E objectbox_generator:resolver: Property name conflicts with the target ID property
  "publicationId" created for the ToOne relation "publication".
  Rename the property or use @TargetIdProperty on the ToOne to rename the target ID property.
```

Verified working fix: `@TargetIdProperty('publicationRef')` on the `ToOne`, which frees `publicationId` for the denormalised column. **Confirmed by successful codegen.**

This is a spec defect, not an implementation detail: FR7's Dart snippet does not compile as written. Per AGENTS.md's escalation rule this traces to the root — spec FR7 — and the snippet needs correcting there. Implementation proceeds with the `@TargetIdProperty` form; `spec.md` is corrected at the source rather than diverging from it.

#### D2 — The over-fetch multiplier cannot be `1 / scopeFraction`.

FR15 requires over-fetching "proportional to scope selectivity" but does not fix the formula. Measured on a 5%-scope corpus:

| Total chunks | Scope fraction | `1/fraction` | **Minimum multiplier that actually worked** |
|---|---|---|---|
| 2,000 | 0.050 | 20 | **30** (×1.5) |
| 20,000 | 0.050 | 20 | **15** (×0.75) |

`1/fraction` is a **lower bound, not a guarantee**, and the shortfall is not a fixed factor — it varied from 0.75× to 1.5× across corpus sizes. A formula resting on `1/fraction` alone would be wrong in one direction or the other depending on corpus size.

**Resolution:** `fetchCount = clamp(limit × ceil(1/fraction × 2), limit, kMaxFetch)` with `kMaxFetch = 1000`. The `×2` safety factor exceeds both measured cases; the clamp bounds the worst case, because an unbounded multiplier on a 1%-scope query over a large corpus would otherwise ask for more candidates than the corpus holds. When scope is unknown or empty, `fraction = 1.0` and `fetchCount = limit × 2`.

AC16 is written to be **adversarial** rather than merely "returns `limit` results": build a corpus where the unfiltered top-`limit` is entirely out-of-scope, then assert `limit` results come back. A test that seeds a friendly corpus where the nearest neighbours happen to be in-scope **passes against the broken implementation** and guards nothing. This is the single most important test in the milestone.

### E. Domain / entity separation (NFR5)

The spec's C3 says domain models must not import `package:objectbox`. Enforced structurally by `lib/domain_mapping.dart` owning every conversion, and by AC18's import-grep test.

The mapping is not busywork. It is what lets the shell's existing tests keep using pure `Notebook` values against a fake repository (AC22), with no store in the picture.

### F. Store lifecycle

```dart
// Production — NFR2: application-support directory, platform-agnostic.
Future<Store> openLibraryStore() async =>
    openStore(getApplicationSupportDirectory());

// Tests — NFR4: file-less, per-test, no cleanup needed.
Store openTestStore([String tag = 'test']) => Store(
      getObjectBoxModel(),
      directory: '${Store.inMemoryPrefix}lib-$tag-${DateTime.now().microsecondsSinceEpoch}',
    );
```

The timestamp in the test directory name is **not optional**. `Store.inMemoryPrefix` alone reuses the same in-memory database across tests in one isolate, so state leaks between them. Verified working.

The store is opened once in `bootstrap.dart` before `runApp` (AGENTS.md Directive 6) and handed to the root widget as a constructor argument. Nothing in the data layer opens a store — that is the seam that keeps tests free of filesystem concerns.

### G. Transactions

FR10 and FR11 both reduce to one rule: **any write that would leave an inconsistency if interrupted runs in `store.runInTransaction(TxMode.write, …)`.** Concretely:

| Operation | Transaction contents |
|---|---|
| `replaceChunks(publication, chunks)` | remove existing chunks → insert new → update `chunkCount` → set each `ToOne` target |
| `deletePublication(pub)` | remove chunks → remove publication → leave notebooks |
| `deleteNotebook(nb)` | remove association only |
| `attach` / `detach` | mutate the `ToMany`, one `put` |

AC11 forces a throw mid-transaction and asserts the prior chunks, the prior count, and searchability all survive. A transaction test that never provokes a rollback has not tested a transaction.

### H. Repository surface

```dart
abstract interface class PublicationRepository {
  List<Publication> listForNotebook(String notebookUuid);
  Publication? byUuid(String uuid);
  List<String> attachments(String publicationUuid);      // notebook uuids
  List<String> embeddingModelIds();                       // FR6
  List<Publication> byEmbeddingModel(String modelId);     // FR6
}

abstract interface class LibraryRepository {
  Publication create({required String title, required String sourceMarkdown,
                      required String embeddingModelId});
  void replaceChunks(String publicationUuid, List<ChunkDraft> chunks);  // FR10
  void deletePublication(String publicationUuid);                       // FR12
  void attach(String publicationUuid, String notebookUuid);             // FR11
  void detach(String publicationUuid, String notebookUuid);             // FR11
  void deleteNotebook(String notebookUuid);                             // FR12
}

abstract interface class SearchRepository {
  List<SearchResult> search({required List<double> queryVector,
                             required List<int> publicationIds,  // empty = all (FR13)
                             required int limit});                // FR14, FR15
}
```

`SearchRepository.search` takes **ObjectBox ids** (`List<int>`), not uuids. Resolution happens above it. This keeps the vector path free of string lookups and keeps the id-vs-uuid distinction (FR5) from leaking inward. The caller-facing conversion is a separate method.

### I. Decisions the implementation makes

| # | Decision | Alternative | Cost to reverse |
|---|---|---|---|
| **I1** | `@TargetIdProperty('publicationRef')` | Rename the denormalised column instead | Trivial — but the denormalised name is the one queries read, so this direction is clearer |
| **I2** | `fetchCount = clamp(limit × ceil(2/fraction), limit, 1000)` | `limit × 2` flat; or exact | Trivial — one function, one test |
| **I3** | Search takes `List<int>` publication ids | uuids | Medium — touches the call site |
| **I4** | `sourceMarkdown` is `String`, not bytes | `Uint8List` | Medium — a UTF-8-only assumption appears at the boundary |
| **I5** | In-memory test store keyed by timestamp | explicit per-test name | Trivial |
| **I6** | Repositories are sync (`Box` is sync); the store is async | async everywhere | Low — ObjectBox's `*Async` APIs exist for exactly this |
| **I7** | `InMemoryNotebookRepository` stays in place | move to its own file | Trivial — but moving breaks AC22's "unmodified tests" |

### J. Explicitly not built

- **Text/hybrid search.** `content` is stored unindexed. No `IndexType.value` on it.
- **Observers / reactive queries.** `Query.watch()` exists and is the natural fit for a live sources list, but nothing consumes it yet and it is not in the spec's requirements.
- **Sync.** ObjectBox Sync would make the `ToMany` edge synctractable nearly free. Out of scope per spec.
- **A migration path.** No user data exists. The first shipped schema needs one; the first working one does not.
- **Store size reporting.** `Store.dbFileSize()` exists and the spec's storage budget invites a check, but there is no UI to show it in.

---

## Milestones

### M1 — Dependencies, codegen, and a green spike

Add the five packages. Verify the solver conflict (R1) is resolved by the `<2.15.2` bound. Create `lib/data/objectbox/` with the three entity classes **exactly as in C**, including `@TargetIdProperty`. Run codegen. Commit `objectbox.g.dart` and `objectbox-model.json`.

**Gate:** `dart run build_runner build` succeeds with zero errors; `objectbox.g.dart` and `objectbox-model.json` exist and are committed; `flutter analyze` clean. The two `DateTime` warnings the generator emits are silenced by declaring `@Property(type: PropertyType.dateUtc)` explicitly — verified as the documented fix, and chosen because `createdAt`/`importedAt` ordering must not depend on the device's timezone.

**This milestone exists to fail cheaply.** It contains the one thing that does not work as sketched (D1) and the one version conflict (R1). Both are found here rather than in M3.

### M2 — Store lifecycle, mapping, and the notebook repository swap

`objectbox_store.dart` with the two constructors from F. `lib/models/publication.dart`, `chunk.dart`, `search_result.dart` as pure values. `domain_mapping.dart` in both directions. `ObjectBoxNotebookRepository implements NotebookRepository`, wired into `bootstrap.dart`. Seed data moves from hard-coded constructor calls to a real seeding path.

**Gate:** AC18 (domain models import neither Flutter nor ObjectBox — grep-enforced); AC19 (clean checkout builds without re-running codegen); **AC22 — the seven existing shell tests pass unmodified.** M2 does not add any new test that the shell could have caught; its job is that nothing the shell already asserts changes.

### M3 — Publications, associations, and cascade

`PublicationRepository`, `LibraryRepository`. `create` rejects empty/whitespace `sourceMarkdown` (FR4, AC5). `attach`/`detach` idempotent (AC3). Cascade per G (AC12, AC13).

**Gate:** AC1, AC2, AC3, AC4, AC5, AC10. AC2 is the many-to-many proof and is written as *two notebooks, one publication, both directions readable* — a test that only checks one side would pass against a broken `ToMany`.

### M4 — Chunks and vector search

`ChunkDraft` → `Chunk` mapping with **validation at the boundary** (FR8, AC8): reject any embedding whose length ≠ 256 with a typed error, before `put`. The typed error is a new public type — the caller must be able to catch it, and `ArgumentError` would not distinguish "bad vector" from "bad argument" at an ingestion boundary. `replaceChunks` transactional (FR10, AC11). `SearchRepository` with the over-fetch from D2 (FR13–FR16).

**Gate:** AC6, AC8, AC9, AC10, AC11, AC14, AC15, AC16, AC17. **AC16 uses the adversarial corpus from D2** — 2,000 chunks, 20 publications, query vector near publication 19, scope pinned to publication 0 — which was measured to return **0 results** against the naive implementation. A friendly corpus passes against the broken code and guards nothing. AC17 asserts ascending distance and that an identical vector scores lower than an orthogonal one.

### M5 — Verification, documentation, and the spec corrections

Full `flutter analyze` + `flutter test`. Manual pass on macOS: create a notebook, create a publication from markdown, associate, search scoped, search unscoped, delete the notebook, confirm the publication and its chunks survive (AC13 by hand, not only in a test). AC21 (query hygiene) by inspection plus a leak-free suite run. AC23 by inspection of `lib/data/`. `docs/data-conventions.md`.

**Correct the two spec defects at the source** (AGENTS.md escalation): FR7's snippet gains `@TargetIdProperty('publicationRef')`, and FR15 gains the D2 formula with its measurement table. `spec.md` must not be left disagreeing with the implementation.

**Gate:** AC20, AC21, AC22, AC23; `docs/data-conventions.md` written; spec corrected.

---

## Dependencies

**External (all resolution-verified on Dart 3.13):** `objectbox ^5.3.2`, `objectbox_flutter_libs ^5.3.2`, `path_provider ^2.1.6`, `objectbox_generator ^5.3.2`, `build_runner >=2.12.0 <2.15.2`. Full set resolves to `objectbox 5.3.2` / `build_runner 2.15.1` / `analyzer 10.2.0` / `source_gen 4.2.4`.

**Toolchain (present):** Flutter 3.47.0, Dart 3.13.0. Codegen verified working.

**Internal:** M1 → M2 → M3 → M4 → M5, strictly sequential. M1's codegen must succeed before anything else compiles. M3 must land before M4 because `SearchRepository` resolves publications.

**Zero upstream coupling.** No spec dependency; the shell spec is untouched. Nothing waits on the ONNX, chunker, or embedding-model specs — the interfaces are defined here and those specs fill them.

---

## Risks & Mitigations

**R1 — `build_runner` latest is incompatible with `objectbox_generator`.** Not hypothetical; the solver fails outright on `^2.16.1`:

> `build_runner >=2.15.2` depends on `analyzer >=13.3.0 <15.0.0` and `objectbox_generator` depends on `analyzer >=8.1.1 <11.0.0` … version solving failed.

`objectbox_generator` 5.3.2 allows `analyzer <11.0.0`; `build_runner` 2.15.2+ requires `analyzer >=13.3.0`. The ranges do not overlap, so there is **no version of both that is current**. A `flutter pub upgrade` that lifts the `build_runner` bound breaks the build outright.
→ **Mitigation:** pin `build_runner: ">=2.12.0 <2.15.2"` with a comment naming the conflict. M1 verifies `pub get` *and* a successful codegen run — resolution alone is not proof, since a future `objectbox_generator` could widen its own `analyzer` range and silently invalidate the pin. Re-check on every dependency bump.

**R2 — Host-side unit tests need a native library that is not in the repo.** `flutter test` on macOS fails with `Failed to load dynamic library 'libobjectbox.dylib'`. `objectbox_flutter_libs` covers *apps*; it does not cover the Dart VM running tests. Upstream ships `install.sh` for this.
→ **Mitigation:** run `bash install.sh` once per machine checkout as a documented setup step, and note it in `docs/data-conventions.md` and the Makefile. **Verified working.** CI must run it or every test fails at load — and it fails at *load*, not at assert, so the symptom looks like a broken suite rather than a missing setup step.

**R3 — A version skew between `objectbox` and `objectbox_flutter_libs` breaks at runtime, not at compile.** The store refuses to open: `Unsupported operation: ObjectBox platform-specific library not compatible: is X, expected Y`. This is ObjectBox's most-reported issue and it recurs on every minor bump, because the three ObjectBox packages ship a shared native core that must agree.
→ **Mitigation:** all three pinned to `^5.3.2` in lockstep. Note the `objectbox-android-objectbrowser` coupling: if Android Admin is ever enabled, `android/app/build.gradle`'s `objectboxVersion` must be bumped in the same commit, or Android debug builds break while every other platform is fine.

**R4 — AC16 is the test most likely to be written wrong, because the friendly version passes against broken code.** A corpus where the query vector's nearest neighbours are already in-scope returns a full `limit` from the *naive* implementation. Such a test is green on day one and catches nothing.
→ **Mitigation:** M4's gate names the adversarial construction explicitly, and D2 records the measured `0 of 10` result that the naive implementation produces. The test asserts the corpus *shape*, not just the result count: if the unfiltered top-`limit` is in-scope, the test is vacuous. Reviewers should check for this before accepting the test.

**R5 — The `@TargetIdProperty` rename is load-bearing and easy to undo.** Removing it does not fail loudly in application code; it fails at codegen with a name-conflict error that looks like a typo. Worse, renaming the *denormalised column* instead would compile and would silently break FR7's flat-condition queries, because the queries reference `Chunk_.publicationId`.
→ **Mitigation:** the rename appears in the entity class with a comment naming the conflict, and AC9 asserts the denormalised column stays consistent with the `ToOne`. M1's gate is codegen success, which catches the removal immediately.

**R6 — The `ToOne` and the denormalised `publicationId` can drift.** They are two representations of one fact. A future contributor adds a code path that sets one and not the other.
→ **Mitigation:** no write path outside `replaceChunks` sets either. AC9 reads every chunk back and asserts `publicationId == publication.targetId`. Drift is a test failure, not a runtime symptom.

**R7 — Silent wrongness from vector problems (FR8).** Verified: a 128-dimension vector stored against a 256-dimension HNSW index **succeeds without throwing**. The chunk exists, is counted, renders in a list, and is unfindable by search. This is the worst failure mode in the system because every user-visible surface except search looks correct.
→ **Mitigation:** validate length at the write boundary before `put`, with a typed error (M4). AC8 asserts the rejection. Related: FR6's `embeddingModelId` is the guard against the same class of problem at the model level, and AC7 asserts it is always present and enumerable.

**R8 — `chunkCount` denormalisation drifts from reality.** It exists so a publication list renders without loading chunks, which means nothing forces it to stay correct.
→ **Mitigation:** written only inside the `replaceChunks` transaction (FR10), asserted after create, after re-index, and after a *failed* re-index (AC10). The failed case is the one that matters: a rollback that updated the count but not the chunks would report a healthy publication with missing content.

**R9 — Deleting a notebook could cascade too far.** FR12 forbids it, but ObjectBox's `ToMany` makes the destructive path look natural, and a shared publication makes the blast radius user-visible.
→ **Mitigation:** AC13 asserts a publication shared with a second notebook survives the first notebook's deletion **and remains searchable from the second**. `deleteNotebook` touches one relation and nothing else.

**R10 — Shell regressions from the repository swap.** Replacing `InMemoryNotebookRepository` in `bootstrap.dart` touches the shell's start-up path, and the shell spec's seeded-notebook behaviour (D10) is asserted by existing tests.
→ **Mitigation:** M2's gate is AC22 — the seven existing tests pass **unmodified**. The in-memory implementation is retained (I7) rather than deleted, so any test that wants it still finds it. Seeding is preserved exactly: three notebooks, stable titles.

---

## Spec defects found by verification

Per AGENTS.md's escalation rule, these trace to the spec and are corrected **at the source** in M5 rather than absorbed silently here.

| # | Location | Defect | Correction |
|---|---|---|---|
| **1** | FR7 (and the schema in FR2) | The `Chunk` snippet declares both `int publicationId` and `ToOne<Publication> publication`. ObjectBox auto-generates a target-ID property named `publicationId` for that `ToOne`, so codegen **fails with a name conflict**. The snippet does not compile. | Add `@TargetIdProperty('publicationRef')` to the `ToOne`. Verified: codegen succeeds. |
| **2** | FR15 | "Proportional to scope selectivity" is under-specified. `1/fraction` was **measured** to be insufficient — a 5% scope needed ×30 and ×15 at two corpus sizes. | Specify `fetchCount = clamp(limit × ceil(2/fraction), limit, 1000)` with the measurement table, and state that `1/fraction` is a lower bound only. |

Neither changes a goal, a non-goal, or an acceptance criterion's intent. Both change how the implementation must be written, which is why they are recorded here and routed back to `spec.md`.

Two further findings are **not** spec defects but do constrain the implementation, and are carried in the milestones rather than escalated:

- **A short vector is silently ignored by HNSW** (verified). FR8 already anticipated this; the plan now carries the measurement.
- **Host tests need `install.sh`** (verified). NFR4 assumed in-memory stores were self-contained on the host. They are, once the library is present; R2 covers the setup step and CI.

---

## Open Questions for the plan phase

Carried from the spec and **not** resolved here, because each belongs to a later spec:

- **`embeddingModelId`'s value space.** FR6 and FR8 both assume 256 dimensions. The actual string depends on the model choice (`nomic-embed-text-v1.5:int8:256` vs `ModernBERT-small-embed:…`). M4 validates against the constant 256; if the model spec lands a different dimension, `dimensions:` and FR8 change together, and changing `dimensions` **triggers a full HNSW re-index**.
- **Behaviour on model change.** FR6 makes a mismatch detectable. Whether the app re-indexes, prompts, or proceeds anyway is the embedding spec's decision, and it must not be left implicit.
- **Corpus ceiling.** ~100,000 chunks per the spec's storage budget. What happens at the ceiling is undecided.
- **Backup / export.** A single local store with no sync has no recovery story.
