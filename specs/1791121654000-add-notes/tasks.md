# Tasks: Notes — Add, Read, Edit, and Embed

**Spec directory:** `1791121654000-add-notes`
**Spec:** [`spec.md`](./spec.md) (D1–D34; carries two Plan-found amendments, applied in T44)
**Plan:** [`plan.md`](./plan.md)
**Generated:** 2026-10-04

## Prerequisites

- Read [`spec.md`](./spec.md) — **FR1–FR5** (entities/domain), **FR6–FR9** (chunker/embedder/indexer), **FR10–FR16** (write path), **FR19–FR25** (sync), **FR26–FR36** (UI + chat + search), and **Corrections to the blueprint**.
- Read [`plan.md`](./plan.md) — **§C** (entities, incl. both `@TargetIdProperty` renames), **§D** (reference sites 7→14), **§E** (repository surface + `NotebookCascade`), **§F** (fakes), **§H** (over-fetch), **§I** (sync), **§J** (worker/assets), **§K** (UI).
- Read `AGENTS.md` **Flutter/Dart Development Instructions** — State→Hook→View→Coordinator, `utopia_hooks`, constructor injection, no service locator, pure `lib/models/`.
- Read `docs/data-conventions.md`, `docs/sync-conventions.md`, `docs/shell-conventions.md`.
- **Toolchain:** Flutter 3.47.0 / Dart 3.13.0 (present). **Rust + `flutter_rust_bridge_codegen` + `cargo-ndk`/xcframework tooling is NOT installed yet — required only from M6.**
- **Machine setup:** `make install_objectbox` (host-side ObjectBox native lib) as for the existing suite.

**How to read this list**

- **Strictly sequential.** Each task depends on the previous unless `Depends on` says otherwise; the plan's gates are sequential by construction.
- **Test-first, paired.** Each unit task authors its test(s) before the implementation. A task is not done until its `Satisfies` criteria are demonstrable and its tests are green.
- `Satisfies` names the spec acceptance criteria the task owns.
- Each milestone ends with a **gate** task. A gate is not "it compiles".
- **T38 is a throwaway feasibility spike** and M6 tasks T39–T42 are **gated on it passing**. If it fails, escalate spec D16/D17/D22 rather than proceeding.
- **M1–M5 must be green with no native package used** (the fake seams). An import check in T30 enforces it.

---

## Milestone 1 — Entities, codegen, and domain models (no native)

### T1: Add native packages (resolution only)
- **Files:** `pubspec.yaml`
- **Effort:** Small
- **Depends on:** —
- **Satisfies:** plan §A
- **Steps:**
    1. Add `onnxruntime` and `flutter_rust_bridge` to `dependencies`, no code importing them yet.
    2. Run `flutter pub get` and confirm both resolve on Dart 3.13.
    3. **If either fails to resolve, stop and escalate spec D16/D17** — do not substitute a package silently.
    4. Leave versions as resolved; record them in `docs/data-conventions.md` in T45.

### T2: ObjectBox entities and the notebook relation
- **Files:** `lib/data/objectbox/ob_note.dart`, `ob_note_document.dart`, `ob_note_chunk.dart`, `ob_chat_message.dart` (new); `ob_notebook.dart` (amend)
- **Effort:** Large
- **Depends on:** T1
- **Satisfies:** FR1, FR2, FR3, FR4; AC1, AC2
- **Steps:**
    1. Write `ObNote`, `ObNoteDocument`, `ObNoteChunk`, `ObChatMessage` exactly as plan §C.
    2. **`@TargetIdProperty('noteRef')` on `ObNoteChunk.note` and `@TargetIdProperty('noteOwnerId')` on `ObNoteDocument.note` are mandatory** — without the first, the `ToOne` named `note` generates a `noteId` property that collides with the denormalised column and fails codegen (plan R4, the `publicationRef` failure repeating).
    3. `ObNoteChunk.embedding` uses the identical HNSW config to `ObChunk`: `dimensions: 256`, `cosine`, `neighborsPerNode: 16`, `indexingSearchCount: 100`, `PropertyType.floatVector`.
    4. Declare `createdAt`/`updatedAt` as `@Property(type: PropertyType.dateUtc)`.
    5. Add `final notes = ToMany<ObNote>();` to `ObNotebook` (the `@Backlink('notes')` lives on `ObNote.notebooks`).
    6. Run `make codegen`; it must succeed with zero errors. Commit `objectbox.g.dart` and `objectbox-model.json`.
    7. Assert the generated model shows `dimensions: 256` on `ObNoteChunk` and the `notes` relation on `ObNotebook`.

