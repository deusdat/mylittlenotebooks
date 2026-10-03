# Tasks: Local-First Publication Data Layer

**Spec directory:** `1790958509972-publication-data-layer`
**Spec:** [`spec.md`](./spec.md) (revision 1 — **carries two open spec defects, see T29**)
**Plan:** [`plan.md`](./plan.md)
**Generated:** 2026-10-02

## Prerequisites

- Read [`spec.md`](./spec.md) — **FR2** (schema), **FR7** (denormalised `publicationId`), **FR10** (transactional writes), **FR12** (cascade), **FR13–FR16** (search), and **Corrections to the brief** (C1/C2/C3).
- Read [`plan.md`](./plan.md) — **§C** (entities incl. the `@TargetIdProperty` rename), **§D** (the two verification findings), **§F** (store lifecycle), **§G** (transactions), **§H** (repository surface).
- Read `AGENTS.md` **Flutter/Dart Development Instructions** — constructor injection, no service locator, domain models free of framework imports.
- Read `docs/shell-conventions.md` — the conventions this data layer must not break.
- **Toolchain:** Flutter 3.47.0 / Dart 3.13.0, verified.
- **One-time machine setup:** `bash install.sh` (ObjectBox's script, fetched from the `objectbox-dart` repo) downloads `libobjectbox.dylib` into `lib/`. Required for **host-side `flutter test`** — plan R2. Without it every test fails at *load*, which reads as a broken suite rather than a missing step.

**How to read this list**

- Strictly sequential unless `Depends on` says otherwise.
- `Satisfies` names the acceptance criteria a task owns. Not done until demonstrable.
- Each milestone ends with a gate. A gate is not "it compiles".
- **T1 is a verification spike.** Do not skip it, and do not keep it — the entities it writes are the real ones.
- **T23 contains the most important test in this spec** (plan R4). Read step 2 before writing it.

---

## Milestone 1 — Dependencies, codegen, and the entities

This milestone exists to fail cheaply. It contains the one thing that does not work as sketched (`@TargetIdProperty`, plan D1) and the one version conflict (plan R1). Both must surface here, not in Milestone 4.

### T0: Add pinned dependencies
- **Files:** `pubspec.yaml`
- **Effort:** Small
- **Depends on:** —
- **Satisfies:** plan §A
- **Steps:**
    1. Add to `dependencies`: `objectbox: ^5.3.2`, `objectbox_flutter_libs: ^5.3.2`, `path_provider: ^2.1.6`.
    2. Add to `dev_dependencies`: `objectbox_generator: ^5.3.2`, `build_runner: ">=2.12.0 <2.15.2"`.
    3. **The `build_runner` upper bound is load-bearing.** `^2.16.1` fails the solver outright: it needs `analyzer >=13.3.0 <15.0.0` while `objectbox_generator 5.3.2` allows `analyzer <11.0.0`. The ranges do not overlap, so **no currently-published version of both exists.** Leave a comment naming the conflict so a future `pub upgrade` is not mistaken for a fix.
    4. All three ObjectBox packages share a native core and **must** move in lockstep (plan R3). Do not bump one alone.
    5. `flutter pub get`; confirm resolution to `objectbox 5.3.2`, `build_runner 2.15.1`, `analyzer 10.2.0`.

### T1: Run `install.sh` and verify the native library loads
- **Files:** `lib/libobjectbox.dylib` (downloaded, **gitignored**)
- **Effort:** Small
- **Depends on:** T0
- **Satisfies:** NFR4; plan R2
- **Steps:**
    1. Fetch and run ObjectBox's installer: `curl -sL https://raw.githubusercontent.com/objectbox/objectbox-dart/main/install.sh -o install.sh && bash install.sh`.
    2. Confirm `lib/libobjectbox.dylib` exists.
    3. Add `lib/*.dylib`, `lib/*.so`, `lib/*.dll` to `.gitignore` — the native library is a machine artifact, never committed.
    4. **Write the step into `docs/data-conventions.md` and the Makefile now**, not at the end. CI needs it too (T28), and its absence fails every test at *load*.
    5. This is a spike: no feature code. T2 onward is the real work.

### T2: The three ObjectBox entity classes
- **Files:** `lib/data/objectbox/ob_notebook.dart`, `ob_publication.dart`, `ob_chunk.dart` (new)
- **Effort:** Medium
- **Depends on:** T0
- **Satisfies:** FR1, FR2, FR3, FR5, FR6, FR7, FR9; AC1
- **Steps:**
    1. `ObNotebook`: `@Id() int id`, `@Index() String uuid`, `String title`, `DateTime createdAt`, `final publications = ToMany<ObPublication>()`.
    2. `ObPublication`: `@Id()`, `@Index() String uuid`, `String title`, `String sourceMarkdown`, `int byteSize`, `DateTime importedAt`, `String embeddingModelId`, `int chunkCount`, `@Backlink('publications') final notebooks = ToMany<ObNotebook>()`, `final chunks = ToMany<ObChunk>()`.
    3. `ObChunk`: `@Id()`, `int chunkIndex`, `String content`, `int tokenCount`, `@Index() int publicationId`, and the HNSW vector exactly as plan §C — `dimensions: 256`, `distanceType: cosine`, `neighborsPerNode: 16`, `indexingSearchCount: 100`, `@Property(type: PropertyType.floatVector) List<double> embedding`.
    4. **`@TargetIdProperty('publicationRef')` on the `ToOne` is mandatory (plan D1, spec defect 1).** ObjectBox auto-generates a target-ID property named `publicationId` for a `ToOne` called `publication`, which collides with the denormalised column and **fails codegen**. The rename frees the name. Verified working; do not "clean this up" later without re-running codegen.
    5. Declare dates explicitly as `@Property(type: PropertyType.dateUtc)` on `createdAt` and `importedAt`. This silences the generator's warning and, more importantly, makes ordering independent of the device timezone — FR ordering depends on it.
    6. **No `filePath` field** (FR3). If one appears, stop: it is the sketch this spec deliberately rejected.
    7. Constructors take required fields; no defaults that could mask a missing value.

### T3: Codegen, and confirm the committed artifacts
- **Files:** `lib/objectbox.g.dart`, `lib/objectbox-model.json` (generated, **committed**)

> **Path correction:** the generator writes to the package root — ObjectBox's default output directory — not next to the entities in `lib/data/objectbox/`. Recorded here so a later task does not "fix" the location.
- **Effort:** Small
- **Depends on:** T2
- **Satisfies:** NFR3, AC19; plan R5
- **Steps:**
    1. Run `dart run build_runner build`. Must succeed with **zero errors** — a `publicationId` name conflict here means T2 step 4 was reverted (plan R5).
    2. Commit both generated files, at `lib/`. NFR3 requires a fresh checkout to build **without** running codegen.
    3. Add **no** `.gitignore` rule for `*.g.dart` in `lib/data/objectbox/`. The repository-root Flutter template does not ignore them; verify rather than assume.
    4. Add a Makefile `codegen` target (`dart run build_runner build`) so the step is discoverable.
    5. Open `lib/objectbox-model.json` and confirm `dimensions: 256` and the `cosine` distance type landed. This is the check that codegen actually honoured the annotation.

### T4: Milestone 1 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T3
- **Satisfies:** AC1, AC19
- **Steps:**
    1. `dart run build_runner build` succeeds with zero errors.
    2. `flutter analyze` reports zero issues.
    3. `objectbox.g.dart` and `objectbox-model.json` are tracked by git.
    4. `git status` is clean after a fresh checkout with codegen **not** re-run.
    5. **Nothing outside `lib/data/objectbox/` imports `package:objectbox` yet.**

---

## Milestone 2 — Store lifecycle, domain models, and the repository swap

### T5: Domain models — pure values, no framework imports
- **Files:** `lib/models/publication.dart` (new), `lib/models/chunk.dart` (new), `lib/models/search_result.dart` (new)
- **Effort:** Small
- **Depends on:** T2
- **Satisfies:** NFR5; spec C3, D4
- **Steps:**
    1. `Publication`: `uuid`, `title`, `sourceMarkdown`, `byteSize`, `importedAt`, `embeddingModelId`, `chunkCount`. Immutable, `==`/`hashCode` by identity fields.
    2. `Chunk`: `publicationUuid`, `chunkIndex`, `content`, `tokenCount`, `embedding`. Note it carries the **uuid**, not the int id — the int id must not leak into the domain (FR5).
    3. `SearchResult`: `chunk` plus `distance`. Name the field `distance`, never `score` — ObjectBox's `score` is a distance where **smaller is nearer**, and a field called `score` invites the opposite comparison at the call site.
    4. **No `package:flutter`, no `package:objectbox`, no `package:objectbox/objectbox.g.dart`** in any of the three. T6's grep test enforces it.
    5. `lib/models/notebook.dart` is **unchanged**. It already satisfies NFR5 and the shell depends on its shape.

### T6: Entity ↔ domain mapping, both directions
- **Files:** `lib/domain_mapping.dart` (new)
- **Effort:** Small
- **Depends on:** T5
- **Satisfies:** NFR5; plan §E
- **Steps:**
    1. Every conversion between an `Ob*` entity and its domain value lives here and nowhere else. A conversion appearing in a repository is a layering leak.
    2. `toDomain` / `toEntity` for all three types.
    3. Do **not** map `ObChunk.publicationId` into the domain — the domain carries `publicationUuid`, resolved by the repository. The int id stays inside the data layer (FR5).
    4. Write `test/domain_model_purity_test.dart`: glob `lib/models/*.dart` and assert none imports `package:flutter` or `package:objectbox` (AC18). This test exists because the separation is easy to erode and invisible when eroded.

### T7: Store lifecycle — production and test constructors
- **Files:** `lib/data/objectbox/objectbox_store.dart` (new)
- **Effort:** Small
- **Depends on:** T3
- **Satisfies:** NFR2, NFR4; plan §F
- **Steps:**
    1. `Future<Store> openLibraryStore()` opening via the generated `openStore(getApplicationSupportDirectory())` — platform-agnostic, application-support directory (NFR2).
    2. `Store openTestStore([String tag = 'test'])` using `Store(getObjectBoxModel(), directory: '${Store.inMemoryPrefix}lib-$tag-${DateTime.now().microsecondsSinceEpoch}')`.
    3. **The timestamp is not optional.** `Store.inMemoryPrefix` alone reuses one in-memory database across tests in an isolate, so state leaks between them and failures become order-dependent. Verified working.
    4. **Nothing in `lib/data/` opens a store.** Opening is a bootstrap concern; that is what keeps tests free of filesystem concerns.
    5. Document in the file that a production store must be opened exactly once — ObjectBox refuses to open the same directory twice, and hot restart must not throw.

### T8: `ObjectBoxNotebookRepository` and the bootstrap swap
- **Files:** `lib/data/objectbox_notebook_repository.dart` (new), `lib/bootstrap.dart`, `lib/data/notebook_repository.dart`
- **Effort:** Medium
- **Depends on:** T7, T6
- **Satisfies:** FR5, FR18; D13, D14; AC22
- **Steps:**
    1. `ObjectBoxNotebookRepository implements NotebookRepository`, backed by `Box<ObNotebook>`. `uuid` is the app-level id (FR5, plan D14) — the existing `Notebook.id` string becomes a durable uuid rather than a new field, preserving the shell spec's D4 decision.
    2. `list()` ordered by `createdAt` ascending — the shell spec's FR8 and D5, unchanged.
    3. `exists(String id)` backs the router's synchronous `redirect` guard, so it **must stay synchronous**. `Box` is synchronous, so this costs nothing (plan I6). Do not make it async; `app_router.dart` cannot await.
    4. **Leave `NotebookRepository`'s interface signature untouched** and **keep `InMemoryNotebookRepository` and `seededRepository()` exactly where they are** (plan I7). `nav_state_machine_test.dart`, `notebook_flow_test.dart`, and `app_shell_widget_test.dart` all reference them by import; moving them forces edits and AC22 requires those tests to pass **unmodified**.
    5. `bootstrap.dart`: open the store before `runApp` (AGENTS.md Directive 6) and pass it down as a constructor argument. No service locator.
    6. Preserve the seeded-notebook behaviour exactly: three notebooks, stable titles (plan R10).
    7. Make the swap testable: `bootstrapDependencies()` already accepts overrides; keep that shape.

### T9: Milestone 2 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T8
- **Satisfies:** AC18, AC19, AC20, AC22
- **Steps:**
    1. **All seven existing shell tests pass unmodified** (AC22). This is the milestone's real gate — M2 adds almost no new test, and its job is that nothing the shell already asserts changes.
    2. `flutter analyze` reports zero issues.
    3. `test/domain_model_purity_test.dart` green (AC18).
    4. A clean checkout builds with codegen not re-run (AC19).
    5. `flutter run -d macos` launches and lists three notebooks from the real store.

---

## Milestone 3 — Publications, associations, and cascade

### T10: `PublicationRepository`
- **Files:** `lib/data/publication_repository.dart` (new)
- **Effort:** Medium
- **Depends on:** T8
- **Satisfies:** FR1, FR4, FR5, FR6, FR9; AC2, AC4, AC7
- **Steps:**
    1. `listForNotebook(String notebookUuid)` traversing `ObNotebook.publications` — the `ToMany` side, proving the association reads from the notebook.
    2. `byUuid(String)`.
    3. `attachments(String publicationUuid)` reading the `@Backlink` side. **Both directions are required** (AC2): a test that checks only one side passes against a broken `ToMany`.
    4. `embeddingModelIds()` and `byEmbeddingModel(String)` for FR6. Distinct ids come from an indexed scalar query, not from loading every publication.
    5. `sourceMarkdown` is read **only** by preview and re-chunk paths. No list or search method loads it (NFR6).

### T11: `LibraryRepository` — create, attach, detach, cascade
- **Files:** `lib/data/library_repository.dart` (new)
- **Effort:** Medium
- **Depends on:** T10
- **Satisfies:** FR4, FR11, FR12; AC3, AC5, AC12, AC13; plan R9
- **Steps:**
    1. `create({title, sourceMarkdown, embeddingModelId})`. **Reject empty or whitespace-only `sourceMarkdown` with a typed error before any write** (FR4, AC5).
    2. `byteSize` is the byte length of `sourceMarkdown`, **not** a file on disk (FR3, D8). Use UTF-8 byte length; `String.length` is UTF-16 code units and will disagree for any non-ASCII document.
    3. `attach` / `detach`: mutate the `ToMany` and `put` inside one transaction (FR11). Both **idempotent** — attaching an already-attached pair is a no-op, not a duplicate (AC3).
    4. `deletePublication`: remove chunks **and** the publication in one transaction; **leave every notebook intact** (FR12, AC12). A notebook that referenced it simply has one fewer publication.
    5. `deleteNotebook`: remove the association and **nothing else** (FR12, AC13). Publications and chunks shared with another notebook must survive. ObjectBox's `ToMany` makes the destructive path look natural — this is plan R9, and it is the one place over-deletion is user-visible.
    6. No path outside `replaceChunks` (T13) writes `chunkCount` or `publicationId` (plan R6).

### T12: Association and cascade tests
- **Files:** `test/publication_repository_test.dart` (new), `test/library_repository_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T11
- **Satisfies:** AC2, AC3, AC4, AC5, AC7, AC12, AC13
- **Steps:**
    1. All tests against `openTestStore()` (plan §F) — **no emulator, no fixture files** (AC20).
    2. **AC2**: one publication, two notebooks. Assert it appears in *both* `listForNotebook` results **and** in *both* `attachments` results. Two notebooks, one publication, both directions — this is the many-to-many proof and the reason D1 was chosen.
    3. **AC3**: attach three times, assert the association count is exactly 1. Assert the **count**, not merely that the call returns — a duplicate is invisible otherwise.
    4. **AC4**: create from markdown alone; read back `sourceMarkdown`, `title`, `byteSize`, `importedAt` **exactly**. Non-ASCII content, to catch the UTF-16/UTF-8 slip in T11 step 2.
    5. **AC5**: empty and whitespace-only `sourceMarkdown` both rejected, and the publication box count is unchanged.
    6. **AC7**: create, then delete the original file from disk (write a temp file, import it, `File.deleteSync`), then assert the publication and its chunks are intact and searchable.
    7. **AC12**: delete a publication; assert its chunks are gone and every notebook still exists.
    8. **AC13**: publication shared by two notebooks; delete notebook A; assert the publication **and its chunks survive and remain searchable from notebook B** (plan R9).

### T13: Milestone 3 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T12
- **Satisfies:** AC2, AC3, AC4, AC5, AC7, AC12, AC13
- **Steps:**
    1. `make test` green, including all seven unmodified shell tests.
    2. `make analyze` clean.
    3. Manual: create two notebooks, import the same markdown into one publication, attach to both, delete one notebook, confirm the publication and its chunks are still searchable from the other.
    4. Confirm no `filePath` field exists anywhere in `lib/`.

---

## Milestone 4 — Chunks and vector search

### T14: Typed vector validation at the write boundary
- **Files:** `lib/data/invalid_embedding_exception.dart` (new), `lib/data/library_repository.dart`
- **Effort:** Small
- **Depends on:** T11
- **Satisfies:** FR8; AC8; plan R7
- **Steps:**
    1. A **dedicated** exception type. `ArgumentError` would not distinguish "malformed vector" from "bad argument" at an ingestion boundary, and the chunker needs to catch exactly one case.
    2. Validate `embedding.length == 256` **before** `put`, in the repository, on every write path.
    3. **Why this is a hard requirement (plan R7, verified):** ObjectBox's HNSW index is configured for `dimensions: 256` and **silently ignores any vector with fewer dimensions.** A 128-dimension vector was measured to store successfully — no throw. The chunk then exists, counts, renders in a list, and is unfindable by search. Every user-visible surface except search looks correct.
    4. Also reject `Float64List` where a float32 vector is required, and reject non-finite values (`NaN`, `±inf`), which would otherwise poison the index graph.
    5. Do **not** "fix" a wrong-length vector by padding or truncating. Reject it; the caller owns the model contract.

### T15: `replaceChunks` — the transactional write path
- **Files:** `lib/data/library_repository.dart`
- **Effort:** Medium
- **Depends on:** T14
- **Satisfies:** FR7, FR9, FR10; AC9, AC10, AC11; plan R6, R8
- **Steps:**
    1. One `store.runInTransaction(TxMode.write, …)` containing: remove existing chunks for the publication → insert new chunks → update `chunkCount` → set each chunk's `ToOne` target **and** its denormalised `publicationId` (FR7).
    2. Both representations are written **together** and never separately (plan R6). AC9 asserts they never diverge.
    3. `chunkCount` is written **only** here (plan R8).
    4. A partially indexed publication must never be observable — that is the whole point of the transaction.
    5. Define `ChunkDraft` (a chunk not yet persisted) separately from the domain `Chunk`, so the write path has no ObjectBox types in its signature.

### T16: `SearchRepository` — one path for scoped and unscoped
- **Files:** `lib/data/search_repository.dart` (new)
- **Effort:** Medium
- **Depends on:** T15
- **Satisfies:** FR13, FR14, FR15, FR16, FR17; AC14, AC15, AC16, AC17; plan D2
- **Steps:**
    1. Signature takes `List<int> publicationIds` — **ObjectBox ids, not uuids** (plan I3). Resolution happens above. This keeps the vector path free of string lookups and stops the id/uuid distinction leaking inward (FR5).
    2. Build exactly the query the spec specifies:
       ```dart
       chunkBox.query(
         Chunk_.embedding.nearestNeighborsF32(queryVector, fetchCount)
             .and(Chunk_.publicationId.oneOf(publicationIds)),
       )
       ```
    3. **`fetchCount` is not `limit`** (FR15, plan D2). Implement `clamp(limit × ceil(2/fraction), limit, 1000)` where `fraction = scopeChunks / totalChunks`, defaulting to `1.0` when the scope is empty or unknown.
    4. **The `×2` safety factor is measured, not guessed.** At a 5% scope, `1/fraction` (=20) was insufficient: 2,000 chunks needed ×30, 20,000 chunks needed only ×15. `1/fraction` is a **lower bound**, and the shortfall is not a constant factor. The clamp bounds the other failure — an unbounded multiplier on a 1%-scope query over a large corpus would request more candidates than the corpus holds.
    5. Compute `fraction` with a cheap `count()` per scope, not by loading chunks (NFR6).
    6. Empty/absent scope searches everything, through the **same function** (FR13). No second implementation, so the two cannot drift.
    7. An empty scope matching nothing returns **empty, never an unscoped fallback** (FR16). Test it explicitly.
    8. **Close every `Query`** (FR17). ObjectBox holds native resources until close and explicitly discourages relying on finalizers.
    9. Map `ObjectWithScore` to `SearchResult` with the field named `distance`.

### T17: `chunk_repository_test.dart` — invariants and atomicity
- **Files:** `test/chunk_repository_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T15
- **Satisfies:** AC8, AC9, AC10, AC11; plan R7, R8
- **Steps:**
    1. **AC9**: write a mixed set of chunks across several publications, read every one back, assert `chunk.publicationId == chunk.publication.targetId` for all of them (plan R6).
    2. **AC8**: a 255-dimension and a 257-dimension vector are both rejected with the typed error, and **the chunk count is unchanged** — a partial write would defeat the test.
    3. A 128-dimension vector — the exact case verified to store silently — is rejected (plan R7).
    4. Non-finite values (`NaN`, `inf`) rejected.
    5. **AC10**: `chunkCount` correct after create, after re-index, and after a **failed** re-index, where the rollback leaves the prior count **and** the prior chunks.
    6. **AC11 — force a real rollback.** Throw from inside the transaction after some chunks are written; assert the prior chunks survive, the prior `chunkCount` survives, and the publication is still searchable. A transaction test that never provokes a rollback has not tested a transaction.
    7. Re-index is idempotent: running it twice leaves the chunk set identical, not doubled.

### T18: `search_repository_test.dart`
- **Files:** `test/search_repository_test.dart` (new)
- **Effort:** Large
- **Depends on:** T16
- **Satisfies:** AC14, AC15, AC16, AC17; plan D2, R4
- **Steps:**
    1. Seed a deterministic corpus with a seeded `Random` — no `Random()` without a seed, or failures are unreproducible.
    2. **AC14**: scoped search returns only in-scope chunks; unscoped returns chunks from all. Assert both through the same function (FR13).
    3. **AC15**: a scope matching nothing returns **empty**, and does **not** fall back to unscoped (FR16).
    4. **AC16 — the most important test in this spec. Read plan R4 first.**
       - Build the adversarial corpus **measured during planning**: 2,000 chunks across 20 publications, query vector near publication 19, scope pinned to publication 0. The naive implementation was measured to return **0 of 10** results here.
       - Assert `limit` results come back, **and assert the corpus shape**: if the unfiltered top-`limit` is already in scope, the test is vacuous and passes against the broken code. The test must be able to fail.
       - Add a companion assertion that the naive `fetchCount = limit` returns fewer than `limit`, so the test documents *why* over-fetching exists rather than only that results appear.
    5. **AC17**: results ordered by ascending distance; scores monotonically non-decreasing; an identical vector scores **lower** than an orthogonal one.
    6. Repeat AC16 at a larger corpus (20,000 chunks) to pin the multiplier's behaviour across scales — the measured shortfall was 1.5× at one size and 0.75× at the other.
    7. AC21: assert the suite runs leak-free (plan §F, FR17).

### T19: Milestone 4 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T18
- **Satisfies:** AC6, AC8–AC11, AC14–AC17
- **Steps:**
    1. `make test` green.
    2. **Temporarily set `fetchCount = limit` and confirm AC16 fails.** If it passes, the test is not adversarial and guards nothing — stop and fix the test, not the code. This is the cheapest possible check on the most important test.
    3. **Temporarily remove the length validation and confirm AC8 fails** with a stored-but-unfindable chunk rather than an exception.
    4. `make analyze` clean.
    5. Manual: import markdown, confirm chunks persist, search scoped and unscoped, delete the source file, search again — still works (AC6).

---

## Milestone 5 — Verification, CI, documentation, and the spec corrections

### T20: Query hygiene and locality audit
- **Files:** `lib/data/` (audit), fixes wherever it surfaces
- **Effort:** Small
- **Depends on:** T19
- **Satisfies:** AC21, AC23; NFR2, NFR6
- **Steps:**
    1. Every `Query` built in library code is closed on the path that built it (FR17). Audit each repository method individually.
    2. **No network call** in `lib/data/` (NFR2). No telemetry, no sync.
    3. **No platform-conditional schema logic** — no `Platform.is*` branch affecting fields, indices, or queries (NFR1, AC23). File access differs on mobile, but that lives in the importer, which is a Non-Goal.
    4. No list or search path loads `sourceMarkdown` (NFR6). Retrieval loads at most `fetchCount` chunks.
    5. No `dart:io` import in `lib/models/`.

### T21: `docs/data-conventions.md`
- **Files:** `docs/data-conventions.md` (new)
- **Effort:** Medium
- **Depends on:** T19
- **Satisfies:** the spec's purpose — conventions later specs plug into
- **Steps:**
    1. **The `install.sh` step first**, prominently — it is the thing that makes every test fail at load for a new contributor (plan R2).
    2. **The `@TargetIdProperty('publicationRef')` rename and why.** Renaming either side silently breaks FR7's flat-condition queries (plan R5). This is the most likely file in the repo to be "tidied" by mistake.
    3. **The `build_runner` upper bound and the `analyzer` conflict** (plan R1), so a future `pub upgrade` is not mistaken for a fix.
    4. **The over-fetch rule**: `fetchCount ≠ limit`, the measured multiplier table, and that `1/fraction` is a lower bound only (plan D2).
    5. **Vector validation at the boundary**, and that a wrong-length vector is *silently ignored* by HNSW rather than rejected (plan R7).
    6. Domain/entity separation and why: domain models stay free of `objectbox` and `flutter` (NFR5).
    7. The transaction rule — any write that could leave an inconsistency if interrupted runs in one transaction (FR10).
    8. Cascade semantics, and that `deleteNotebook` must never delete a shared publication (FR12, plan R9).
    9. The extension points later specs consume: `embeddingModelId` for a model change, `ChunkDraft` for the chunker, the embedding seam for the ONNX spec.

### T22: CI — flip the two assertions this spec inverts
- **Files:** `.github/workflows/ci.yml`
- **Effort:** Medium
- **Depends on:** T19
- **Satisfies:** AC19, AC20, AC22; plan R2
- **Steps:**
    1. **The existing `build-desktop` job asserts `! grep -q build_runner pubspec.lock` and `! grep -rq "part '.*\.g\.dart'" lib`. Both are now false and CI will fail until they are removed.** This spec is the first to add a codegen step and generated sources; the assertions encoded the previous "no generated files" state.
    2. Replace them with the inverse intent: assert `build_runner` **is** present, and that `lib/objectbox.g.dart` is tracked by git — AC19's "committed generated code" is the thing CI should now protect.
    3. **Add `bash install.sh` to the `analyze-and-test` job before `flutter test`.** Without it every test fails at load with a `dlopen` error that reads as a broken suite, not a missing setup step (plan R2).
    4. Add a Makefile `codegen` target invocation to a CI check, so a stale `objectbox.g.dart` — edited by hand, or generated from a since-changed entity — fails rather than silently shipping.
    5. Keep the desktop build matrix. It now also proves the ObjectBox native library links on macOS, Windows, and Linux (NFR1).
    6. **Note what CI still cannot verify:** no Android or iOS build job exists, so NFR1's mobile half is unverified here (spec Open Questions). Do not claim otherwise.

### T23: Correct the two spec defects at the source
- **Files:** `spec.md`
- **Effort:** Small
- **Depends on:** T19
- **Satisfies:** plan §"Spec defects found by verification"; AGENTS.md escalation rule
- **Steps:**
    1. **Defect 1 — FR7 and the FR2 schema.** The `Chunk` snippet declares both `int publicationId` and `ToOne<Publication> publication`; ObjectBox auto-generates a target-ID property named `publicationId` for that `ToOne`, so codegen **fails with a name conflict** and the snippet does not compile. Add `@TargetIdProperty('publicationRef')` and a note that the rename is mandatory.
    2. **Defect 2 — FR15.** "Proportional to scope selectivity" is under-specified. `1/fraction` was measured insufficient at a 5% scope (×30 needed at 2,000 chunks, ×15 at 20,000). Specify `clamp(limit × ceil(2/fraction), limit, 1000)` and state that `1/fraction` is a lower bound only. Carry the measurement table.
    3. Amend the C1–C3 corrections section to note that **verification during planning found two further defects in the spec's own remedy**, both now fixed.
    4. **Do not leave `spec.md` disagreeing with the implementation.** If the spec and the code diverge, the next spec inherits the wrong one.

### T24: Final gate
- **Files:** —
- **Effort:** Medium
- **Depends on:** T20, T21, T22, T23
- **Satisfies:** AC1–AC23
- **Steps:**
    1. `make analyze` reports zero issues.
    2. `make test` green, including the seven unmodified shell tests (AC22).
    3. Walk every acceptance criterion AC1–AC23 and record pass/fail against the running app. AC20 is satisfied by `flutter test` on the host; desktop cross-platform builds by CI.
    4. Confirm `spec.md` matches the implementation on FR7 and FR15 (T23).
    5. Confirm no `TODO` remains except explicitly deferred items.
    6. Confirm `lib/` contains no `filePath` and no `objectbox` import outside `lib/data/objectbox/`.
    7. Only then report status. **Do not claim mobile builds are verified** — no Android or iOS build exists in CI (T22 step 6).

---

## Traceability

| AC | Tasks |
|---|---|
| AC1 | T2, T3, T4 |
| AC2 | T10, T12, T13 |
| AC3 | T11, T12, T13 |
| AC4 | T10, T12 |
| AC5 | T11, T12 |
| AC6 | T19 |
| AC7 | T10, T12 |
| AC8 | T14, T17, T19 |
| AC9 | T15, T17 |
| AC10 | T15, T17 |
| AC11 | T15, T17 |
| AC12 | T11, T12, T13 |
| AC13 | T11, T12, T13 |
| AC14 | T16, T18 |
| AC15 | T16, T18 |
| AC16 | T16, T18, T19 |
| AC17 | T16, T18 |
| AC18 | T6, T9 |
| AC19 | T3, T4, T9, T22 |
| AC20 | T1, T9, T12, T18, T22 |
| AC21 | T16, T18, T20 |
| AC22 | T8, T9, T13, T22, T24 |
| AC23 | T20 |

## Effort summary

| Milestone | Tasks | Rough size |
|---|---|---|
| M1 — Dependencies, codegen, entities | T0–T4 | Medium |
| M2 — Store, domain models, repository swap | T5–T9 | Medium |
| M3 — Publications, associations, cascade | T10–T13 | Medium |
| M4 — Chunks and vector search | T14–T19 | **Large** |
| M5 — Verification, CI, docs, spec fixes | T20–T24 | Medium |

M4 is the large one: T18 in particular carries the spec's most consequential test.

## Deferred to later specs (not tasks here)

- **The chunker** — chunk boundaries, overlap, Markdown section parsing. Plugs in via `ChunkDraft` (T15).
- **ONNX inference** — model loading, task prefixes, Matryoshka truncation. Plugs in via the embedding seam.
- **`embeddingModelId`'s value space.** T14 validates against the constant 256. If the model spec lands a different dimension, `dimensions:` and FR8 change together — and changing `dimensions` **triggers a full HNSW re-index**.
- **Behaviour on model change** — re-index, prompt, or proceed. FR6 makes a mismatch detectable; the decision is the embedding spec's and must not be left implicit.
- **Hybrid search** — `content` stays unindexed (spec D9).
- **Reactive queries** — `Query.watch()` is the natural fit for a live sources list; nothing consumes it yet.
- **ObjectBox Sync.** The `ToMany` edge would synctractable nearly free. Explicitly out of scope.
- **A schema migration path.** No user data exists. Needed before the first *shipped* schema, not the first working one.
- **Corpus ceiling behaviour** and **backup/export** (spec Open Questions).
- **Android and iOS build verification** — NFR1's mobile half is unverified; no CI job exists.
