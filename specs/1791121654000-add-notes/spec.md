# Feature: Notes — Add, Read, Edit, and Embed

**Spec directory:** `1791121654000-add-notes`
**Feature name:** `add-notes`
**Builds on:** [`1790958509972-publication-data-layer`](../1790958509972-publication-data-layer/) (entities, transactions, invariants), [`1790968315311-peer-sync`](../1790968315311-peer-sync/) (payload, DTOs, versions, tombstones, delta selection, ingest), [`1791055194089-delete-notebooks`](../1791055194089-delete-notebooks/) (notebook cascade, tombstone-on-delete), [`1791079931744-settings-for-ai`](../1791079931744-settings-for-ai/) (the pattern for adding a fifth entity to the payload).
**Amends:** publication-data-layer and peer-sync — see [Amendments to prior specs](#amendments-to-prior-specs). The notebook delete cascade grows to include notes, and the sync payload grows a sixth record type.
**Status:** the `Notes` section exists in the detail navigation but is disabled (`lib/models/notebook_section.dart`). This spec enables it and gives the notebook detail page its first real content.

## Context

The app can collect source publications and search them, but the user cannot yet
write anything down. A research notebook is half research and half **notes** — the
user's own thinking, connected to the sources. This spec adds that half.

Three facts about the existing codebase shape the design:

1. **The data layer already knows how to store, chunk, version, and sync a
   text-bearing entity with a vector index.** A note is structurally the same
   shape as a publication: a uuid, user text, a set of derived chunks each
   carrying one embedding, a many-to-many edge to notebooks, and three
   independently-versioned sync axes (metadata + edges, document text, chunk
   set). Rather than invent a parallel mechanism, this spec **mirrors the
   publication grammar** and reuses its write-path contracts.

2. **There is no chunker and no embedder.** The data-layer spec deliberately
   deferred embedding inference and chunk boundaries to a "later spec"
   (`publication-data-layer` Non-Goals; its Open Questions are blocked on "the
   ONNX integration spec"). The note body is the first surface that actually
   needs both, so **this feature defines those seams** and the ONNX-backed
   implementation behind them. This spec is the ONNX integration spec the data
   layer was waiting for. The concrete stack is now **pinned** rather than
   deferred: `nomic-embed-text-v1.5` exported and quantised to ONNX, executed by
   `onnxruntime`, tokenised by Hugging Face `tokenizers` over Rust FFI, and
   Matryoshka-truncated to the 256 dimensions ObjectBox already indexes. See
   [The pinned embedding stack](#the-pinned-embedding-stack).

3. **A note's vectors are only meaningful against a single active model.** The
   peer-sync `embeddingModelId` gate exists precisely because mixing two models'
   vectors returns confident nonsense with no trace in the data
   (`docs/sync-conventions.md`). A note therefore records its
   `embeddingModelId` exactly as a publication does, and the embedder's model id
   is the single source of truth shared with `SyncApplier`.

The chat panel is the **display shell** for a future retrieval conversation. This
feature establishes its layout and nothing more.

## Goals

- Let the user create, read, and edit **notes** in a notebook.
- Store a note durably: an optional title, a body, `createdAt`, `updatedAt`, and
  a many-to-many edge to notebooks.
- **Regenerate a note's embeddings when, and only when, its body changes** — and
  never when only its title or an association edge changes.
- Define the **chunker and embedder seams** and pin the ONNX stack
  (`nomic-embed-text-v1.5` → `onnxruntime`, Rust `tokenizers` FFI, MRL-truncated
  to the 256 dimensions the HNSW index requires).
- Make a note a first-class **syncable record** with the same uuid/version/
  tombstone discipline as publications, including the chunk-set/model gate.
- Give the notebook's disabled **Notes section** a working list and an editor
  with explicit Save/Cancel semantics.
- Lay out a collapsible **chat panel** on the right of the note editor, define
  the minimal **chat message record** it renders, and provide a **note-scoped
  retrieval path** over the note's chunks.

## Non-Goals

- **No change to publication retrieval.** A **note-scoped** search path over
  `ObNoteChunk` is in scope (D30), reusing the `FetchBudget` over-fetch. The
  existing publication `SearchRepository` and its results are unchanged, and the
  two indexes are never queried together.
- **No chat behaviour.** A **minimal message entity and its rendering** are in
  scope (D31): the panel shows the note's stored messages. The behaviour of
  composing and sending a message, of answering one, and of orchestrating the AI
  — both implementation and requirements definition — remains beyond the scope
  of this feature. This feature establishes the chat's data shape and display
  surface. See FR31–FR34.
- **No rich-text editing.** The editor is a plain multi-line text box. Markdown
  is typed as text; no bold/italic toolbar, no syntax highlighting, no rendered
  preview.
- **No cross-notebook linking UI.** The schema is many-to-many (FR3) and the UI
  creates one association by default; the affordance to attach one note to a
  second notebook is a later feature. The schema must not need a migration when
  it ships.
- **No re-index on model change *in this feature*.** A model change makes old
  note vectors incomparable exactly as it does publication vectors; the mismatch
  is surfaced (FR36). Automatic re-indexing of stale notes is the committed
  direction, to be specified later (D27).
- **No note deletion UI.** Cascade semantics are specified (FR14, FR15) so the
  notebook delete stays correct; no trash-can affordance is added here.
- **No chat panel persistence.** The right panel's collapsed/expanded state is
  transient per session and is not written to disk (D26).

## Definitions

- **Note** — one user-authored document: an optional title, a body, a creation
  date, an update date, and a set of derived chunks. The unit the user writes.
- **Body** — the note's text. The **only** input to chunking and embedding. An
  empty or whitespace-only body is valid and yields zero chunks.
- **Metadata** — a note's title and its notebook association edges. Never an
  input to chunking.
- **Regenerate** — replace a note's entire chunk set: remove every existing
  `NoteChunk` and insert a freshly chunked and embedded set, in one transaction
  (mirrors publication-data-layer FR10).
- **Dirty** — the editor's title or body differs from the last saved values.
  A note with `dirty == false` shows no Save and no Cancel.
- **Chunker** — the seam that turns a body string into an ordered list of
  `(index, content, tokenCount)` text chunks. Default: a sliding word window
  (FR6).
- **Embedder** — the seam that turns text into a 256-dimension, finite,
  L2-normalised vector, applies the model's task prefix, and names the model that
  produced it. Pinned implementation: `OnnxEmbedder` over `nomic-embed-text-v1.5`
  (FR7, FR8).
- **Note chunk set version / note metadata version / note document version** —
  the three independent sync axes a note inherits from the publication model
  (`docs/sync-conventions.md`, "The two versions, and three axes").
- **Note-scoped search** — vector retrieval restricted to one note's chunks,
  over the `ObNoteChunk` index. The note analogue of publication scoped search.
- **Message** — a minimal chat record attached to a note: a role, text, and a
  creation time. Local-only in this feature (FR34).

## The pinned embedding stack

This feature resolves the `publication-data-layer` Open Question ("the embedding
model's actual dimensions and identity string … Blocked on the ONNX integration
spec") by pinning one stack for all five targets. Everything here is a
requirement, not a suggestion.

| Component | Choice | Notes |
|---|---|---|
| Model | `nomic-ai/nomic-embed-text-v1.5` | 8,192-token context; native 768 dims |
| Dimensions in the index | **256** (MRL truncation) | Must equal `VectorGeometry.dimensions` and the HNSW `dimensions` (FR4) |
| Runtime | `onnxruntime` (Dart) | Session opened once, cached (FR8, NFR7) |
| Tokenizer | Hugging Face `tokenizers` via Rust FFI | `flutter_rust_bridge`; avoids a Dart tokenisation loop (FR8) |
| Quantisation | Dynamic INT8, **one portable file** | Runs on x86-64 and ARM (D22); ~150 MB budget (D32) |
| Task prefixes | `search_document: ` / `search_query: ` | Mandatory; applied inside the `Embedder`, never by the caller (FR7) |
| Pooling | Mean pooling over the attention mask, then MRL slice, then L2 normalise | Order is load-bearing (FR8) |
| Store | ObjectBox HNSW, cosine | Already configured in `ObNoteChunk` (FR4) |

**Artefact layout** (paths relative to the repository root; the Rust crate follows
`flutter_rust_bridge`'s convention):

```text
assets/
  models/nomic_embed_text_v1.5_quantized.onnx
  tokenizers/tokenizer.json
native/rust_tokenizer/          # Rust cdylib/staticlib crate + FFI bridge
lib/bridge/                     # generated FFI bindings (never hand-edited)
lib/data/embedding/             # TextChunker, Embedder, OnnxEmbedder, NoteIndexer
```

The blueprint's `lib/objectbox/` and `lib/services/` locations are **not** adopted:
this repository keeps annotated entities in `lib/data/objectbox/`, domain values
in `lib/models/`, and infrastructure under `lib/data/` (AGENTS.md; README
"Architecture"). The blueprint's single `DocumentChunk` entity is likewise
superseded by `ObNoteChunk` plus the enumerated reference sites (FR21), which a
plain `documentId` string column would not satisfy.

### Corrections to the blueprint

The supplied plan is sound in its stack and its inference maths. Four points are
recorded because each would have regressed a rule this repository already
enforces.

1. **`--quantize avx512_vnni` is x86-only.** It produces a model that will not run
   correctly, or at all, on Apple Silicon, iOS, or Android ARM. The export must
   produce a **portable** artefact (dynamic INT8) or one artefact per
   architecture. This is a build-matrix requirement, not a flag tweak. See Risks.
2. **`maxTokens: 400` in the blueprint's chunker counts words, not tokens.** The
   loop is `words.sublist(i, end)`, so the parameter name overstates the window
   by the token-to-word ratio (~1.3×). FR6 makes the unit explicit and computes a
   real `tokenCount` per chunk from the tokenizer.
3. **`Isolate.run()` per ingestion reloads the model every call.** A fresh
   isolate does not share the parent's `OrtSession`, so `Isolate.run` would pay
   the model-load cost on every note. FR9/NFR7 require a **long-lived worker
   isolate** that owns its session and is reused; the Rust tokenizer's process
   static is shared, but the ONNX session is not.
4. **`nearestNeighborsF32(queryEmbedding, topK)` is the retrieval bug the data
   layer already documented.** `maxResultCount` bounds the ANN sub-query before
   any scope filter, so a naive top-K under-delivers (`publication-data-layer`
   FR15, `FetchBudget`). The note-scoped search path (FR35) therefore reuses
   `FetchBudget`, not this snippet.

---

## Requirements

### Entities and domain model

- **FR1 — A note is an entity with an optional title, two dates, and three
  versions.** It is stored as `ObNote` with a `@Unique() String uuid`, a nullable
  `String? title`, a `@Property(type: PropertyType.dateUtc) DateTime createdAt`,
  a date `DateTime updatedAt`, a `String embeddingModelId`, an `int chunkCount`,
  an `@Index() int versionCounter`, and an `int chunkSetVersion`. The int id never
  leaves the data layer. This mirrors `ObPublication` minus `byteSize` (a note
  body is small and its size is not a UI concern) and with `updatedAt` added.

  ```dart
  @Entity()
  class ObNote {
    @Id() int id = 0;
    @Unique() String uuid;

    /// Optional. Null means "untitled"; the UI derives a placeholder (FR18).
    String? title;

    @Property(type: PropertyType.dateUtc) DateTime createdAt;
    @Property(type: PropertyType.dateUtc) DateTime updatedAt;

    String embeddingModelId;      // empty until first indexed (FR8)
    int chunkCount;               // denormalised; see FR12

    @Index() int versionCounter;  // metadata + edges axis
    int chunkSetVersion;          // chunk-set axis

    final notebooks = ToMany<ObNotebook>();       // @Backlink('notes') on ObNotebook
    final chunks = ToMany<ObNoteChunk>();          // @Backlink('note') on ObNoteChunk
    final document = ToOne<ObNoteDocument>();
  }
  ```

- **FR2 — The body lives in its own row.** `ObNoteDocument` holds the note's
  text, keyed by `@Unique() String uuid` derived as `noteDocumentUuidFor(noteUuid)`
  (FR25), with an `@Index() int noteId` denormalised column, its own
  `@Index() int versionCounter`, the `String markdown` body, and a
  `ToOne<ObNote> note` annotated `@TargetIdProperty('noteOwnerId')`. This is the
  same correction the data layer had to make for publications
  (`publication-data-layer` correction 3): ObjectBox loads whole objects, so a
  body stored on the note row would be read by every note **list** — which
  NFR4 forbids.

- **FR3 — Note↔Notebook is structurally many-to-many.** `ObNotebook` gains
  `final notes = ToMany<ObNote>();`; `ObNote.notebooks` is the matching
  `@Backlink('notes')`. Nothing in the schema encodes a cardinality of one, so
  the day the UI grows a cross-link affordance no migration and no re-embed is
  required. This is the publication-data-layer D1/D2 decision applied to notes.

- **FR4 — A note has exactly one body row and zero or more chunk rows.**
  `ObNoteChunk` is a distinct entity: `@Id() int id`, `@Unique() String uuid`
  derived as `noteChunkUuidFor(noteUuid, chunkIndex)`, `int chunkIndex`,
  `String content`, `int tokenCount`, `@Index() int noteId`, an `@HnswIndex`
  `List<double> embedding` with the **same** `dimensions: 256`,
  `distanceType: cosine`, `neighborsPerNode: 16`, `indexingSearchCount: 100`, and
  a `ToOne<ObNote> note` annotated `@TargetIdProperty('noteRef')`.

  Note chunks are a **separate entity from `ObChunk`**, not rows with a nullable
  `publicationId`. Sharing `ObChunk` would force a schema change to an
  already-shipped, sync-critical entity and a nullable parent column on the
  publication search path; a distinct entity leaves `SearchRepository` and every
  existing reference site untouched. The cost is a second HNSW index in the same
  store; see NFR8. This satisfies OR1 (`docs/sync-conventions.md`): children are
  rows, never a JSON column on the parent.

- **FR5 — Domain values are Flutter-free and ObjectBox-free.** `Note`,
  `NoteSummary`, and `NoteChunk` live in `lib/models/` with no `package:flutter`
  and no `package:objectbox`, matching the publication models. `Note` carries the
  body (it is read only to open the editor, FR17); `NoteSummary` is a projection
  with no body field, so a list caller cannot read it even by mistake.

  ```dart
  class Note {
    final String uuid;
    final String? title;
    final String body;
    final DateTime createdAt;
    final DateTime updatedAt;
    final String embeddingModelId;
    final int chunkCount;
    // copyWith, ==, hashCode, toString as for Publication.
  }

  class NoteSummary {           // returned by every list path
    final String uuid;
    final String? title;
    final DateTime createdAt;
    final DateTime updatedAt;
    final String embeddingModelId;
    final int chunkCount;
  }

  class NoteChunk {
    final String noteUuid;
    final int chunkIndex;
    final String content;
    final int tokenCount;
    final List<double> embedding;
  }
  ```

### Chunker and embedder seams

- **FR6 — A `TextChunker` seam turns a body into ordered text chunks.**

  ```dart
  class TextChunk {
    final int index;        // 0-based, contiguous
    final String content;
    final int tokenCount;
  }

  /// A token's character span in the source body, from the model's tokenizer.
  class TokenSpan {
    final int start;   // inclusive character offset
    final int end;     // exclusive character offset
  }

  /// Tokenizes the way the active model's tokenizer does. A seam so the
  /// chunker is testable without the Rust FFI (NFR5). The Rust bridge exposes
  /// HF `get_offsets()` alongside ids and mask for exactly this.
  abstract interface class Tokenizer {
    List<TokenSpan> tokenize(String text);
  }

  abstract interface class TextChunker {
    /// Deterministic. Returns an empty list for an empty or whitespace-only
    /// body. Indices are contiguous from 0 (the ObChunk/ObNoteChunk contract).
    List<TextChunk> chunk(String body);
  }
  ```

  The default implementation is **heading-aware with a token-window fallback**
  (D24). It proceeds in two levels:

  1. **Section split.** The body is divided into Markdown sections at ATX heading
     boundaries (`^#{1,6}\s`). A heading line starts a new section and stays with
     the content that follows it; sections are **never merged across a heading**.
     A body with no headings is one section.
  2. **Token window within a section.** Any section whose token count exceeds
     `maxTokens = 512` is split by the **sliding token window** — windows of 512
     tokens with `overlap = 64` tokens — using the `Tokenizer` seam's spans,
     mapped back to **character offsets** so `content` is the original substring.
     Sections at or below the cap are one chunk.

  `tokenCount` is always the true token count of the emitted chunk's content.
  Indices are contiguous from 0 across the whole body. Deterministic; pure Dart
  with the tokenizer injected, so it is unit-testable with a fake tokenizer and
  no FFI.

  The cap and overlap are derived from the blueprint's 400-word / 50-overlap
  window at the model's ~1.3 token-to-word ratio (400 × 1.3 ≈ 512, 50 × 1.3 ≈
  64). The blueprint named the parameter `maxTokens` while counting words
  (`words.sublist`), a ~1.3× understatement; the unit is corrected here. The
  values are constants, not configuration — changing them, or the heading rule,
  is a re-index, not a schema change.

- **FR7 — An `Embedder` seam turns text into 256-dimension vectors, applies the
  model's task prefix, and names its model.**

  ```dart
  abstract interface class Embedder {
    /// The model *and configuration* that produced every vector (FR8),
    /// e.g. `nomic-embed-text-v1.5:onnx:int8:256`.
    String get modelId;

    /// Ingestion side. Prefixes `search_document: ` internally.
    /// One vector per input, in order. Each is exactly
    /// `VectorGeometry.dimensions` (256) finite values, L2-normalised.
    Future<List<List<double>>> embedDocuments(List<String> texts);

    /// Retrieval side. Prefixes `search_query: ` internally. Used by the
    /// note-scoped search path (D30).
    Future<List<double>> embedQuery(String text);
  }
  ```

  **The task prefixes are applied inside the implementation, never by the
  caller.** `nomic-embed-text-v1.5` mandates `search_document: ` for ingested
  content and `search_query: ` for queries, and omitting either degrades
  retrieval quality significantly without throwing. Making the caller pass a
  prefix is exactly the contract that gets forgotten; making the method name
  state the purpose makes the prefix structural.

  `embedDocuments` is batched because the note indexer embeds a whole chunk set
  at once and a per-chunk round trip into the runtime is the dominant cost
  (NFR7). Implementations must **not** run inference on the UI isolate.

- **FR8 — The ONNX-backed embedder is the one implementation, and its pipeline
  is fixed.** An `OnnxEmbedder implements Embedder` runs exactly this pipeline,
  in this order, for every vector:

  1. **Prefix** — `search_document: ` for `embedDocuments`, `search_query: ` for
     `embedQuery` (FR7).
  2. **Tokenise** — Hugging Face `tokenizers`, yielding `input_ids` and
     `attention_mask` as `Int64List`s. The **pinned fast path** is the Rust FFI
     bridge (implemented with `flutter_rust_bridge`; the generated bindings live
     under `lib/bridge/` and are never hand-edited), to avoid a per-token Dart
     loop on large notes. A **pure-Dart WordPiece tokenizer parsing
     `tokenizer.json` ships as the default** behind the same seam, so the stack
     runs with no native tokenizer build; swapping in the bridge is a constructor
     change (D35).
  3. **Infer** — one `onnxruntime` session call over tensors `input_ids` and
     `attention_mask`, producing `[1, seq, 768]` token vectors. The session is
     opened **once** and cached; loading is lazy (first save), asynchronous, and
     never repeated per call (NFR7). Platform execution providers (Core ML /
     NNAPI / Metal) are enabled where available with a **mandatory CPU
     fallback**, so output is correct whether or not an EP is active (D23).
  4. **Mean-pool** across the sequence, weighting by `attention_mask` so padding
     does not contribute.
  5. **Matryoshka-truncate** the pooled 768-vector to its first 256 components
     (MRL), matching the HNSW index (FR4) and `VectorGeometry.dimensions`.
  6. **L2-normalise** the truncated vector, which is what makes cosine distance
     rank as intended (`publication-data-layer` D10).
  7. **Release** every ONNX tensor in a `finally`, so a failed inference does not
     leak native memory.

  The method returns exactly `VectorGeometry.dimensions` values or throws. A
  wrong-length or non-finite output is rejected at the seam — the same rule
  `validateEmbedding` enforces again at the store boundary (NFR3).

  `modelId` is the **single source of truth** for both note embedding writes and
  `SyncApplier(activeEmbeddingModelId: …)`; it encodes model, runtime,
  quantisation, and dimension (`nomic-embed-text-v1.5:onnx:int8:256`). Two
  literals would drift and re-open the `embeddingModelId` gate; there must be
  one. `OnnxEmbedder` and the tokenizer bridge are the two new native
  dependencies; the Dart packages are pinned in Plan (nothing ONNX-shaped is in
  `pubspec.yaml` today).

- **FR8a — The model artefact is bundled and quantised.** The app ships
  `assets/models/nomic_embed_text_v1.5_quantized.onnx` and
  `assets/tokenizers/tokenizer.json` as declared Flutter assets, and the
  embedder resolves them via the asset bundle (or copies them to a file path the
  runtime can open). Exactly **one portable dynamic-INT8 `.onnx` artefact** is
  shipped (D22), runnable on x86-64 and ARM; an `avx512_vnni`-only artefact is
  rejected (see [Corrections](#corrections-to-the-blueprint), point 1). The
  model is placed at build time, not downloaded at runtime (D25). It is a
  **build artifact** fetched by `make install_model` from a pinned revision +
  SHA-256 and loaded by path (D38); the app is fully offline once built.

- **FR9 — `NoteIndexer` orchestrates the regeneration.** Given a note body it:
  1. calls `chunker.chunk(body)`;
  2. returns immediately with an empty draft list if there are zero chunks (no
     embedder call at all);
  3. otherwise calls `embedder.embedDocuments(contents)` (the
     `search_document: ` side, FR7) and pairs each vector with its
     `(index, content, tokenCount)` into a `ChunkDraft`;
  4. returns the drafts to the caller, which hands them to the atomic write
     (FR12). The indexer performs no write itself, so a failed embedding leaves
     nothing to roll back.

  `ChunkDraft` (from `lib/models/chunk.dart`) is deliberately reused: it is
  parent-agnostic — `(chunkIndex, content, tokenCount, embedding)` — and already
  carries exactly what a note chunk needs.

  **Inference runs off the UI isolate via `onnxruntime`'s `runAsync`**, which
  reuses one background session for the app's lifetime (NFR7, D36). A fresh
  `Isolate.run` per save would not share the parent's `OrtSession` and would
  reload the model every time; the package's isolate session avoids that while
  keeping the session loaded once.

### Write path

- **FR10 — Creating a note is one transaction.** `create` writes the `ObNote`
  row, its empty-or-initial `ObNoteDocument` row, and the association edge to the
  notebook in a single `runInTransaction(TxMode.write, …)`. The note starts with
  `chunkCount == 0`, `chunkSetVersion == 0`, `versionCounter == 1` (creation is a
  modification; a record with no version is indistinguishable from one a peer
  has seen), `createdAt == updatedAt`, and `embeddingModelId == ''`. Creating a
  note does **not** run the embedder: an empty body has no chunks (FR9).

- **FR11 — Save semantics are body-aware.**
  - If the **title** changed and the body did not: write metadata only. Bump
    `versionCounter`, set `updatedAt = now`, and **do not** touch the document,
    `chunkSetVersion`, or any chunk row. No embedding runs.
  - If the **body** changed: write the body and its chunk set in one transaction
    (FR12), set `updatedAt = now`, bump `versionCounter` and `chunkSetVersion`,
    set `embeddingModelId` to the embedder's `modelId`, and set
    `chunkCount` to the new chunk count.
  - If neither changed: no write at all. Re-saving an unedited note must not
    advance a version, because an advanced version is a push to every peer for
    no change.
  - Body equality is exact string equality against the last saved body.
    Whitespace is meaningful; a body that is whitespace-only is not empty but
    yields zero chunks (FR9).

- **FR12 — Replacing a note's chunk set is atomic and validated.**
  `replaceNoteChunks(noteUuid, drafts)`:
  - validates **every** draft with `validateEmbedding` **before** opening the
    transaction, so a bad vector can never leave a partial write
    (`publication-data-layer` FR8);
  - inside one `runInTransaction(TxMode.write, …)` removes every
    `ObNoteChunk` whose `noteId` equals the note, inserts the new set
    (`putMany`), writes the `noteId` denormalised column and the `ToOne` target
    for each so they cannot drift, updates `chunkCount`, and advances
    `chunkSetVersion` and `versionCounter`.

  The body write and the chunk-set replacement for a body save happen in the
  **same** transaction, so a note can never be observable with a new body and
  the old chunk set.

- **FR13 — Association writes are idempotent.** `attach(noteUuid, notebookUuid)`
  and `detach` are single transactions. Attaching an already-attached pair is a
  no-op; detaching compares by **id** (`removeWhere`), never `remove`, because
  ObjectBox `ToMany` has no value equality (`docs/sync-conventions.md`). Both
  bump the note's `versionCounter` (the edge travels in the metadata record) and
  never `chunkSetVersion`.

- **FR14 — Deleting a note cascades its children, in one transaction.**
  `deleteNote(noteUuid)` removes the note's chunks, its document row, its chat
  messages (FR34), and the note row. Deleting a note never deletes a notebook.
  The cascade lives in one implementation shared by the local path and the sync
  receive path, as `_cascadePublication` already does.

- **FR15 — The notebook delete cascade includes exclusive notes.** This
  **amends** `LibraryRepository.deleteNotebook` (`publication-data-layer` FR12,
  delete-notebooks FR3): a note attached **only** to the notebook being deleted
  is cascaded away (chunks, document, note row) and returned to the caller as a
  `CascadedNote { uuid, versionCounter }` so a tombstone can be written; a note
  attached to any other notebook is **shared** and survives, holding one fewer
  notebook. The returned cascade is a **`NotebookCascade
  { List<CascadedPublication> publications; List<CascadedNote> notes }`**, so the
  sync delete path keeps one call site and one place to write tombstones for both
  child kinds. Without this, deleting a notebook would orphan note rows and their
  vectors forever.

- **FR16 — `updatedAt` is advanced on every write, never on read.** It is set by
  FR10/FR11/FR12 at the store's millisecond precision (`PropertyType.dateUtc`),
  truncated the way `ObjectBoxLibraryRepository._nowUtc` does, so the returned
  object equals the object read back.

### Read path

- **FR17 — Two read shapes.** `noteByUuid(uuid)` returns a full `Note` including
  the body (read to open the editor). `listNotes(notebookUuid)` returns
  `List<NoteSummary>` with **no body** and never touches `ObNoteDocument`. The
  list query reads the notebook's `notes` relation; the body is read by note id
  only when the editor opens.

- **FR18 — Deterministic ordering and untitled rendering.** Notes order by
  `createdAt` ascending, matching the existing notebook and publication ordering
  conventions. A `null`/empty title is rendered by the UI as a single shared
  placeholder string (e.g. `Untitled note`); the placeholder is a presentation
  concern and is never stored.

### Sync

- **FR19 — A note is a record, not a reference.** `ObNote` carries
  `@Unique() uuid`, `versionCounter`, and `chunkSetVersion`; its body row carries
  its own `versionCounter`; deletes are tombstoned. This is the same shape as
  `ObPublication` and is what makes notes sync without a special channel. The
  three axes behave exactly as `docs/sync-conventions.md` documents:

  | Event | metadata + edges | chunk set | document body | Transfers |
  |---|---|---|---|---|
  | Retitle / attach / detach | bumps | — | — | metadata only |
  | Body re-index | bumps | bumps | bumps | metadata, body, and the set |

- **FR20 — The payload gains a `notes` list, additively.** `SyncPayload` gains
  `List<NoteDto> notes` with **three** new DTOs:
  - `NoteDto { uuid, String? title, createdAt, updatedAt, embeddingModelId,
    declaredChunkCount, chunksIncluded, version, chunkSetVersion, notebookUuids,
    body?, chunks[] }`;
  - `NoteDocumentDto { uuid, noteUuid, markdown, version }`;
  - `NoteChunkDto { uuid, chunkIndex, content, tokenCount, noteUuid,
    embeddingBase64, version }`.

  Every reference is a **uuid**, never an int storage id. Decoding is total:
  a malformed record refuses the whole payload, never half-populates it. Absence
  of `notes` in an old payload decodes to an empty list, exactly as `aiConfigs`
  does, so an old peer is simply a peer that carries no notes.

- **FR21 — The reference-site list grows from seven to fourteen.** Every new
  relation is a site where a uuid must be resolved to a local int **twice** (the
  denormalised column and the relation row), and both must be written and agree:

  | # | Entity | Reference | Kind |
  |---|---|---|---|
  | 8 | `ObNote` | `notebooks` | `ToMany` (`@Backlink('notes')`) |
  | 9 | `ObNoteChunk` | `noteId` | denormalised int column, indexed |
  | 10 | `ObNoteChunk` | `note` | `ToOne` (`@TargetIdProperty('noteRef')`) |
  | 11 | `ObNoteDocument` | `noteId` | denormalised int column, indexed |
  | 12 | `ObNoteDocument` | `note` | `ToOne` (`@TargetIdProperty('noteOwnerId')`) |
  | 13 | `ObNote` | `document` | `ToOne` |
  | 14 | `ObNote` | `chunks` | `ToMany` (`@Backlink('note')`) |

  Existing sites 1–7 are unchanged. As with the original list, this is
  **enumerated, never discovered reflectively**: a missed site is silently
  wrong (a chunk that still counts and still matches search).

- **FR22 — Notes ingest with the publication mechanics.** `SyncApplier` gains
  note planning and application with the same order and the same guards:
  - **Validate** every note chunk set against its `declaredChunkCount` before
    any write; refuse the whole payload on mismatch, store untouched.
  - **Plan** before resolving, so a tombstoned or outranked note never conjures
    a placeholder row via `UuidScope`.
  - **Deletes first**, then notebook roots, then publications and notes (both
    reference notebooks), one transaction per note DAG.
  - The `embeddingModelId` gate applies: on a model mismatch, apply the note's
    metadata and body but transfer **no** vectors, leave `chunkSetVersion`
    unadvanced, and never relabel a note that already holds local chunks.
  - `chunksIncluded` disambiguates "no set selected" from "the set shrank to
    nothing" for notes exactly as for publications; a metadata-only note push
    must never wipe a peer's note chunks.
  - A note edge naming a tombstoned notebook is filtered out **before** it is
    resolved, so a dead notebook cannot be resurrected as an untitled row.

- **FR23 — Deletes resolve notes too.** `_applyDelete` resolves the delete
  uuid against notebook, then publication, then **note**, then AI configuration,
  and runs the note cascade (chunks, document, note row) in one transaction. A
  delete for a note this device never had is still tombstoned. The tombstone is
  written in the **same** transaction as the cascade.

- **FR24 — Delta selection and watermarks cover notes.** `PushSender.selectDelta`
  selects a note when **any** of its three axes moved past what the peer
  acknowledged (metadata, chunk set, body), assembling `NoteDto` with
  `chunksIncluded`/`declaredChunkCount` from the selection — never from local
  state. `acknowledge` writes the note's three counters into `ObPeerWatermark`;
  the per-record, per-axis rule is unchanged, and reusing the record uuid as the
  watermark key needs no schema change.

- **FR25 — The identity scheme grows two derived forms.** `lib/data/identity.dart`
  gains `noteDocumentUuidFor(noteUuid) => 'nd-$noteUuid'` and
  `noteChunkUuidFor(noteUuid, index) => 'nc-$noteUuid-$index'`, and
  `isValidIdentifier` accepts them so a payload legitimately carrying note
  chunk/document ids is not rejected. Derivation is what makes re-applying a
  whole note chunk set idempotent. The existing `c-`/`d-` forms are unchanged;
  the `n` prefix cannot collide with them or with a plain v7 uuid.

### UI — notes

- **FR26 — The Notes section is enabled and lists notes.** `notebookSections`
  marks `notes` enabled. The detail navigation renders, under the Notes section,
  an **Add note** action and the notebook's notes (from `listNotes`) ordered by
  `createdAt`. Selecting a note navigates to it; selecting Add note opens the
  editor in new-note mode. The enabled section renders with the same selection
  treatment as Overview.

- **FR27 — The editor is a plain, editable markdown text box.** The note route
  shows, for the selected note: a single-line **title** field (optional) and a
  multi-line **body** text box, both seeded from the stored note. There is no
  rendered preview and no formatting toolbar (Non-Goals). New-note mode shows
  the same surface, empty.

- **FR28 — Save and Cancel appear only when dirty.** Dirty is
  `title != savedTitle || body != savedBody`. While clean, neither control is
  shown. **Cancel** resets both fields to the last saved values and clears all
  editing/dirty state; it writes nothing. **Save** is the only path that writes.

- **FR29 — Save applies FR11.** Saving a title-only change updates metadata and
  runs no embedding. Saving a body change re-chunks, re-embeds, replaces the
  chunk set, and updates `updatedAt`. A failed embedding surfaces an error and
  leaves the stored note unchanged (the atomic write has not run).

- **FR30 — Adding a note.** Add note opens the editor in new-note mode. Save
  creates the note in the current notebook (FR10), then indexes and writes the
  body if non-empty (FR11/FR12). Cancel discards the unsaved note and returns to
  the notes list.

### UI — chat panel

- **FR31 — A collapsible chat panel docks on the right of the note editor.** On
  the note route the centre editor is joined by a right-hand panel, mirroring the
  existing side panel's collapse behaviour: expanded it shows content, collapsed
  it reduces to a narrow rail with a toggle. Its width policy is a pure-Dart,
  testable geometry (fraction of window with min/max clamp) in the same spirit as
  `PanelGeometry`, and its collapsed state is UI state, transient per session
  (D26), not a note property.

- **FR32 — The panel is a message list over a resizable input.** The panel
  contains:
  - a scrollable **message list** rendering the note's stored messages (FR34) —
    oldest at the top, newest at the bottom, scrolled to the newest by default;
  - a **multi-line text input** at the bottom, **three rows tall by default**,
    internally scrollable, and **vertically resizable** by the user (a drag
    handle that grows/shrinks the input, not the window).
  The input is a layout element only; composing and sending are FR33.

- **FR33 — Chat behaviour is out of scope, but the message shape is not.**
  Composing and sending a message, answering one, retrieval-augmented reply
  generation, AI orchestration, and the requirements for any of it remain
  **beyond the scope of this feature**. This feature specifies the panel's
  placement, collapse, list ordering, input size, resize affordance, and the
  minimal message record it renders (FR34).

- **FR34 — A minimal, local-only chat message record.** A `ChatMessage` domain
  value `{ String uuid; String noteUuid; ChatMessageRole role; String text;
  DateTime createdAt }` (role ∈ `{ user, assistant }`, a plain enum with no sync
  vocabulary, NFR2) is stored in `ObChatMessage`: `@Id() int id`,
  `@Unique() uuid`, `@Index() int noteId`, `String role`, `String text`,
  `@Property(dateUtc) createdAt`, and a `ToOne<ObNote> note`
  (`@TargetIdProperty('messageOwnerId')`). A `ChatMessageRepository` exposes
  `listForNote(noteUuid)` (ordered by `createdAt`) and an `append(...)`. The
  panel renders `listForNote`; the input does **not** call `append` in this
  feature. Messages are **local-only** — they are not added to `SyncPayload` and
  do not extend the reference-site list (FR21). Deleting a note cascades its
  messages (FR14).

- **FR35 — A note-scoped retrieval path exists.** A `NoteSearchRepository`
  exposes `search({ required String noteUuid, required List<double> queryVector,
  required int limit, int? fetchCountOverride })` returning
  `List<NoteSearchResult>` (`{ NoteChunk chunk; double distance }`), ordered by
  ascending distance and truncated to `limit`. It is the **note** analogue of the
  publication search and must not be the naive query the blueprint showed:
  ObjectBox's `maxResultCount` bounds the ANN sub-query **before** the `noteId`
  filter, so the call **over-fetches using `FetchBudget`** with
  `scopeFraction = noteChunks / totalNoteChunks`, exactly as
  `SearchRepository` does (D30). The query vector is validated with
  `validateEmbedding`; the query text is embedded with `embedQuery`
  (`search_query: ` prefix). The existing publication `SearchRepository` is
  unchanged and the two indexes are never combined. Nothing in the UI consumes
  this path yet (FR33).

- **FR36 — An unindexed note is surfaced with a banner.** When a note's
  `chunkCount == 0` while it has a non-empty body, or its `embeddingModelId`
  differs from the active model, the editor shows a **banner** explaining the
  note is not currently searchable. It is informational and blocks no editing;
  no re-index is offered here (D27). This is the visible half of the
  `embeddingModelId` mismatch the sync gate already makes detectable.

### Non-Functional Requirements

- **NFR1 — Models stay pure.** `Note`, `NoteSummary`, `NoteChunk`,
  `NoteSearchResult`, and `ChatMessage` in `lib/models/` import neither
  `package:flutter` nor `package:objectbox`, enforced by the existing
  import-directive purity test.

- **NFR2 — No sync vocabulary in the domain layer.** No `Sync*`, version, or
  tombstone concept appears in `lib/models/` (peer-sync NFR2). The note's three
  versions are storage concerns.

- **NFR3 — Vectors are validated at both boundaries.** `validateEmbedding` runs
  on the note write path before `put`, and the `Embedder` contract requires
  256 finite values. ObjectBox silently ignores a short vector
  (`publication-data-layer` FR8), so this cannot be left to the store.

- **NFR4 — Bounded memory on read.** No note list path loads a body. This is
  structural: the body is in its own row (FR2) and lists return `NoteSummary`,
  which has no body field.

- **NFR5 — Testability without a device.** Every repository, indexer, and sync
  contract is exercised against in-memory stores in a plain `flutter test`; the
  `Embedder` is exercised through a deterministic fake, and the ONNX
  implementation through a contract test that can run without the model where
  the runtime is absent.

- **NFR6 — Generated code is committed and reproducible.** `objectbox.g.dart`
  and `objectbox-model.json` are regenerated with `make codegen` and committed;
  CI fails on drift (`docs/data-conventions.md`).

- **NFR7 — Inference never blocks the UI.** Model load and inference run off the
  UI isolate; the model is loaded once per session and cached, and a batch embed
  is one runtime call. The shipped mechanism is `onnxruntime`'s
  `OrtSession.runAsync`, which the package runs on a background isolate that
  reuses one session — **not** a per-call `Isolate.run`, which cannot share a
  session and would reload the model each time (D36). Saving a large note may be
  asynchronous, but must not jank the editor.

- **NFR8 — The second index is bounded.** `ObNoteChunk.embedding` uses the same
  256-dim HNSW configuration as `ObChunk`; per-chunk cost is `~1.1–1.2 KB`
  (`publication-data-layer` Storage Budget). A new index does not change that
  ceiling per note; it is recorded so the growth is checked, not assumed.

- **NFR9 — OR1 holds.** Note chunks and the note body are separate rows, never a
  delimited or JSON column on `ObNote`. `test/or1_enforcement_test.dart` must
  continue to pass.

- **NFR10 — No network.** The embedder runs the model on-device. No note path
  makes a network call.

## Acceptance Criteria

- [ ] **AC1:** The store contains `ObNote`, `ObNoteDocument`, and `ObNoteChunk`; `ObNote.notebooks` is a `ToMany` with a matching `@Backlink('notes')` on `ObNotebook`; codegen emits no error.
- [ ] **AC2:** `ObNoteChunk.note` carries `@TargetIdProperty('noteRef')` and `ObNoteDocument.note` carries `@TargetIdProperty('noteOwnerId')`; codegen succeeds with the denormalised `noteId` columns present.
- [ ] **AC3:** One note attached to two notebooks appears in both notebooks' note lists, and both notebooks appear in the note's notebook list, with no schema change and no re-embed.
- [ ] **AC4:** A note created with an empty body has `chunkCount == 0`, `chunkSetVersion == 0`, and `embeddingModelId == ''`, and the embedder is never invoked.
- [ ] **AC5:** A note with a non-empty body round-trips its `title`, body, `createdAt`, `updatedAt`, `embeddingModelId`, and `chunkCount` exactly.
- [ ] **AC6:** `listNotes` returns `NoteSummary` values and a test asserts the body row is not read (no `ObNoteDocument` access on the list path).
- [ ] **AC7:** A title-only save advances `versionCounter` and `updatedAt`, leaves `chunkSetVersion` and the document version unchanged, and calls the embedder zero times.
- [ ] **AC8:** A body save replaces the chunk set wholesale; `chunkCount` equals the number of inserted chunks; `chunkSetVersion` and the document version both advance; `embeddingModelId` equals the embedder's `modelId`.
- [ ] **AC9:** Saving an unedited note performs no write and advances no version.
- [ ] **AC10:** A body save whose embedding throws leaves the stored body, chunk set, and versions byte-for-byte unchanged.
- [ ] **AC11:** `replaceNoteChunks` with a wrong-length or non-finite vector throws before the transaction and writes nothing.
- [ ] **AC12:** For every note chunk, `chunk.noteId == chunk.note.targetId`; a test writes a mixed set and asserts the invariant after read-back.
- [ ] **AC13:** `attach`/`detach` are idempotent: attaching the same pair three times leaves exactly one association; detaching a freshly queried note actually removes it (the `removeWhere`-on-id guard).
- [ ] **AC14:** `deleteNote` removes the note, its document, its chunks, and its chat messages, and leaves every notebook intact.
- [ ] **AC15:** Deleting a notebook cascades notes exclusive to it and leaves notes shared with another notebook intact and reachable from that other notebook; the returned cascade carries each dead note's uuid and version.
- [ ] **AC16:** A `NoteDto` round-trips through `encodePayload` → `decodePayload` with the body and chunk set intact; a malformed note record refuses the whole payload.
- [ ] **AC17:** A metadata-only note push does not erase the receiver's note chunks (`chunksIncluded: false`).
- [ ] **AC18:** A note chunk set arriving under a different `embeddingModelId` transfers metadata and body but leaves the receiver's note chunk count exactly 0, and does not advance `chunkSetVersion`.
- [ ] **AC19:** A payload carrying both a note upsert and a note `DeleteDto` applies the delete; a later in-flight upsert cannot resurrect the note.
- [ ] **AC20:** A note push selects metadata only after a retitle, and metadata+body+set after a body re-index, by their independent watermarks; a re-index after a first push is selected again.
- [ ] **AC21:** A note edge naming a tombstoned notebook is dropped before resolution; no untitled notebook row is created.
- [ ] **AC22:** `isValidIdentifier` accepts `nd-<uuid>` and `nc-<uuid>-<n>` and still accepts the existing `c-`/`d-`/plain-uuid forms.
- [ ] **AC23:** The Notes section is enabled and renders a list plus an Add note action; selecting a note opens the editor with its title and body; an empty title renders the shared placeholder.
- [ ] **AC24:** Save and Cancel are absent while clean and present while dirty; Cancel restores the last saved title and body and clears dirty; Save with a changed body regenerates chunks.
- [ ] **AC25:** The chat panel docks on the right of the note route, collapses to a rail and expands; its message list orders oldest-first with the newest at the bottom; its input is three rows tall by default, scrolls internally, and can be resized vertically by the user.
- [ ] **AC26:** Domain models in `lib/models/` import neither `package:flutter` nor `package:objectbox`, and contain no sync vocabulary; the existing purity tests pass.
- [ ] **AC27:** `objectbox.g.dart` and `objectbox-model.json` are committed and a clean checkout builds without re-running codegen.
- [ ] **AC28:** Every repository/indexer/sync test runs against an in-memory store in a plain `flutter test` with no device and no ONNX model required.
- [ ] **AC29:** The existing publication, search, sync, and shell test suites pass unmodified except where this spec's amendments (FR15, FR20–FR24) necessarily change a call signature.
- [ ] **AC30:** `embedDocuments` sends `search_document: <text>` to the model and `embedQuery` sends `search_query: <text>`; a test through the `Tokenizer`/session seam asserts the exact prefixed string for each.
- [ ] **AC31:** For a fixed input, the embedder's output has length 256, is finite, and is L2-normalised to unit length within epsilon; mean pooling ignores masked tokens (padding does not change the result).
- [ ] **AC32:** The default chunker is deterministic; returns an empty list for an empty or whitespace-only body; returns contiguous 0-based indices; starts a new chunk at each ATX heading and never merges content across a heading; splits a section exceeding 512 tokens by a 512-token window with 64-token overlap; keeps a smaller section as one chunk; yields `content` equal to the original substring (character offsets preserved); and reports `tokenCount` equal to the emitted chunk's token count from the injected `Tokenizer`, not a word count.
- [ ] **AC33:** Across N embeds the model is loaded exactly once and every inference runs off the UI isolate (the worker isolate owns the session).
- [ ] **AC34:** `NoteSearchRepository.search` returns only chunks of the requested note, distance-ordered. On the adversarial case — a note whose chunks are a narrow slice of a large note-chunk corpus — it returns exactly `limit` results when `limit` in-scope chunks exist; a test proves the naive `fetchCount == limit` under-delivers (the `FetchBudget` guard).
- [ ] **AC35:** `ObChatMessage` persists `role`, `text`, `createdAt`, a `@Unique()` uuid, and its note link; `listForNote` orders by `createdAt`; deleting the note cascades its messages; and no message appears in an encoded `SyncPayload`.
- [ ] **AC36:** The editor shows the unindexed-note banner when a non-empty-body note has `chunkCount == 0` or its `embeddingModelId` differs from the active model, and the banner blocks no editing.

---

## Resolved Decisions

| # | Question | Resolution | Why |
|---|---|---|---|
| **D1** | Is a note a new entity or a flagged publication? | **New entity** (`ObNote`/`ObNoteChunk`/`ObNoteDocument`). | A note has an optional title, `updatedAt`, and no `byteSize`; overloading `ObPublication` would put nullable fields on a shipped, sync-critical row and blur two different lifecycles. |
| **D2** | Share `ObChunk` (nullable parent) or a separate note chunk entity? | **Separate `ObNoteChunk`.** | Sharing forces a schema change to the publication search path and a nullable parent column; a distinct entity leaves every existing reference site and `SearchRepository` untouched. |
| **D3** | Note↔notebook cardinality? | **Many-to-many `ToMany` + `@Backlink`.** | Asked for explicitly; matches D1/D2 of the data layer and avoids a migration + re-embed when cross-linking ships. |
| **D4** | When does embedding run? | **On save, only when the body changed.** | The brief's requirement; it also keeps per-keystroke embedding out of the editor. |
| **D5** | What counts as "the body changed"? | **Exact string inequality against the last saved body.** | Whitespace is meaningful in markdown; a whitespace-only body is valid and yields zero chunks. |
| **D6** | Does a title change re-embed? | **No.** | The brief states it; the title is metadata and is not an input to chunking. |
| **D7** | Is an empty note allowed? | **Yes.** A new note starts empty with zero chunks; the embedder is not called. | A note is authored, not imported; rejecting an empty note would make "create then type" impossible. This deliberately differs from `EmptySourceException` for publications. |
| **D8** | Chunker/embedder source? | **Defined and pinned here** — `nomic-embed-text-v1.5` → ONNX → `onnxruntime`, Rust `tokenizers` FFI, 256-dim MRL. | Nothing else does, and the data layer's Open Questions are blocked on exactly this. Artefact portability (D22) and budget (D32) are now fixed. |
| **D9** | Sync notes now or later? | **Now**, as a sixth payload record type. | Asked for; the publication change-set gives the template, and deferring means a schema addition plus a full re-embed later. |
| **D10** | One HNSW index or two? | **Two** — `ObChunk` and `ObNoteChunk`. | Keeps retrieval scopes separable (a note chat must not retrieve arbitrary publications) and keeps the publication query untouched. Cost recorded in NFR8. |
| **D11** | Where does the chat panel live? | **A right-docked, route-scoped panel on the note editor**, mirroring the existing panel. | It is note-specific, so it must not become a global shell panel; route-scoping keeps the shell's navigation unchanged. |
| **D12** | Is the note editor read-only until an Edit button? | **No** — one editable surface; Save/Cancel appear only when dirty. | The brief: "why do we care if the user edits the thing while they read?" |
| **D13** | Note deletion in this feature? | **Cascade semantics only; no UI.** | The notebook delete must stay correct (FR15); a trash-can affordance is not requested. |
| **D14** | Reuse `ChunkDraft` for the note write path? | **Yes.** | It is parent-agnostic and already the data-layer write input type, so there is one chunk-draft shape. |
| **D15** | Embedding model and dimensions? | **`nomic-embed-text-v1.5`; 768 native, MRL-truncated to 256.** | Matches the existing HNSW `dimensions: 256` with no index change; MRL retains ~98% of quality at ~3× smaller vectors/indices. |
| **D16** | Inference runtime? | **`onnxruntime` (Dart).** | Per the blueprint; on-device on all five targets, no web. |
| **D17** | Tokenizer? | **Hugging Face `tokenizers` via Rust FFI (`flutter_rust_bridge`).** | Removes a per-token Dart loop on large notes; the tokenizer must match the model. |
| **D18** | Nomic task prefixes? | **Applied inside the `Embedder`, selected by method (`embedDocuments`/`embedQuery`).** | Mandatory for this model and trivially forgotten by callers; making the prefix structural beats documenting it. |
| **D19** | Chunk window and token counting? | **Sliding word window, 400 words / 50 overlap; `tokenCount` from the tokenizer.** | The blueprint's parameters with the unit corrected (its "tokens" were words); a re-index, not a schema change, if changed. |
| **D20** | Threading model? | **Off the UI isolate via `onnxruntime`'s `runAsync` (one reused session).** | A per-call `Isolate.run` cannot share the session and would reload the model every save. |
| **D21** | Quantisation artefact? | **INT8 / FP16, portable across x86-64 and ARM.** | The blueprint's `avx512_vnni` artefact is x86-only and would not run on Apple Silicon, iOS, or Android ARM. |
| **D22** | One artefact or per architecture? | **One portable dynamic-INT8 `.onnx` file.** | Simplest asset pipeline; must run correctly on every target. |
| **D23** | Execution providers? | **Platform EPs (Core ML / NNAPI / Metal) enabled where available, with mandatory CPU fallback.** | Perf where the hardware offers it, correctness everywhere. |
| **D24** | Chunk boundary algorithm now? | **Heading-aware sections, with a `maxTokens 512` / `overlap 64` token window inside oversized sections.** | Aligns chunks to note structure; the token window bounds large sections. A re-index, not a schema change, if changed. |
| **D25** | Model redistribution? | **Bundle the quantised weights in-repo; Plan verifies the licence permits it.** | Keeps inference offline with no first-run network dependency. |
| **D26** | Chat panel state persistence? | **Transient per session.** | Note-specific surface; no new preference key. |
| **D27** | Model-change handling for notes? | **Surface the mismatch now; auto re-index is the committed future direction (a later spec).** | No re-index in this feature, but the intended end state is automatic re-embedding of stale notes. |
| **D28** | Note titles? | **Duplicates allowed, addressed by uuid; no title uniqueness or search.** | Matches the optional-title model and uuid addressing. |
| **D29** | Cross-notebook linking UI? | **Deferred.** | The schema already supports it (FR3); the affordance is a later feature. |
| **D30** | Note retrieval now or later? | **In scope now** — a note-scoped query over `ObNoteChunk` reusing `FetchBudget`. | Decided to build the retrieval path alongside the index; nothing consumes it yet (FR33). |
| **D31** | Chat message model now or later? | **A minimal local-only `ChatMessage` entity now** (FR34). | Decided to fix the data shape now; sending and AI orchestration remain beyond scope. |
| **D32** | Bundled model size budget? | **~150 MB, raised if the artefact exceeds it.** | The budget is a guide, not a hard gate; a larger portable artefact is accepted. |
| **D33** | How is an unindexed note shown? | **A banner in the editor** (FR36). | Prominent and explanatory, per the decision, while blocking no editing. |
| **D34** | Execution providers? | **Core ML (Apple), NNAPI (Android), DirectML (Windows), CPU (Linux), with CPU fallback everywhere.** | One preferred EP per platform plus a mandatory CPU fallback; Metal/XNNPACK optional if offered. |
| **D35** | Tokenizer: Rust only, or a Dart default? | **A pure-Dart WordPiece tokenizer is the shipped default**, behind the same seam; the Rust bridge (D17) is the pinned fast path. | Removes the native tokenizer build from the critical path while preserving the seam, so swapping in Rust is a constructor change. Recorded as a deliberate deviation from D17's "Rust only". |
| **D36** | Off-UI-isolate mechanism? | **`onnxruntime`'s `runAsync`** (one reused session), not a hand-rolled worker isolate. | The package already runs inference on a background isolate that shares the session; a custom worker would duplicate it. |
| **D37** | Model asset present? | **Yes** — the dynamic-INT8 `model_quantized.onnx` from `nomic-ai/nomic-embed-text-v1.5` and its `tokenizer.json` are present under `assets/`, and the app boots on the ONNX stack. Bootstrap still falls back (with a log) if an asset is ever absent. | The model is loaded once and the pipeline verified against the HF reference. |
| **D38** | Track the model binary, or treat it as a build artifact? | **Build artifact, untracked.** `make install_model` fetches the raw **131 MB** `.onnx` from a **pinned HF revision + SHA-256** into `assets/models/` (gitignored); `tokenizer.json` (695 KB) is committed. No gzip step. | The binary is a build input, too large to track and reproducible from the pinned revision. Untracked, GitHub's 100 MB limit does not apply, so the gzip/decompress round-trip is unnecessary. Mirrors the mandatory `make install_objectbox` setup pattern. |

---

## Amendments to prior specs

- **publication-data-layer FR12 / delete-notebooks FR3.** The notebook delete
  cascade now also cascades notes that exist **only** inside the deleted
  notebook, and never deletes notes shared with another notebook (FR15). The
  cascade result grows a notes list alongside publications.
- **peer-sync payload and reference sites.** `SyncPayload` gains `notes`; the
  enumerated reference-site list grows from seven to fourteen (FR21); delete
  resolution gains a note branch (FR23); delta selection and acknowledgement
  cover notes (FR24). The three-axis versioning rule is unchanged and now
  applies to notes as well.
- **publication-data-layer Open Questions (model identity/dimensions).** This
  spec resolves them: the model is `nomic-embed-text-v1.5`, the vectors are 256
  dimensions via MRL, the runtime is `onnxruntime`, and the embedder's `modelId`
  is the single source of truth. Only the quantised artefact's portability and
  size remain Open.

---

## Risks & Mitigations

- **The ONNX runtime may not build on all five targets, or the packed model may
  be too large to ship.** → Plan verifies the package and measures the quantised
  asset before committing. The seam (FR7) means a runtime failure does not touch
  the data model; only `OnnxEmbedder` is swappable.
- **A quantised artefact can be architecture-specific.** The blueprint's
  `avx512_vnni` export will not run on ARM. → D22/FR8a fix one portable
  dynamic-INT8 file; Plan must prove it correct on every target. If portability
  proves impossible, D22 is revisited deliberately rather than a broken artefact
  being shipped.
- **The Rust FFI tokenizer adds a cross-compilation build matrix** (`cargo-ndk`
  for Android, `xcframework` for iOS/macOS, `.dll`/`.so` for Windows/Linux) and a
  Rust toolchain to the build. → The pure-Dart WordPiece default (D35) removes the
  native build from the critical path; the `Tokenizer` seam (FR6) keeps both
  swappable and testable.
- **A per-call isolate would reload the model and stall saves.** → FR9/NFR7 use
  `onnxruntime`'s reused `runAsync` session.
- **A second HNSW index increases store size and opens a new silent-failure
  surface** (a short note vector is stored and unfindable). → NFR3 validates at
  both boundaries; NFR8 states the per-chunk cost so growth is checked.
- **Embedding on save can be slow enough to feel broken.** → NFR7 bans UI-isolate
  inference and cache-loads the model; FR29 keeps a failed embed from writing.
- **The payload grows and a note body can be large.** → The three-axis split
  (FR19) means a retitle never ships the body or the set; a body edit ships once.
- **Enabling the Notes section changes navigation behaviour the shell tests pin.**
  → AC29 and the shell suite are updated deliberately where the amendment
  requires it, not incidentally.

---

## Open Questions

Every question this section previously held is now resolved (D8, D15–D37) or
explicitly deferred. What remains is genuinely undecidable without Plan
measurement or a later spec:

- **Redistribution of the model.** The dynamic-INT8 model is a fetched build
  artifact (D38) and the app boots on the ONNX stack (D37); the licence (D25)
  should still be confirmed. The model needs a third input, `token_type_ids`,
  which the embedder supplies. A fresh checkout must run `make install_model`
  (or `make setup`) before `flutter run`/build, because the asset is declared in
  `pubspec.yaml` and Flutter fails a build when a declared asset is missing.
- **Execution-provider failure behaviour.** D34 fixes the per-platform EP and the
  CPU fallback; how a present-but-failing EP degrades (retry, disable, log) is a
  Plan/implementation detail.
- **Heading-detection edge cases.** D24 splits on ATX headings; setext headings,
  front matter, and fenced code containing `#` are implementation details of the
  section splitter, fixed in Plan.
- **The automatic re-index design.** D27 commits to auto re-embedding stale notes
  but this feature builds none of it; detection trigger, batching, and UI feedback
  belong to the spec that implements it.
- **Whether chat messages ever sync.** FR34 keeps them local-only; adding them to
  `SyncPayload` (and the reference-site list) is a later decision, and the minimal
  shape is sync-ready in principle.
- **Chat consumption of note search.** FR35 builds the note-scoped retrieval path
  but nothing calls it; how the future chat turns results into a reply — including
  any scoping beyond a single note — is the future chat spec's decision.
- **Cross-notebook linking UI.** Deferred (D29); the schema already supports it
  (FR3), and the affordance's interaction with the notebook delete cascade is a
  later feature.

---

## Amendment — durable embedding state and boot recovery (D39–D41)

Found in review. Two gaps in the original write path:

1. **A crash could leave a note half-indexed.** `replaceBodyAndChunks` was one
   transaction, so a kill *during* it was safe — but a kill between "embed
   finished" and "transaction opened", or right after an editor save, could lose
   the just-typed body (it lived only in memory), and a new note could persist
   empty. Nothing recorded that a note *needed* embedding.
2. **Model extraction was not atomic.** `ModelAssets` wrote the model directly
   to its final path behind an `exists()` check, so an interrupted first-run
   copy left a truncated file that the check then accepted forever — permanently
   falling back to the deterministic embedder with no self-heal.

### New / changed requirements

- **FR11a — A note carries its embedding state.** `ObNote` gains a
  **local-only** `embeddingState` string (`complete` | `inProcess`), surfaced as
  `NoteEmbeddingState`. It is **never** in `SyncPayload` — it is this device's
  processing state, like a job status, not record data.
- **FR11b — Save is durable then background.** Save is two steps:
  `beginEmbedding` writes the body and title, removes the stale chunk set, and
  marks `inProcess` **in one transaction** — so the edit survives a crash and the
  note is never half-searchable; then embedding runs **in the background**
  (`completeEmbedding` writes the new set, records the model, marks `complete`).
  Save does not await the embedding. (This supersedes the "await embedding on
  save" reading of FR11/FR29.)
- **FR37 — Boot recovery.** After the first frame, a background pass re-embeds
  every note left `inProcess` at startup, one transaction per note, so progress
  is durable. The embedder never enters concurrently: all work is serialized on
  one queue (`NoteEmbeddingService`). A failure leaves the note `inProcess` and
  is retried at the next boot or save.
- **FR38 — Model extraction is atomic.** `ModelAssets` writes to a temp path and
  `rename`s it into place, so an interrupted extraction can never leave a
  truncated file at the final path.
- **FR22 (amended) — a gated sync note is marked `inProcess`.** When a peer's
  vectors are withheld by the model gate, the receiving note is marked
  `inProcess` so boot recovery builds them locally; a note that receives a full
  chunk set is marked `complete`.

### Additional acceptance criteria

- [ ] **AC37:** A note saved with a changed body has the new body durable
  *before* embedding completes, and its `embeddingState` is `inProcess` until the
  background embed flips it to `complete`.
- [ ] **AC38:** At boot, every note whose state is `inProcess` is re-embedded and
  flipped to `complete`, with `chunkCount` equal to the inserted chunk count; a
  completed note is untouched.
- [ ] **AC39:** A note that receives a sync metadata/body update whose vectors the
  model gate withheld has `embeddingState == inProcess` and `chunkCount == 0`; a
  note that receives a full vector set is `complete`.
- [ ] **AC40:** `embeddingState` never appears in an encoded `SyncPayload`.
- [ ] **AC41:** An extraction interrupted before completion leaves no file at the
  final model path (only a `.part` temp), so the next launch re-extracts.

### Resolved decisions

| # | Question | Resolution | Why |
|---|---|---|---|
| **D39** | How to make saves crash-safe? | **Durable embedding state**: `beginEmbedding` (body + `inProcess`, one transaction) then background `completeEmbedding`. | The edit is durable at once; a crash mid-embed is recovered at boot. No half-indexed notes. |
| **D40** | When does recovery run? | **After the first frame, in the background**, serialized on one queue. | Startup is not blocked by a 131 MB model load + embedding; each note commits independently. |
| **D41** | Is the new field synced? | **Local-only.** | It is device-local processing state; peers compute their own and it can legitimately differ per device. |