### T3: Pure domain models
- **Files:** `lib/models/note.dart`, `note_chunk.dart`, `note_search_result.dart`, `chat_message.dart` (new)
- **Effort:** Medium
- **Depends on:** T2
- **Satisfies:** FR5, FR17, FR35, FR36; AC26; NFR1, NFR2
- **Steps:**
    1. `Note { uuid, String? title, body, createdAt, updatedAt, embeddingModelId, chunkCount }` with `copyWith`, `==`, `hashCode`.
    2. `NoteSummary` — a projection with **no body field**.
    3. `NoteChunk { noteUuid, chunkIndex, content, tokenCount, embedding }`.
    4. `NoteSearchResult { NoteChunk chunk, double distance }`.
    5. `ChatMessage { uuid, noteUuid, ChatMessageRole role, text, createdAt }` with `enum ChatMessageRole { user, assistant }` — no sync vocabulary.
    6. Extend the import-directive purity test to cover all five. Run it.

### T4: Entity ↔ domain mapping
- **Files:** `lib/domain_mapping.dart` (amend)
- **Effort:** Medium
- **Depends on:** T3
- **Satisfies:** FR5; NFR1
- **Steps:**
    1. `ObNote ↔ Note`/`NoteSummary`; `ObNoteChunk ↔ NoteChunk` (tagged with the note uuid); `ObChatMessage ↔ ChatMessage`.
    2. Round-trip test: write entities, read back, assert domain equality including `null` title.
    3. No `package:objectbox` import may leak into `lib/models/` (purity test stays green).

### T5: Milestone 1 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T4
- **Satisfies:** AC1, AC2, AC26, AC27
- **Steps:**
    1. `make codegen` succeeds with zero errors; generated files committed.
    2. `flutter analyze` clean.
    3. Purity tests green; existing suite green (no native code imported).

---

## Milestone 2 — Note repository, cascade amendment, note search

### T6: `NoteRepository` interface + in-memory test double
- **Files:** `lib/data/note_repository.dart` (new), `lib/data/in_memory_note_repository.dart` (new)
- **Effort:** Small
- **Depends on:** T5
- **Satisfies:** FR10–FR14, FR17; plan §E
- **Steps:**
    1. Define the interface exactly as plan §E (create, updateMetadata, replaceBodyAndChunks, attach, detach, deleteNote, byUuid, listForNotebook).
    2. Add `NoteRepository` alongside `LibraryRepository`; do not fold notes into `LibraryRepository`.
    3. In-memory double for hook/UI tests (mirrors `InMemoryNotebookRepository`), seeded empty.

### T7: `create` (transactional)
- **Files:** `lib/data/objectbox_note_repository.dart` (new)
- **Effort:** Medium
- **Depends on:** T6
- **Satisfies:** FR10; AC4, AC5
- **Steps:**
    1. Test first: create writes `ObNote` + `ObNoteDocument` + notebook edge in one `runInTransaction(TxMode.write)`; `chunkCount == 0`, `chunkSetVersion == 0`, `embeddingModelId == ''`, `versionCounter == 1`, `createdAt == updatedAt` (ms-truncated UTC).
    2. Empty body is valid and produces no chunks; no embedder is invoked (AC4).
    3. `byUuid` round-trips title/body/dates (AC5).

