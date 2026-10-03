# Feature: Local-First Publication Data Layer

**Spec directory:** `1790958509972-publication-data-layer`
**Feature name:** `publication-data-layer`
**Revision:** 2 — three corrections found during implementation, escalated per `AGENTS.md`'s root-cause rule. FR7 did not compile; FR15's formula was measured insufficient; and FR13/FR16 contradicted each other on the empty-scope case. See [Corrections found during implementation](#corrections-found-during-implementation).

## Context

The shell spec (`1790815734133-add-menu`) built the app chrome and, deliberately, left notebook data in an in-memory repository behind a `NotebookRepository` interface. That interface is the seam this spec fills.

The product direction has since become concrete: a local-first RAG application. The user imports Markdown documents; the app chunks them, embeds each chunk on-device, and answers questions by retrieving the nearest chunks. The unit the user thinks in is a **notebook** (the shell already has one). The unit the app ingests is a **publication** (a `.md` file). The unit retrieval operates on is a **chunk**.

The relationship between the first two is the whole design question, and it is deliberately **not** one-to-one. A user comparing two papers wants the same paper in both notebooks. A user building a literature review wants one paper in three. The initial UI will only ever attach a single publication to a notebook, because that is the simplest thing to build; the database must not encode that restriction, because the day the UI grows a multi-select it must not require a re-ingest of every document in the user's library.

This spec covers **storage and the write-path contracts only**. The chunker algorithm and the ONNX embedding pipeline are separate specs that plug into the interfaces defined here.

### Two corrections to the originating brief

The brief this spec answers contained a schema sketch and a retrieval query. Both were checked against ObjectBox's actual Dart API and documentation, and both are wrong in ways that would have cost a migration or a silent-wrongness bug. Both are recorded in [Corrections](#corrections-to-the-brief) rather than quietly adopted.

## Goals

- Make notebook, publication, and chunk **durable** in an embedded store, replacing the in-memory `NotebookRepository` without changing the shell.
- Support **many-to-many** notebook↔publication association at the schema and repository level.
- Make the storage layer **platform-agnostic**, so one schema serves desktop and mobile.
- Guarantee that a publication's **source markdown is recoverable from the database alone**, so re-chunking and citation never depend on a file handle.
- Guarantee that **retrieval never mixes incompatible vectors**: every chunk records which embedding model produced it.
- Define the **write-path contracts** — transactions, idempotency, cascade behaviour — that the chunker and embedder will be written against.
- Make filtered vector search **correct and fast enough** to be the only search implementation.

## Non-Goals

- **No chunker.** Chunk boundaries, overlap, and Markdown section parsing are a later spec. This spec fixes only what a chunk *is* and what it must carry.
- **No embedding inference.** `onnxruntime_flutter`, model loading, task prefixes, and Matryoshka truncation are a later spec. This spec stores vectors and validates them.
- **No UI.** No publication picker, no sources page, no multi-select affordance. The one-publication-per-notebook limit is a UI constraint, not a schema one.
- **No hybrid search.** No BM25, no reciprocal rank fusion, no keyword prefilter. Pure vector retrieval only. The `content` field is indexed for future hybrid use but no text-query path is specified.
- **No chat.** Retrieval is specified; nothing consumes its output yet.
- **No sync, no cloud, no account.** The store is local to the device. ObjectBox Sync exists and is deliberately unused.
- **No migration framework.** ObjectBox evolves its model by UID-preserving property addition; there is no user data to migrate yet because there is no user data. A migration story is needed before the first shipped schema, not before the first working one.
- **No notebook renaming, reordering, or deletion semantics.** The shell spec deferred these; they are out of scope here too. Deletion *cascade* is specified (FR12) but no UI triggers it.

## Definitions

- **Notebook** — the user's workspace. Exists in the shell spec; becomes durable here. The unit the user navigates by.
- **Publication** — one imported source document. Holds its own source markdown. The unit the user imports and attaches.
- **Chunk** — one indexed slice of a publication, carrying exactly one embedding vector. The unit retrieval returns.
- **Association** — the many-to-many edge between a notebook and a publication. A publication may be attached to any number of notebooks and vice versa.
- **Embedding model id** — an opaque string naming the model *and configuration* that produced a vector (e.g. `nomic-embed-text-v1.5:int8:256`). Two vectors are only comparable if these match.
- **Scoped search** — vector search restricted to a subset of publications. Unscoped search is the degenerate case where the subset is every publication.

---

## Requirements

### Functional Requirements

- **FR1 — Four entities.** The store contains `Notebook`, `Publication`, `Chunk`, and `Document`, with the relations `Notebook —* Publication` (many-to-many) and `Publication —* Chunk` (one-to-many). No join table is materialised for the notebook↔publication edge; ObjectBox's `ToMany` is the join.

  `Document` exists because ObjectBox loads **whole objects** and NFR6 forbids list paths from reading the source text. Keeping the markdown on the `Publication` row would make every publication *list* read every document in the store. The text therefore lives in its own row, and list methods return a `PublicationSummary` projection that has no `sourceMarkdown` field at all — so a list caller cannot read the document even by mistake. See [correction 3](#3--fr2-and-nfr6-contradicted-each-other).

- **FR2 — Many-to-many is structural, not advisory.** The association is a true `ToMany` on the `Notebook` side with a matching `@Backlink` on `Publication`. It must be possible to attach one publication to two notebooks and to list, from either side, without a second schema change. Nothing in the schema may encode a cardinality of one.

  ```dart
  @Entity()
  class Notebook {
    @Id() int id = 0;
    @Index() String uuid;        // stable app-level identity, survives re-put
    String title;
    DateTime createdAt;
    final publications = ToMany<Publication>();
  }

  @Entity()
  class Publication {
    @Id() int id = 0;
    @Index() String uuid;
    String title;

    /// The document itself. The database is the record of truth.
    String sourceMarkdown;

    int byteSize;                 // length of sourceMarkdown in bytes
    DateTime importedAt;
    String embeddingModelId;      // see FR6
    int chunkCount;               // denormalised; see FR9

    @Backlink('publications')
    final notebooks = ToMany<Notebook>();
    final chunks = ToMany<Chunk>();
  }

  @Entity()
  class Chunk {
    @Id() int id = 0;
    int chunkIndex;               // 0-based, contiguous within a publication
    String content;
    int tokenCount;

    /// Denormalised from Publication. See FR7 — this is load-bearing.
    @Index() int publicationId;

    @HnswIndex(
      dimensions: 256,
      distanceType: VectorDistanceType.cosine,
      neighborsPerNode: 16,
      indexingSearchCount: 100,
    )
    @Property(type: PropertyType.floatVector)
    List<double> embedding;

    final publication = ToOne<Publication>();
  }
  ```

- **FR3 — No `filePath`.** The originating brief stored `filePath` and `fileSize`. `filePath` is **removed**: on iOS a picked file's path is not durably readable, and on Android the picker may return a content URI whose permission grant does not survive a relaunch. `byteSize` is retained, but measures `sourceMarkdown`, not the file on disk. Provenance is `title` plus `importedAt`; re-establishing a path is an import concern, not a storage one.

- **FR4 — Source markdown is stored, not referenced.** Every publication's complete source text is stored, in its own `Document` row (FR1). Consequences that are requirements, not observations:
  - Re-chunking after a chunker change is possible with no user action and no file access.
  - Citation and preview render from the store alone.
  - Deleting the original file has no effect on the publication.
  - A publication with an empty or whitespace-only `sourceMarkdown` is rejected at the write boundary and never persisted.

- **FR5 — Stable identity.** Both `Notebook` and `Publication` carry an application-level `uuid`, indexed, generated at creation and never reassigned. The `int` ObjectBox id is a storage detail and must not leak into routes, UI state, or cross-store references. This preserves the shell spec's D4 decision that a notebook's identity is an opaque app-owned id — it just becomes durable.

- **FR6 — Vectors carry their model.** Every `Publication` records `embeddingModelId`; every `Chunk` is reachable from exactly one publication and therefore inherits it. A chunk is only comparable with a query vector produced by the same id. The store must expose a way to enumerate the distinct model ids in use and to find publications indexed under a given id, so a model change can be detected and re-indexed rather than silently returning nonsense. **Silently mixing vectors from two models is the single worst failure mode this schema can have, and it is prevented structurally rather than by convention.**

- **FR7 — Chunk carries a denormalised `publicationId`.** `Chunk` has a real `ToOne<Publication>` *and* an indexed `int publicationId`. This is deliberate duplication, and it is the reason scoped search is expressible as a single flat condition:

  ```dart
  Chunk_.publicationId.oneOf(publicationIds)
  ```

  rather than a two-hop relation traversal. ObjectBox generates a hidden target-id property for every `ToOne`, and a relation condition is expressible against it — but the relation condition must be built through `QueryBuilder.link()`/`backlinkMany()`, which **cannot be combined with `nearestNeighborsF32` in a single `.and()` chain**. See [Corrections](#corrections-to-the-brief) C1. The denormalised indexed column sidesteps the limitation, makes the filter index-backed, and keeps the hot query a pure scalar-plus-vector condition.

  The `ToOne` **must** be annotated `@TargetIdProperty('publicationRef')`. ObjectBox auto-generates a target-ID property named `<toOneName>Id` for every `ToOne`, so a `ToOne` named `publication` generates `publicationId` — colliding with the column above and **failing codegen**. Verified: codegen succeeds with the rename.

  Invariant: `chunk.publicationId` always equals `chunk.publication.targetId`. Enforced by writing them together in one transaction (FR10). A unit test asserts they never diverge.

- **FR8 — Vector validation at the boundary.** The write path rejects a chunk whose embedding length is not exactly 256, and rejects a `Float64List` where a `Float32List` is required. ObjectBox's HNSW index is configured for `dimensions: 256` and **silently ignores any vector with fewer dimensions** — such a chunk is stored, invisible to search, and indistinguishable from a bug. Validation must happen before `put`, not be discovered through a missing search result.

- **FR9 — `chunkCount` is denormalised and maintained.** `Publication.chunkCount` is written in the same transaction as the chunks it counts (FR10). It exists so a publication list renders without loading every chunk. Invariant: `publication.chunkCount` equals the number of chunks whose `publicationId` equals it.

- **FR10 — Publication write is one transaction.** Creating or replacing a publication's chunks — remove-all-then-insert, as a re-index or a re-chunk — happens inside a single `store.runInTransaction(TxMode.write, …)` that also updates `chunkCount` and the `ToOne` targets. A partially indexed publication is never observable. If the transaction throws, the publication's previous chunk set survives intact.

- **FR11 — Association writes are idempotent.** `attach(publication, notebook)` is idempotent: attaching an already-attached pair is a no-op, not a duplicate. `detach` likewise. Both are single-transaction operations. This holds because the association is a `ToMany` and ObjectBox models it as a relation set.

- **FR12 — Cascade on delete is explicit and never over-deletes.** Deleting a `Publication` removes its chunks in the same transaction, and leaves every `Notebook` intact — a notebook that referenced it simply has one fewer publication. Deleting a `Notebook` removes the association and **never** deletes publications or chunks, because those may be attached to other notebooks. This is the concrete reason the many-to-many shape is worth the extra complexity: the one-to-many shortcut would force either orphaned vectors or accidental data loss.

- **FR13 — Scoped and unscoped search are one code path.** `search({required List<int>? publicationIds, required List<double> queryVector, required int limit})` takes a **nullable** scope, and the nullability is load-bearing:

  - `null` — no scope was requested; search the whole corpus.
  - `[]` — a scope *was* requested and matches nothing; return nothing (FR16).

  There is no separate unscoped implementation, so the two cannot drift. Treating `[]` as "everything" would make a search scoped to a deleted notebook, or to one with no publications, return the entire corpus — the worst failure this interface could have. See [correction 2](#2--fr13-and-fr16-contradicted-each-other-on-the-empty-scope-case).

- **FR14 — The query shape is specified, not sketched.** Retrieval is exactly:

  ```dart
  final q = chunkBox.query(
    Chunk_.embedding.nearestNeighborsF32(queryVector, fetchCount)
        .and(Chunk_.publicationId.oneOf(publicationIds)),
  );
  final results = q.findWithScores();
  ```

  with three properties that the next FR makes load-bearing: `findWithScores()` returns results **ordered by distance ascending**, the score is a **distance** (lower is nearer, not higher-is-better), and `nearestNeighborsF32`'s `maxResultCount` bounds only the ANN sub-query, **not** the final result count. See [Corrections](#corrections-to-the-brief) C2.

- **FR15 — Search over-fetches to survive the filter.** Because the filter is applied *after* the ANN sub-query, `maxResultCount` must exceed the requested `limit` or a scoped search silently returns fewer than `limit` results — including zero, for a narrowly-scoped query over a large corpus. The retrieval path never passes `limit` directly.

  The formula is **measured**, not guessed:

  ```
  fetchCount = clamp(limit × ceil(2 / scopeFraction), limit, 1000)
  ```

  where `scopeFraction = scopeChunks / totalChunks`, and `1.0` when there is no scope. On a 5%-scope corpus, `1 / fraction` (= 20) was insufficient: 2,000 chunks needed a ×30 multiplier and 20,000 chunks needed only ×15. **`1 / fraction` is a lower bound, not a guarantee**, and the shortfall is not a constant factor — it moved with corpus size. The `×2` safety factor clears both measurements; the `1000` clamp bounds the opposite failure, where an unbounded multiplier on a 1%-scope query over a large corpus would request more candidates than the corpus holds.

  This is a correctness requirement with an observable symptom (short result sets), not a tuning knob.

- **FR16 — Empty scope returns empty, not everything.** A search scoped to publication ids that match nothing returns an empty list. It does not fall back to unscoped search. A caller that wants "everything" asks for everything (FR13).

- **FR17 — Queries are closed.** Every `Query` is closed on the path that built it. ObjectBox holds native resources until close; relying on finalizers is explicitly discouraged upstream.

- **FR18 — The repository seam is preserved.** `NotebookRepository` keeps its existing shape as the *notebook-facing* interface. New interfaces — `PublicationRepository`, `ChunkRepository` or a combined `LibraryRepository` — sit alongside it. The shell is not modified. The in-memory implementation is retained as a test double so the existing shell tests keep passing unchanged.

### Non-Functional Requirements

- **NFR1 — Schema is platform-agnostic.** One schema and one set of repository implementations serve macOS, Windows, Linux, iOS, and Android. No per-platform schema divergence and no platform-conditional field. Where mobile *does* change behaviour — chiefly file access at import time — the difference lives in the importer, which is a Non-Goal here, not in the store.

- **NFR2 — Locality.** Everything is on-device. No network call in the data layer, no telemetry, no sync. The store is opened in the platform's application-support directory.

- **NFR3 — Generated code is committed and reproducible.** The ObjectBox model (`objectbox.g.dart`, `objectbox-model.json`) is generated by `objectbox_generator` via `build_runner` and committed. A fresh checkout builds without running codegen. The generated files are never hand-edited.

- **NFR4 — Testable without a device.** The store opens against ObjectBox's in-memory mode (`Store.inMemoryPrefix`) in tests, so every repository contract is exercised in a plain `flutter test` on the host with no emulator and no fixture files. Schema-shape assertions (HNSW dimensions, index presence, `ToMany`/`@Backlink` pairing) run against the generated model, not against a live store, so a codegen regression fails loudly.

- **NFR5 — Domain models stay Flutter-free.** `Notebook`, `Publication`, and `Chunk` as *domain* values live in `lib/models/` with no `package:flutter` and no `package:objectbox` import, matching the shell spec's convention. ObjectBox entity classes are separate, in `lib/data/objectbox/`, and map to the domain values. This keeps the models unit-testable with a bare `test()` and keeps annotation-bearing storage classes out of the domain layer. **This is a departure from the brief's sketch, which annotated the domain classes directly** — it is recorded as C3.

- **NFR6 — Bounded memory on read.** Retrieval loads at most `fetchCount` chunks. A publication's source markdown is not loaded by any list or search path; it is read only for preview and re-chunk. This is enforced structurally, not by convention: the text lives in its own `Document` row (FR1) and list methods return a `PublicationSummary` type that has no `sourceMarkdown` field. The 100–150 MB peak-indexing ceiling is an ingestion concern, but the read path must not be the thing that breaches it.

- **NFR7 — Deterministic ordering where the UI depends on it.** Notebooks order by `createdAt` ascending, preserving the shell spec's FR8 and D5. Publications and chunks order by `importedAt` / `chunkIndex` ascending. Vector search results are distance-ordered by ObjectBox (FR14).

## Storage Budget

Derived, and stated so the target can be checked rather than assumed.

| Quantity | Value | Derivation |
|---|---|---|
| Embedding bytes | 1,024 B | 256 dims × 4 B (float32) |
| `Chunk` metadata | ~60–100 B | ints, one string pointer, HNSW graph adjacency |
| Total per chunk | **~1.1–1.2 KB** | The brief's 1.02 KB counts the vector only |
| 10,000 chunks | ~11 MB | 10,000 × 1.1 KB |
| 100,000 chunks | ~110 MB | The practical ceiling before re-evaluation |

The brief's ~1.02 KB/chunk is the vector alone. Real per-chunk cost includes HNSW adjacency lists (`neighborsPerNode: 16`, plus backlinks) and the `content` string, so the honest figure is ~1.1–1.2 KB. The order of magnitude holds; the precise figure in the brief does not.

## Acceptance Criteria

- [ ] **AC1:** The store contains exactly four entities — `Notebook`, `Publication`, `Chunk`, `Document` — with `Notebook.publications` as a `ToMany` and `Publication.notebooks` as a matching `@Backlink('publications')`. Codegen emits no error, and `ObChunk.publication` carries `@TargetIdProperty('publicationRef')`.
- [ ] **AC2:** One publication attached to two notebooks appears in both notebooks' publication lists, and both notebooks appear in the publication's notebook list. No schema change and no re-ingest is involved.
- [ ] **AC3:** `attach`/`detach` are idempotent. Attaching the same pair three times leaves exactly one association; a test asserts the count, not just that the call returns.
- [ ] **AC4:** `Publication` has no `filePath` field. A publication created from markdown text alone round-trips its `sourceMarkdown`, `title`, `byteSize`, and `importedAt` exactly.
- [ ] **AC5:** A publication whose `sourceMarkdown` is empty or whitespace-only is rejected by the write path and is not persisted.
- [ ] **AC6:** A publication created from markdown text alone survives deleting the original file from disk, and its chunks remain searchable.
- [ ] **AC7:** Every `Publication` exposes a non-empty `embeddingModelId`, and the store can enumerate distinct model ids and list the publications under each.
- [ ] **AC8:** A chunk whose embedding length ≠ 256 is rejected at the write boundary with a typed error, and nothing is written.
- [ ] **AC9:** For every chunk in the store, `chunk.publicationId == chunk.publication.targetId`. A test writes a mixed set and asserts the invariant holds after read-back.
- [ ] **AC10:** `Publication.chunkCount` equals the actual chunk count after create, after re-index, and after a **failed** re-index — where the failure leaves the previous chunk set and the previous count intact.
- [ ] **AC11:** Replacing a publication's chunk set is atomic. A transaction that throws partway leaves the prior chunks, the prior count, and a searchable publication. A test forces a throw mid-transaction and asserts all three.
- [ ] **AC12:** Deleting a publication removes its chunks and leaves every notebook intact.
- [ ] **AC13:** Deleting a notebook removes only the association. Publications and chunks shared with another notebook survive and remain searchable from that other notebook.
- [ ] **AC14:** Scoped search returns only chunks from the requested publications. Unscoped search (empty scope) returns chunks from all of them. Both run through the same function.
- [ ] **AC15:** Scoped search with ids matching nothing returns empty — never an unscoped fallback.
- [ ] **AC16:** A scoped search over a large corpus with a narrow scope returns exactly `limit` results when `limit` in-scope chunks exist. A test constructs the adversarial case — a narrow scope inside a corpus large enough that the unfiltered top-`limit` would be entirely out-of-scope — and asserts `limit` results are returned. This is the FR15 over-fetch guard, and it is the single most important search test in the spec.
- [ ] **AC17:** Results are ordered by increasing distance, and the returned score is a distance where **smaller means nearer**. A test asserts monotonic non-decreasing scores and that a known-identical vector scores lower than a known-orthogonal one.
- [ ] **AC18:** Domain models in `lib/models/` import neither `package:flutter` nor `package:objectbox`; a test parses the **import directives** (not the raw source, since the doc comments discuss the rule in prose) so the separation cannot regress silently. `PublicationSummary` is a projection rather than a domain value, so the Flutter ban does not apply to it — the ObjectBox ban still does.
- [ ] **AC19:** The generated `objectbox.g.dart` and `objectbox-model.json` are committed, and a clean checkout builds with codegen not re-run.
- [ ] **AC20:** Every repository test runs against an in-memory store in a plain `flutter test` on the host, with no emulator, no device, and no fixture files.
- [ ] **AC21:** Every `Query` built in library code is closed on its own path. A test exercises each repository method and the suite passes without leaked-resource warnings.
- [ ] **AC22:** The existing shell tests pass **unmodified** against the durable repository, with `InMemoryNotebookRepository` retained as a test double.
- [ ] **AC23:** The data layer contains no network call and no platform-conditional schema logic. Verified by inspection of `lib/data/`.

---

## Resolved Decisions

| # | Question | Resolution | Why |
|---|---|---|---|
| **D1** | One-to-one or many-to-many between notebook and publication? | **Many-to-many**, via `ToMany` + `@Backlink`. | Asked for explicitly. Costs one extra relation and buys a comparison workflow and a literature-review workflow with no re-ingest. |
| **D2** | Should the one-publication UI limit be enforced in the schema? | **No.** It is a UI constraint. | Enforcing it in the schema would mean a migration the moment multi-select ships, and a migration means re-embedding every chunk in the user's library. |
| **D3** | `filePath` or `sourceMarkdown`? | **`sourceMarkdown`**; no `filePath`. | A picked file's path is not durably readable on iOS, and an Android content URI's grant does not survive a relaunch. Storing the text makes re-chunk, preview, and citation work offline from the database alone. |
| **D4** | Annotate the domain models directly, as the brief sketched? | **No.** Separate ObjectBox entity classes in `lib/data/objectbox/`. | Domain values stay Flutter-free and ObjectBox-free, matching the shell spec's `lib/models/` convention and keeping them testable with a bare `test()`. |
| **D5** | Query through the `ToOne` relation, or a denormalised `publicationId`? | **Denormalised indexed `int`.** | The relation condition cannot be `.and()`-ed with `nearestNeighborsF32`; the flat column makes scoped search a pure scalar+vector condition on an index. Duplication is kept honest by FR7's invariant and its test. |
| **D6** | What is a chunk's identity? | `(publicationId, chunkIndex)`, with the publication's `uuid` as the app-level handle. | `chunkIndex` alone is not unique. Together they give a natural idempotency key for re-indexing. |
| **D7** | How is "these vectors are not comparable" prevented? | `embeddingModelId` on `Publication`, structurally. | Convention fails. A model swap that silently mixes vector spaces returns confident nonsense, and nothing in the data would reveal it. |
| **D8** | Store `fileSize`? | Yes, but as `byteSize` of `sourceMarkdown`. | Retains the size signal for UI and budget checks without implying a file on disk. |
| **D9** | Should `content` be indexed for hybrid search? | **Not now.** Unindexed string. | Hybrid retrieval is a Non-Goal. Adding a text index later is cheap and non-breaking; adding one now costs write throughput and index size for a feature nobody specified. |
| **D10** | Distance type? | `cosine`, per the brief. | Vectors are L2-normalised after Matryoshka truncation, so cosine and euclidean rank identically — the choice is not load-bearing, and `cosine` is the safer default if normalisation is ever skipped. |
| **D11** | HNSW parameters? | `dimensions: 256`, `neighborsPerNode: 16`, `indexingSearchCount: 100`. | Per the brief. Note `indexingSearchCount` is the correct name — the brief's `indexingSearchLimit` does not exist and would not compile. All three trigger re-indexing when changed, so they are constants, not runtime config. |
| **D12** | One store or one store per notebook? | **One store.** | Per-notebook stores make cross-notebook retrieval and shared publications structurally impossible — the opposite of D1. |
| **D13** | Replace `NotebookRepository` or extend it? | **Extend.** Keep it as the notebook-facing seam. | The shell spec made it the seam precisely so this swap would be additive. |
| **D14** | Should `Notebook.uuid` replace the existing opaque `id`? | **Reuse the concept; keep one field.** | The shell spec's D4 already decided a notebook's identity is an opaque app-owned string. It just becomes durable now. |
| **D15** | Platform? | **All five**, one schema. | Desktop builds exist today and must keep working; mobile is the product direction. The schema need not know the difference. |

---

## Corrections to the brief

Three items in the originating brief were checked against ObjectBox's Dart API and documentation and would not have worked. They are recorded because each would have surfaced as a migration or a silent bug rather than a compile error.

### C1 — The retrieval query does not compile

The brief's example:

```dart
// NOT valid Dart
chunkBox.query(
  Chunk_.embedding.nearestNeighbors(queryVector, 10)
      .and(Chunk_.publication.link(Publication_.uuid.oneOf(selectedPubUuids)))
)
```

`link()` is not a condition and produces nothing you can `.and()`. In ObjectBox's Dart API, relation traversal is a **`QueryBuilder` method** (`link()`, `linkMany()`, `backlink()`, `backlinkMany()`) that re-targets the builder at another entity — `QueryBuilder<Chunk>` becomes `QueryBuilder<Publication>`. It cannot participate in a boolean condition chain, and therefore cannot be combined with `nearestNeighborsF32` in one query. Compiling this needs two chained builder calls with no way to also carry the vector condition.

FR7's denormalised `publicationId` exists to avoid this entirely. The brief also had the direction backwards: filtering chunks by *publication* is a `ToOne` hop, but filtering by *notebook* — which is what a many-to-many schema actually requires — is a two-hop traversal through a `ToMany`, and that is precisely the case that cannot be expressed as a condition at all.

### C2 — `maxResultCount` is not the result count

The brief passes `10` as `maxResultCount` and expects top-10. ObjectBox applies `maxResultCount` to the **ANN sub-query only**; the additional condition filters those candidates afterwards. This is documented behaviour and was the subject of a maintainer-confirmed issue. The consequence is that a scoped search returns **fewer than 10 results, possibly zero**, whenever the unfiltered nearest neighbours happen to fall outside the scope. A query for one small publication inside a large library can return nothing at all and look like a broken index.

FR15 requires over-fetching proportional to scope selectivity. Without it, scoped search — the app's primary mode — is unreliable in exactly the situation it exists to serve.

### C3 — `indexingSearchLimit` is not a parameter

The brief's annotation uses `indexingSearchLimit: 100`. The `HnswIndex` constructor accepts `dimensions`, `neighborsPerNode`, `indexingSearchCount`, `flags`, `distanceType`, `reparationBacklinkProbability`, and `vectorCacheHintSizeKB`. There is no `indexingSearchLimit`. FR2 uses `indexingSearchCount`.

---

## Corrections found during implementation

Three defects in revision 1 were found while building this, and are corrected here per `AGENTS.md`'s escalation rule rather than absorbed silently in the code. Two would have shipped as silent wrongness; one would not have compiled.

### 1. FR2 and NFR6 contradicted each other

FR2 stored `sourceMarkdown` on the `Publication` row, while NFR6 required that no list or search path load it. Both are right in isolation and **unsatisfiable together**, because ObjectBox loads whole objects — a document on the publication row is read by every publication list.

Resolved at the source: the text moves to its own `Document` row (FR1, FR4), and list methods return a projection with no text field. This adds an entity and a join, and makes NFR6 true rather than aspirational.

### 2. FR13 and FR16 contradicted each other on the empty-scope case

FR13 said an empty scope searches everything; FR16 said an empty scope returns nothing. A notebook with no publications resolves to an empty scope, so the implementation had to pick — and picking FR13's reading meant **a search scoped to a deleted notebook returned the entire corpus**.

Resolved at the source: the scope is nullable. `null` means "no scope", `[]` means "an empty scope". FR13 and FR16 now describe disjoint cases.

### 3. The brief's `chunkIndex` and vector-type assumptions

`indexingSearchLimit` (already C3) and, in addition, a `Float64List` would round-trip as float32 anyway — accepting it silently loses precision, so wrong element types are rejected alongside wrong lengths.

### Also corrected: FR7 did not compile

FR7 declared both `int publicationId` and `ToOne<Publication> publication`. ObjectBox auto-generates a target-ID property named `publicationId` for that `ToOne`, so codegen failed with a name conflict. Fixed by mandating `@TargetIdProperty('publicationRef')`, now stated in FR7 itself so the next reader does not remove it.

---

## Open Questions

Genuinely undecidable without a later spec or an external decision:

- **The embedding model's actual dimensions and identity string.** FR6 and FR7 both assume 256. `nomic-embed-text-v1.5` truncated to 256 and `ModernBERT-small-embed` are different models with different truncation behaviour, and the choice determines `embeddingModelId`'s value space. Blocked on the ONNX integration spec.
- **What happens when the embedding model changes.** FR6 makes the mismatch *detectable*. It does not decide whether the app re-indexes automatically, prompts, or silently mixes. That is a product decision for the embedding spec, and it should not be left implicit — silently mixing is the failure FR6 exists to make visible.
- **Chunk boundary semantics.** `chunkIndex` is required to be contiguous and 0-based (FR2), which is a contract the chunker must honour. The chunker may later want stable ids across re-chunks for citation anchoring; if so, that is a schema addition, not a change.
- **Corpus ceiling and eviction.** NFR7's budget puts the practical limit near 100,000 chunks. What the app does at the ceiling — refuse, evict oldest, warn — is undecided.
- **Full-text search as a hybrid component.** `content` is stored and unindexed. If hybrid retrieval is later specified, it needs a text index and a scoring decision; neither is free.
- **Store corruption and backup.** A single local store with no sync has no recovery story. ObjectBox's file is transactional, but device loss is device loss. Whether a local export/backup exists is undecided and outside this spec.
- **Whether `Notebook` and `Publication` need eventual sync.** ObjectBox Sync would make the many-to-many edge synctractable for free, but brings a server, identities, and conflict resolution. Explicitly out of scope; recorded because D1's shape happens to survive it.