### T8: `updateMetadata` and `replaceBodyAndChunks`
- **Files:** `lib/data/objectbox_note_repository.dart`, `lib/data/embedding_validation.dart` (reuse)
- **Effort:** Large
- **Depends on:** T7
- **Satisfies:** FR11, FR12; AC7, AC8, AC10, AC11, AC12
- **Steps:**
    1. Test-first: title-only save bumps `versionCounter` + `updatedAt`, leaves `chunkSetVersion` and document version and chunks untouched (AC7).
    2. Body save: validate **every** draft with `validateEmbedding` **before** the transaction; then write body + remove-then-insert chunks + `chunkCount` + advance `chunkSetVersion`/`versionCounter`/document version in one transaction (AC8).
    3. Fault-injection test: an embed-step throw leaves body, chunks, versions byte-for-byte unchanged (AC10).
    4. Wrong-length / non-finite vector throws before the transaction and writes nothing (AC11).
    5. Read-back invariant: every `chunk.noteId == chunk.note.targetId` (AC12).

### T9: `attach` / `detach`
- **Files:** `lib/data/objectbox_note_repository.dart`
- **Effort:** Small
- **Depends on:** T8
- **Satisfies:** FR13; AC13
- **Steps:**
    1. Idempotent attach: three attaches leave exactly one edge (assert the count, not the return).
    2. Detach uses `removeWhere` on the id — test against a freshly queried note so a `remove`-by-identity bug fails (the `ToMany.remove` trap).
    3. Both bump only `versionCounter`, never `chunkSetVersion`.

### T10: `deleteNote` cascade
- **Files:** `lib/data/objectbox_note_repository.dart`
- **Effort:** Medium
- **Depends on:** T9
- **Satisfies:** FR14; AC14
- **Steps:**
    1. One transaction removes chunks, the document row, the chat messages (once T27 lands), and the note row.
    2. Deleting a note never deletes a notebook (AC14).

### T11: Reads — list without body, load with body
- **Files:** `lib/data/objectbox_note_repository.dart`
- **Effort:** Small
- **Depends on:** T10
- **Satisfies:** FR17, FR18; AC3, AC6
- **Steps:**
    1. `listForNotebook` returns `NoteSummary` ordered by `createdAt`; a test asserts `ObNoteDocument` is never queried on the list path (AC6).
    2. `byUuid` loads the body for the editor.
    3. Many-to-many proof: one note attached to two notebooks appears in both lists and both notebooks appear on the note (AC3).

### T12: Notebook delete cascade includes notes
- **Files:** `lib/data/library_repository.dart`, `lib/data/objectbox_library_repository.dart`, `lib/data/sync/sync_deleter.dart`
- **Effort:** Medium
- **Depends on:** T11
- **Satisfies:** FR15; AC15; **spec amendment 1**
- **Steps:**
    1. Change `deleteNotebook`'s return from `List<CascadedPublication>` to `NotebookCascade { publications, notes }`; add `CascadedNote { uuid, versionCounter }` (plan §E; amendment applied to `spec.md` in T44).
    2. Cascade notes **exclusive** to the notebook (chunks + document + messages + row); leave shared notes intact and reachable.
    3. Update `SyncDeleter.deleteNotebookLocally` to tombstone cascaded notes too, in the same transaction.
    4. Test: shared note survives the first notebook's deletion and is reachable from the second (AC15).

### T13: `NoteSearchRepository` with over-fetch
- **Files:** `lib/data/note_search_repository.dart` (new)
- **Effort:** Medium
- **Depends on:** T12
- **Satisfies:** FR35; AC34; plan §H
- **Steps:**
    1. Validate the query vector; return distance-ordered, truncated to `limit`.
    2. **Over-fetch via `FetchBudget.forLimit`** with `scopeFraction = noteChunkCount / totalNoteChunks` — `nearestNeighborsF32`'s `maxResultCount` bounds the ANN sub-query before the `noteId` filter (the publication bug repeating).
    3. Adversarial test (AC34): a note that is a narrow slice of a large note-chunk corpus must return exactly `limit`; prove the naive `fetchCount == limit` under-delivers.
    4. Close every query.

### T14: Milestone 2 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T13
- **Satisfies:** AC3–AC15, AC34
- **Steps:**
    1. `flutter analyze` clean; all M2 tests green.
    2. Confirm the existing publication search suite is untouched and green.

---

## Milestone 3 — Sync

### T15: Note DTOs and the additive payload field
- **Files:** `lib/data/sync/sync_payload.dart`
- **Effort:** Large
- **Depends on:** T14
- **Satisfies:** FR19, FR20; AC16; **spec amendment 2**
- **Steps:**
    1. Add `NoteDto`, `NoteDocumentDto` (carries `noteUuid`), `NoteChunkDto` (carries `noteUuid`), each with its own `version` and reflection-free JSON (plan §I; amendment applied to `spec.md` in T44).
    2. Add `List<NoteDto> notes` to `SyncPayload`; decode **absent = empty** (the `aiConfigs` precedent); decoding stays total — a malformed note record refuses the whole payload.
    3. Test: `encodePayload → decodePayload` round-trips body + chunk set; a malformed record returns null.

### T16: Identity scheme extension
- **Files:** `lib/data/identity.dart`
- **Effort:** Small
- **Depends on:** T15
- **Satisfies:** FR25; AC22
- **Steps:**
    1. Add `noteDocumentUuidFor(uuid) => 'nd-$uuid'` and `noteChunkUuidFor(uuid, i) => 'nc-$uuid-$i'`.
    2. Extend `isValidIdentifier` to accept both, without loosening the existing `c-`/`d-`/uuid forms.
    3. Test acceptance and rejection cases, including that `nc-`/`nd-` do not misparse as `c-`/`d-`.

### T17: `UuidScope` reference sites 8–14
- **Files:** `lib/data/sync/sync_scope.dart`
- **Effort:** Large
- **Depends on:** T16
- **Satisfies:** FR21; AC12, AC21
- **Steps:**
    1. Add `resolveNote`, `resolveNoteDocument`, `attachNoteToNotebook`, `attachNoteDocument`, `attachNoteChunk`; enumerate sites 8–14 in the class doc (never reflectively).
    2. Every site writes **both** the denormalised column and the relation and they must agree.
    3. Test: after ingest, `noteChunk.noteId == noteChunk.note.targetId` (AC12); an edge naming a tombstoned notebook is dropped before resolution, creating no row (AC21).

### T18: Note chunk-set validation
- **Files:** `lib/data/sync/sync_validator.dart`
- **Effort:** Medium
- **Depends on:** T17
- **Satisfies:** FR22; AC16
- **Steps:**
    1. Generalise `validateChunkSet` (or add `validateNoteChunkSet`) to enforce declared count, `chunksIncluded` consistency, contiguous indices, parent uuid, derived identity, and decodable vectors.
    2. A mismatch throws before any write and leaves the store untouched.
    3. Test an empty set is legitimate (declared `0`), and a `chunksIncluded: false` record carrying chunks is refused.

### T19: `SyncApplier` plans and applies notes
- **Files:** `lib/data/sync/sync_apply.dart`
- **Effort:** Large
- **Depends on:** T18
- **Satisfies:** FR22; AC17, AC18, AC21
- **Steps:**
    1. Validate every note set first; plan before resolving (no placeholder rows).
    2. Apply after notebooks, one transaction per note DAG: metadata (+ edges) → body → chunk set, with `applyMetadata`/`applyDocument`/`applyChunkSet` selected by their own axes.
    3. `chunksIncluded: false` never wipes the receiver's note chunks (AC17).
    4. Model gate: a mismatched `embeddingModelId` applies metadata + body, transfers no vectors, leaves `chunkSetVersion` unadvanced, leaves the receiver's note chunk count **exactly 0**, and never relabels a note that holds local chunks (AC18).

### T20: Delete resolution for notes
- **Files:** `lib/data/sync/sync_apply.dart`
- **Effort:** Medium
- **Depends on:** T19
- **Satisfies:** FR23; AC19
- **Steps:**
    1. `_applyDelete` resolves notebook → publication → **note** → config and runs the note cascade in one transaction with the tombstone.
    2. A delete for a note this device never had is still tombstoned.
    3. Test: a payload with a note upsert and a `DeleteDto` for the same uuid applies the delete; a later in-flight upsert cannot resurrect it.

### T21: Delta selection, acknowledgement, watermarks
- **Files:** `lib/data/sync/push_sender.dart`
- **Effort:** Medium
- **Depends on:** T20
- **Satisfies:** FR24; AC20
- **Steps:**
    1. `selectDelta` includes a note when any of its three axes moved; sets `declaredChunkCount` from the selected chunks and `chunksIncluded` from whether the set was selected.
    2. `acknowledge` writes the note's three counters into `ObPeerWatermark` (record uuid key; no schema change).
    3. Test: retitle sends metadata only; a body re-index sends metadata + body + set; a re-index after a first push is selected again.

### T22: Two-store convergence test for notes
- **Files:** `test/sync_note_convergence_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T21
- **Satisfies:** AC3, AC15, AC17–AC20
- **Steps:**
    1. Mirror `sync_convergence_test.dart`: two in-memory stores, push both ways, assert note bodies, chunk sets, edges, and deletions converge.
    2. Include the shared-note notebook-delete case (sender emits separate delete records; receiver obeys, does not re-derive).

### T23: Milestone 3 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T22
- **Satisfies:** AC16–AC22
- **Steps:**
    1. `flutter analyze` clean; all sync tests green, including the existing publication/config suites.
    2. Confirm an old payload with no `notes` decodes to empty and applies cleanly.

---

## Milestone 4 — Chunker, embedder seams, indexer, save semantics (fakes)

### T24: `Tokenizer` + `TextChunker` (fakes)
- **Files:** `lib/data/embedding/text_chunker.dart` (new)
- **Effort:** Large
- **Depends on:** T23
- **Satisfies:** FR6; AC32
- **Steps:**
    1. Define `TextChunk`, `TokenSpan`, `Tokenizer`; `FakeTokenizer` (whitespace = one token, offsets tracked).
    2. Implement heading-aware section split (ATX `^#{1,6}\s`), then the 512-token / 64-overlap window inside oversized sections; content = original substring via character offsets.
    3. Test: empty/whitespace ⇒ `[]`; contiguous 0-based indices; a new chunk per heading, never merged; a >512-token section splits with 64 overlap; `tokenCount` equals the emitted chunk's token count (not words).

### T25: `Embedder` seam (fake)
- **Files:** `lib/data/embedding/embedder.dart` (new)
- **Effort:** Small
- **Depends on:** T24
- **Satisfies:** FR7; AC30, AC31
- **Steps:**
    1. Define `Embedder { modelId, embedDocuments, embedQuery }`.
    2. `FakeEmbedder` returns deterministic 256-dim L2-normalised vectors and records the exact input strings.
    3. Test: `embedDocuments` prefixes `search_document: `, `embedQuery` prefixes `search_query: ` (AC30); output length 256, finite, unit norm (AC31).

### T26: `NoteIndexer`
- **Files:** `lib/data/embedding/note_indexer.dart` (new)
- **Effort:** Small
- **Depends on:** T25
- **Satisfies:** FR9; AC4
- **Steps:**
    1. `index(body)`: chunk → if zero chunks return `[]` with **no** embedder call → else `embedDocuments` → `List<ChunkDraft>`.
    2. Test the empty-body early return invokes the embedder zero times; a non-empty body returns one draft per chunk.

### T27: `ChatMessageRepository`
- **Files:** `lib/data/chat_message_repository.dart` (new), `lib/data/objectbox_note_repository.dart` (cascade hook)
- **Effort:** Small
- **Depends on:** T26
- **Satisfies:** FR34; AC35
- **Steps:**
    1. `listForNote` (ordered by `createdAt`) and `append`; messages carry a `@Unique()` uuid and a note link.
    2. Ensure `deleteNote` cascades messages (wire into T10's cascade).
    3. Test: no message appears in an encoded `SyncPayload`.

### T28: Save coordinator and unindexed condition
- **Files:** `lib/state/use_note_editor.dart` (new), `lib/state/note_editor_state.dart` (new)
- **Effort:** Large
- **Depends on:** T27
- **Satisfies:** FR11, FR29, FR36; AC7, AC8, AC9, AC24, AC36
- **Steps:**
    1. State→Hook: `bodyChanged`/`titleChanged` by exact string equality against the loaded note.
    2. Save dispatch: neither changed ⇒ no write (AC9); title only ⇒ `updateMetadata` with zero embedder calls (AC7); body changed ⇒ `indexer.index` then `replaceBodyAndChunks` (AC8).
    3. Cancel clears dirty and writes nothing (AC24).
    4. Expose `isUnindexed` (non-empty body with `chunkCount == 0`, or model mismatch) for the banner (AC36).
    5. Hook tests via `SimpleHookContext` with the in-memory `NoteRepository` and fakes.

### T29: Bootstrap wiring
- **Files:** `lib/bootstrap.dart`, `lib/app.dart`, `lib/main.dart`
- **Effort:** Medium
- **Depends on:** T28
- **Satisfies:** plan §G; NFR7
- **Steps:**
    1. Build `NoteRepository`, `ChatMessageRepository`, `NoteSearchRepository` over the opened store; hand them to `App` as constructor arguments (no service locator).
    2. Provide a lazily-created `EmbeddingWorker` handle; **do not await model load before `runApp`**.
    3. Keep the test/shell path (supplied repositories, no store opened) working.

### T30: Milestone 4 gate (fakes-only)
- **Files:** —
- **Effort:** Small
- **Depends on:** T29
- **Satisfies:** AC4, AC7, AC8, AC9, AC24, AC26, AC28, AC30–AC33, AC35, AC36
- **Steps:**
    1. `flutter analyze` clean; the full suite green **with no native package imported** — add an import check that `lib/` (except M6 files) does not import `onnxruntime`/`lib/bridge/`.
    2. AC9 (no write on unchanged save) and AC10 exercised.

---

## Milestone 5 — UI

### T31: Enable the Notes section and render the list
- **Files:** `lib/models/notebook_section.dart`, `lib/shell/nav_panel_detail_level.dart`
- **Effort:** Medium
- **Depends on:** T30
- **Satisfies:** FR26, FR18; AC23
- **Steps:**
    1. Mark `notes` enabled; render its selection from the active route, not a hardcoded `selected: enabled`.
    2. Under it, render the notebook's notes (`useNotesList`) ordered by `createdAt`, plus **Add note**.
    3. Empty title renders the shared `Untitled note` placeholder (presentation only).

### T32: Nested note routes
- **Files:** `lib/router/app_router.dart`
- **Effort:** Medium
- **Depends on:** T31
- **Satisfies:** FR27, FR30; AC23
- **Steps:**
    1. Add `/notebook/:notebookId/note/new` and `/notebook/:notebookId/note/:noteId` as keyed `CustomTransitionPage`s.
    2. Give `appRouter` the note repository for existence checks; a missing note redirects to the notebook detail.
    3. Wire Add note → `.../note/new`.

### T33: Note list/editor hooks
- **Files:** `lib/state/use_notes_list.dart` (new), `lib/state/notes_list_state.dart` (new)
- **Effort:** Medium
- **Depends on:** T32
- **Satisfies:** FR26; plan §K
- **Steps:**
    1. `useNotesList(notebookId, repo)` returning a State with the summaries and refresh/create actions; constructor-injected repository, no global provider.
    2. Hook tests with the in-memory repository.

### T34: `NoteEditorPage` — Save/Cancel, banner
- **Files:** `lib/pages/note_editor_page.dart` (new)
- **Effort:** Large
- **Depends on:** T33
- **Satisfies:** FR27, FR28, FR29, FR36; AC24, AC36
- **Steps:**
    1. Coordinator + View: title field, multi-line body field, seeded from the note.
    2. Save and Cancel appear **only when dirty**; Cancel restores last-saved and clears dirty.
    3. Save invokes the coordinator from T28; a failed embed surfaces an error and the store is unchanged.
    4. Render the unindexed banner (FR36) and assert it blocks no editing.
    5. Widget tests: dirty visibility, Cancel reset, error path.

### T35: `ChatPanelGeometry`
- **Files:** `lib/models/chat_panel_geometry.dart` (new)
- **Effort:** Small
- **Depends on:** T34
- **Satisfies:** FR31; plan §K
- **Steps:**
    1. Pure-Dart width maths (fraction + min/max clamp, rail width), mirroring `PanelGeometry`, testable with a plain `test()`.
    2. Tests for degenerate widths (`NaN`, negative, tiny).

### T36: `ChatPanel` widget
- **Files:** `lib/shell/chat_panel.dart` (new), `lib/pages/note_editor_page.dart` (layout)
- **Effort:** Large
- **Depends on:** T35
- **Satisfies:** FR31, FR32, FR34; AC25, AC35
- **Steps:**
    1. Right-docked, collapsible to a rail; collapse state transient (D26).
    2. Message list from `listForNote`, oldest→newest, auto-scrolled to newest.
    3. Bottom multi-line input, 3 rows default, internally scrollable, vertically resizable by a drag handle (grows the input, not the window); the input does not append.
    4. Widget tests: collapse/expand, ordering, default input height, resize, empty state.

### T37: Milestone 5 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T36
- **Satisfies:** AC23, AC24, AC25
- **Steps:**
    1. `flutter analyze` clean; widget tests green; existing shell/nav tests green (R10).
    2. Manual macOS pass: add note → save → edit → cancel → save → open chat panel → resize input.

---

## Milestone 6 — Native stack (gated on the spike)

### T38: Feasibility spike (throwaway)
- **Files:** none kept — scratch only
- **Effort:** Large
- **Depends on:** T37
- **Satisfies:** plan R1, R2, R3
- **Steps:**
    1. In a scratch copy, build `flutter_rust_bridge` tokenizer bindings and confirm they build for macOS, iOS, Android, Windows, Linux (or document exactly which fail).
    2. Confirm `onnxruntime` initialises and runs one embedding on each target that advertises support.
    3. Export/quantise `nomic-ai/nomic-embed-text-v1.5` to a **portable dynamic-INT8** `.onnx`; load it and embed one string; confirm the output truncates to 256 dims and L2-normalises.
    4. Measure the artefact size against the ~150 MB guide (D32).
    5. **Gate:** if any target cannot be supported, stop and escalate spec D16/D17/D22 before T39. Keep no spike code.

### T39: Rust tokenizer crate + FRB bridge
- **Files:** `native/rust_tokenizer/` (new), `lib/bridge/` (generated), `lib/data/embedding/native_tokenizer.dart` (new)
- **Effort:** Large
- **Depends on:** T38 passing
- **Satisfies:** FR8 (tokenise), FR6 (offsets); AC32
- **Steps:**
    1. Crate exposing init/tokenize and **token offsets** (`get_offsets()`), per the blueprint's shape.
    2. Generate bindings with `flutter_rust_bridge_codegen`; commit `lib/bridge/`; never hand-edit.
    3. `NativeTokenizer implements Tokenizer`; contract test against the real tokenizer for chunker boundaries.

### T40: `OnnxEmbedder`
- **Files:** `lib/data/embedding/onnx_embedder.dart` (new)
- **Effort:** Large
- **Depends on:** T39
- **Satisfies:** FR8; AC30, AC31
- **Steps:**
    1. Pipeline exactly: prefix → tokenise → session run → masked mean-pool → MRL slice to 256 → L2 normalise → release tensors in `finally`.
    2. Session opened once and cached; `modelId = nomic-embed-text-v1.5:onnx:int8:256`.
    3. Reject wrong-length/non-finite output at the seam.

### T41: Long-lived embedding worker
- **Files:** `lib/data/embedding/embedding_worker.dart` (new)
- **Effort:** Medium
- **Depends on:** T40
- **Satisfies:** FR9, NFR7; AC33
- **Steps:**
    1. `Isolate.spawn` worker owning the session; UI isolate sends `(texts, purpose)` and receives vectors.
    2. **No `Isolate.run` per call** (spec correction 3). Test asserts the model is loaded exactly once across N embeds (AC33).

### T42: Assets, copy-once, EPs, bootstrap wiring
- **Files:** `pubspec.yaml` (`assets:`), `lib/data/embedding/onnx_embedder.dart`, `lib/bootstrap.dart`
- **Effort:** Large
- **Depends on:** T41
- **Satisfies:** FR8a; D25, D32, D34; plan §J
- **Steps:**
    1. Bundle `assets/models/nomic_embed_text_v1.5_quantized.onnx` and `assets/tokenizers/tokenizer.json`; copy once to the application-support directory on first use and hand the runtime the path.
    2. Enable Core ML (Apple), NNAPI (Android), DirectML (Windows), CPU (Linux), with CPU fallback; a failed EP logs and degrades.
    3. Swap the real seams into bootstrap's production path only.

### T43: Milestone 6 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T42
- **Satisfies:** AC30, AC31, AC32, AC33; plan §J
- **Steps:**
    1. Real-stack contract tests green; model loads once.
    2. Per-target smoke: app launches and embeds on each of the five targets.
    3. Size measured and recorded; if >150 MB, record the raised budget (D32).

---

## Milestone 7 — Verification, docs, and spec amendments

### T44: Apply the spec amendments at the source
- **Files:** `specs/1791121654000-add-notes/spec.md`
- **Effort:** Small
- **Depends on:** T43
- **Satisfies:** AGENTS.md escalation rule; plan "Spec amendments"
- **Steps:**
    1. FR14/FR15: specify `NotebookCascade { publications, notes }` and `CascadedNote { uuid, versionCounter }`.
    2. FR20/FR21: state that `NoteDocumentDto`/`NoteChunkDto` carry `noteUuid` and their own `version`.
    3. Do not change a goal, non-goal, or AC intent.

### T45: Documentation
- **Files:** `docs/data-conventions.md`, `README.md`
- **Effort:** Medium
- **Depends on:** T44
- **Satisfies:** NFR5, plan §B/§J
- **Steps:**
    1. Record the note entities, reference sites 8–14, the embedding stack (packages pinned, model, asset, EPs), the Rust toolchain setup, and the `make` targets.
    2. Note the assets and native build steps so a fresh checkout builds.

### T46: Final verification
- **Files:** —
- **Effort:** Medium
- **Depends on:** T45
- **Satisfies:** AC27, AC28, AC29
- **Steps:**
    1. `flutter analyze` + full `flutter test` green; generated files committed and drift-free.
    2. Manual macOS pass across add/edit/save/cancel/search(banner)/chat-panel/notebook-delete-with-notes.
    3. Confirm the existing publication, search, sync, and shell suites pass unmodified except where the amendments (T12, T15–T21) required a signature change.

---

## Dependency summary

M1(T1–T5) → M2(T6–T14) → M3(T15–T23) → M4(T24–T30) → M5(T31–T37) → M6(T38–T43) → M7(T44–T46), strictly sequential. T38 is a spike and gates T39–T42. T44 applies the two spec amendments; T45–T46 verify.
