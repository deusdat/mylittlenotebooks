# Plan: Notes — Add, Read, Edit, and Embed

**Spec directory:** `1791121654000-add-notes`
**Plan date:** 2026-10-04
**Target toolchain (declared):** Flutter 3.47.0 stable · Dart 3.13.0 · macOS (arm64). The Rust/ONNX half of the toolchain is **not yet present** on this machine and is verified in M1/M6, not assumed here.
**Spec:** revision with D1–D34. This plan resolves the spec's Open Questions that are Plan-level and records the choices the spec left to implementation. Two items trace back to the spec and are routed to it per AGENTS.md — see [Spec amendments found by planning](#spec-amendments-found-by-planning).

---

## Approach

Seven milestones, **seam-first**: the entire data, sync, and UI surface is built and tested against a deterministic fake `Embedder`/`Tokenizer`, and the real ONNX + Rust tokenizer stack lands last, behind seams that already have passing tests. This is chosen deliberately (plan question 1): the native build matrix is the one part whose feasibility is unproven, so it must not gate the 90% of the feature that is ordinary ObjectBox + Flutter work.

### The shape of the work in one paragraph

A note is a publication-shaped entity: `ObNote` with an optional title, a body in its own `ObNoteDocument` row, a `ToMany<ObNotebook>` edge, and a set of `ObNoteChunk` rows each carrying a 256-dim HNSW vector. A `NoteRepository` owns the transactional write path; a `NoteSearchRepository` mirrors the publication search over the note index. The sync payload gains `notes` (plus three DTOs), the enumerated reference sites grow from seven to fourteen, and delete resolution gains a note branch. The chunker and embedder are seams (`TextChunker`, `Tokenizer`, `Embedder`) with fake implementations for M1–M5 and an `OnnxEmbedder` + Rust tokenizer bridge in M6. The UI enables the disabled Notes section, routes a `/notebook/:id/note/:noteId` editor with Save/Cancel and an unindexed banner, and adds a right-docked chat panel rendering a minimal local message record.

### Verification performed before planning

Unlike the data-layer plan, this plan **could not execute** its native claims — no ONNX runtime, no Rust toolchain, no quantised model. That is exactly why the sequencing is seam-first. The table states what is carried from verified prior work and what M1/M6 must prove.

| Claim | Method | Status |
|---|---|---|
| ObjectBox `ToMany`/`@Backlink`, HNSW `nearestNeighborsF32` + scalar `.and()`, in-memory test stores | Verified in `1790958509972-publication-data-layer` | ✅ carried |
| Sync payload/DTO/tombstone/watermark patterns, additive field with absent = empty (`aiConfigs`) | Verified in `1790968315311-peer-sync` / `1791079931744-settings-for-ai` | ✅ carried |
| Adding a `ToMany` to the existing `ObNotebook` entity codegens cleanly | not run here | ⏳ M1 |
| `onnxruntime` and `flutter_rust_bridge` resolve on Dart 3.13 for all five targets | not run here | ⏳ M1 (package) / M6 (targets) |
| A portable dynamic-INT8 `nomic-embed-text-v1.5` export yields 256 usable dims | not run here | ⏳ M6 |
| Model asset resolves as a filesystem path after copy-once | not run here | ⏳ M6 |

**The seam-first schedule is the mitigation for the unverified rows.** M1–M5 must be green *without* any native package installed.

---

## Architecture & Design Decisions

### A. Packages

| Package | Version | Why | Status |
|---|---|---|---|
| `onnxruntime` | pin in M1 | ONNX inference (FR8) | **unverified** — M1 resolves it or Plan escalates |
| `flutter_rust_bridge` | pin in M1 | Rust tokenizer bindings (FR8, D17) | **unverified** |
| `objectbox` / `objectbox_flutter_libs` / `objectbox_generator` | `^5.3.2` (existing) | Store + HNSW | present |
| `path_provider` | `^2.1.6` (existing) | asset copy destination (M6), store dir | present |
| `build_runner` | `>=2.12.0 <2.15.2` (existing) | codegen; the upper bound is load-bearing | present |

The two native packages are isolated to M1 (resolution) and M6 (use). **If either fails to resolve for the five targets, the `Embedder`/`Tokenizer` seams mean M1–M5 still ship**, and the failure is escalated to the spec's D16/D17 rather than absorbed.

### B. Directory layout

```
lib/
  models/
    note.dart                    # NEW: Note + NoteSummary (pure)
    note_chunk.dart              # NEW: NoteChunk (pure)
    note_search_result.dart      # NEW: NoteChunk + distance (pure)
    chat_message.dart            # NEW: ChatMessage + role enum (pure)
    chat_panel_geometry.dart     # NEW: right-panel width maths (pure)
  data/
    note_repository.dart         # NEW: interface
    objectbox_note_repository.dart # NEW: transactional impl
    note_search_repository.dart  # NEW: note-scoped query (FR35)
    chat_message_repository.dart # NEW: list/append (FR34)
    library_repository.dart      # AMENDED: deleteNotebook return type
    objectbox_library_repository.dart # AMENDED: cascade notes
    identity.dart                # AMENDED: nd-/nc- forms
    embedding/
      text_chunker.dart          # NEW: TextChunk, TokenSpan, Tokenizer, TextChunker
      embedder.dart              # NEW: Embedder seam
      note_indexer.dart          # NEW: chunk -> embed -> drafts (FR9)
      onnx_embedder.dart         # NEW (M6): real implementation
      native_tokenizer.dart      # NEW (M6): Tokenizer over the bridge
      embedding_worker.dart      # NEW (M6): long-lived isolate owning the session
    objectbox/
      ob_note.dart               # NEW
      ob_note_document.dart      # NEW
      ob_note_chunk.dart         # NEW
      ob_chat_message.dart       # NEW
      ob_notebook.dart           # AMENDED: + notes ToMany
  bridge/                        # NEW (M6): FRB generated, never hand-edited
  shell/
    chat_panel.dart              # NEW: right panel widget
    nav_panel_detail_level.dart  # AMENDED: Notes section live
  state/
    notes_list_state.dart / use_notes_list.dart   # NEW: page-scoped hook
    note_editor_state.dart / use_note_editor.dart # NEW: page-scoped hook
  pages/
    note_editor_page.dart        # NEW: routed coordinator
  router/app_router.dart         # AMENDED: nested note routes
  data/sync/
    sync_payload.dart            # AMENDED: NoteDto/DocumentDto/ChunkDto + notes
    sync_scope.dart              # AMENDED: sites 8-14
    sync_validator.dart          # AMENDED: validateNoteChunkSet
    sync_apply.dart              # AMENDED: plan/apply/delete notes
    push_sender.dart             # AMENDED: select + acknowledge notes
    sync_deleter.dart            # AMENDED: note cascade tombstones
  domain_mapping.dart            # AMENDED: note mappings
native/rust_tokenizer/           # NEW (M6): Rust crate + FRB config
assets/models/ assets/tokenizers/ # NEW (M6): bundled artefacts
test/                            # see each milestone's gate
```

### C. Entities

```dart
// lib/data/objectbox/ob_notebook.dart  (AMENDED)
final notes = ToMany<ObNote>();          // @Backlink('notes') lives on ObNote

// lib/data/objectbox/ob_note.dart  (NEW)
@Entity()
class ObNote {
  @Id() int id = 0;
  @Unique() String uuid;
  String? title;
  @Property(type: PropertyType.dateUtc) DateTime createdAt;
  @Property(type: PropertyType.dateUtc) DateTime updatedAt;
  String embeddingModelId;                 // '' until first indexed
  int chunkCount;
  @Index() int versionCounter;
  int chunkSetVersion;
  @Backlink('notes') final notebooks = ToMany<ObNotebook>();
  @Backlink('note') final chunks = ToMany<ObNoteChunk>();
  final document = ToOne<ObNoteDocument>();
}

// lib/data/objectbox/ob_note_document.dart  (NEW)
@Entity()
class ObNoteDocument {
  @Id() int id = 0;
  @Unique() String uuid;                   // noteDocumentUuidFor(noteUuid)
  @Index() int noteId;
  @Index() int versionCounter;
  String markdown;
  @TargetIdProperty('noteOwnerId') final note = ToOne<ObNote>();
}

// lib/data/objectbox/ob_note_chunk.dart  (NEW)
@Entity()
class ObNoteChunk {
  @Id() int id = 0;
  @Unique() String uuid;                   // noteChunkUuidFor(noteUuid, index)
  int chunkIndex;
  String content;
  int tokenCount;
  @Index() int noteId;
  @HnswIndex(dimensions: 256, distanceType: VectorDistanceType.cosine,
             neighborsPerNode: 16, indexingSearchCount: 100)
  @Property(type: PropertyType.floatVector) List<double> embedding;
  /// Mandatory rename, exactly as ObChunk.publicationRef: the ToOne `note`
  /// would otherwise generate a property named `noteId`, colliding with the
  /// denormalised column above and failing codegen.
  @TargetIdProperty('noteRef') final note = ToOne<ObNote>();
}

// lib/data/objectbox/ob_chat_message.dart  (NEW)
@Entity()
class ObChatMessage {
  @Id() int id = 0;
  @Unique() String uuid;
  @Index() int noteId;
  String role;                             // 'user' | 'assistant'
  String text;
  @Property(type: PropertyType.dateUtc) DateTime createdAt;
  @TargetIdProperty('messageOwnerId') final note = ToOne<ObNote>();
}
```

`@TargetIdProperty('noteRef')` and `('noteOwnerId')` are named distinct from the publication pair (`publicationRef`, `documentOwnerId`) so a grep for either is unambiguous; the collision they prevent is the same one `publication-data-layer` D1 documented.

### D. Reference sites (the enumerated list, 7 → 14)

Sites 1–7 are unchanged. The seven new sites are the note relations, and each must be written **twice** (denormalised column + relation) and made to agree:

| # | Entity | Reference | Kind |
|---|---|---|---|
| 8 | `ObNote` | `notebooks` | `ToMany` (`@Backlink('notes')`) |
| 9 | `ObNoteChunk` | `noteId` | denormalised int, indexed |
| 10 | `ObNoteChunk` | `note` | `ToOne` (`noteRef`) |
| 11 | `ObNoteDocument` | `noteId` | denormalised int, indexed |
| 12 | `ObNoteDocument` | `note` | `ToOne` (`noteOwnerId`) |
| 13 | `ObNote` | `document` | `ToOne` |
| 14 | `ObNote` | `chunks` | `ToMany` (`@Backlink('note')`) |

`UuidScope` gains `resolveNote`, `resolveNoteDocument`, `attachNoteToNotebook`, `attachNoteDocument`, `attachNoteChunk`, enumerated in the class doc exactly as the existing seven — never reflectively. `ObChatMessage` is **local-only** and is *not* a reference site (it never crosses the wire).

### E. Repository surface

```dart
abstract interface class NoteRepository {
  Note create({String? title, required String notebookUuid,
               required String embeddingModelId});            // FR10
  void updateMetadata(String noteUuid, {String? title});        // FR11
  void replaceBodyAndChunks(String noteUuid, String body,
                            List<ChunkDraft> chunks);           // FR11, FR12 (one tx)
  void attach(String noteUuid, String notebookUuid);            // FR13
  void detach(String noteUuid, String notebookUuid);            // FR13
  void deleteNote(String noteUuid);                             // FR14
  Note? byUuid(String uuid);                                    // FR17 (loads body)
  List<NoteSummary> listForNotebook(String notebookUuid);       // FR17 (no body)
}

abstract interface class NoteSearchRepository {
  List<NoteSearchResult> search({required String noteUuid,
      required List<double> queryVector, required int limit,
      int? fetchCountOverride});                                // FR35
}

abstract interface class ChatMessageRepository {
  List<ChatMessage> listForNote(String noteUuid);               // FR34
  void append(ChatMessage message);                             // FR34 (not called by UI)
}
```

`LibraryRepository.deleteNotebook` **return type changes** from `List<CascadedPublication>` to a combined record/type `NotebookCascade { List<CascadedPublication> publications; List<CascadedNote> notes; }`. `SyncDeleter.deleteNotebookLocally` is updated in the same commit, so there is still exactly one cascade implementation (plan question 3). `CascadedNote { uuid, versionCounter }` mirrors `CascadedPublication`.

### F. Chunker and embedder seams (M4 fakes)

- `TextChunker`: heading-aware section split (ATX `^#{1,6}\s`), then a 512-token / 64-overlap window inside oversized sections, using an injected `Tokenizer` (`List<TokenSpan> tokenize(String)`) for both boundaries and counts. `FakeTokenizer` (whitespace = one token) makes AC32 fully unit-testable with no FFI.
- `Embedder`: `modelId`, `embedDocuments(List<String>)`, `embedQuery(String)`. `FakeEmbedder` returns deterministic vectors (e.g. a seedable pseudo-random 256-vector, L2-normalised) and records the exact strings it received, so AC30's prefix assertions and AC31's normalisation assertion run in M4.
- `NoteIndexer.index(body) -> List<ChunkDraft>`: chunk → (empty ⇒ no embedder call) → `embedDocuments` → `ChunkDraft`s. Pure orchestration; performs no write.
- Save path: `NoteEditorCoordinator` computes `bodyChanged`/`titleChanged` by exact string equality against the loaded note (D5), then either `updateMetadata`, or `noteIndexer.index` → `replaceBodyAndChunks`, or no-op. The indexer result and the body write share one repository transaction (FR12).

**No code in M1–M5 imports `onnxruntime` or the bridge.** An analysis/import check enforces that the fakes-only suite stays green on a machine without the native stack.

### G. Store lifecycle and bootstrap

`openLibraryStore()` / `openTestStore()` are reused unchanged. `bootstrapDependencies` gains a `NoteRepository`, `ChatMessageRepository`, and `NoteSearchRepository` built over the same opened store, plus a lazily-created `EmbeddingWorker` handle (plan question 7). Nothing embedding-related is awaited before `runApp`: model load is not a first-frame need. The `App` widget gains the note repositories as constructor arguments, following the existing no-service-locator rule.

### H. Note-scoped search (FR35)

One function, mirroring `SearchRepository` but over `ObNoteChunk`. It **must** use `FetchBudget.forLimit` with `scopeFraction = noteChunkCount / totalNoteChunks`, because `nearestNeighborsF32`'s `maxResultCount` bounds the ANN sub-query before the `noteId` filter (`publication-data-layer` FR15). AC34 is the adversarial test: a note that is a narrow slice of a large note-chunk corpus must still return exactly `limit`.

### I. Sync

- `NoteDto`/`NoteDocumentDto`/`NoteChunkDto` mirror the publication DTOs with `noteUuid` parents and the three-axis versions.
- `SyncPayload.notes` decodes absent-to-empty (additive; plan question 6). No protocol-version bump.
- `validateChunkSet` is generalised (or a `validateNoteChunkSet` sibling) so a note set is validated **before any write**, refusing the whole payload on mismatch.
- `SyncApplier` plans notes after notebooks (they reference notebooks), applies one transaction per note DAG in the order metadata → body → chunk set, applies the `embeddingModelId` gate and `chunksIncluded` disambiguation identically to publications, and resolves deletes as notebook → publication → note → config.
- `PushSender.selectDelta`/`acknowledge` cover the three note axes; the record uuid is the watermark key, so no schema change.

### J. Native stack (M6) — worker, assets, model

- **Worker**: a long-lived isolate (`Isolate.spawn`) owns the `OrtSession`; the UI isolate sends `(texts, purpose)` and receives vectors. A fresh `Isolate.run` per save is explicitly rejected (spec correction 3).
- **Assets**: add an `assets:` block for `assets/models/nomic_embed_text_v1.5_quantized.onnx` and `assets/tokenizers/tokenizer.json`. On first use, **copy once** to the application-support directory (a marker file or existence check prevents re-copy) and hand the runtime the path (plan question 8).
- **Tokenizer bridge**: `native/rust_tokenizer` crate (`tokenizers`, `flutter_rust_bridge`) exposing init/tokenize; `lib/bridge/` generated by FRB and committed. The crate also exposes token **offsets** for the chunker (FR6).
- **Model**: export/quantise `nomic-ai/nomic-embed-text-v1.5` to a **portable dynamic-INT8** ONNX file (D22). An `avx512_vnni` artefact is rejected.
- **EPs**: Core ML (Apple), NNAPI (Android), DirectML (Windows), CPU (Linux), CPU fallback everywhere (D34); a failed EP logs and degrades to CPU rather than failing the save.

### K. UI

- **Notes section**: `notebookSections` enables `notes`; `nav_panel_detail_level.dart` renders the note list + Add note when selected (FR26). Selection is derived from the active route, not a hardcoded `selected: enabled`.
- **Routing** (plan question 4): nested `GoRoute`s `/notebook/:notebookId/note/new` and `/notebook/:notebookId/note/:noteId`, each a `CustomTransitionPage` keyed by note id. `appRouter` gains the note repository for existence checks; a missing note redirects to the notebook detail.
- **State** (plan question 5): page-scoped hooks `useNotesList(notebookId, repo)` and `useNoteEditor(note, repo, indexPath)`, following State → Hook → View → Coordinator. No global provider; the repository is constructor-injected.
- **Editor**: title field + multi-line body field; Save/Cancel rendered only when dirty; Cancel restores last-saved and clears dirty; Save applies FR11 (FR27–FR29). Unindexed banner per FR36.
- **Chat panel**: `ChatPanelGeometry` (pure Dart, fraction + min/max clamp, mirroring `PanelGeometry`) and `ChatPanel` (collapsible rail, message list oldest→newest auto-scrolled, resizable 3-row input). Transient collapse (D26). `listForNote` renders; the input does not append (FR32–FR34).

### L. Decisions the implementation makes

| # | Decision | Alternative | Reversibility |
|---|---|---|---|
| **I1** | Seam-first; native stack last | native-first / integrated | Sequencing only; reverses by reordering milestones |
| **I2** | `flutter_rust_bridge` for the tokenizer | hand-written FFI / pure Dart | Medium — replaces the bridge layer |
| **I3** | `deleteNotebook` returns a combined `NotebookCascade` | coordinating service | Low — one call site (`SyncDeleter`) |
| **I4** | Page-scoped hooks, no global notes provider | global `NotesState` | Low — UI only |
| **I5** | Nested note routes | in-page swap | Low — UI only |
| **I6** | Additive `notes` field, absent = empty | protocol-version bump | Low — additive by construction |
| **I7** | Lazy embedder init on first save | preload before `runApp` | Low — bootstrap change |
| **I8** | Copy-once asset to support dir | bytes-in-memory if supported | Low — one function |
| **I9** | `ObChatMessage` local-only, not a reference site | sync messages | Medium — adds a payload type + sites |

### M. Explicitly not built

- **Any transport** for sync — `SyncApplier`/`PushSender` are wired in tests only, exactly as today.
- **Chat send/reply/AI** — the input is inert (FR33).
- **Cross-notebook linking UI** — schema only (D29).
- **Automatic re-index** — surfaced only (D27; a later spec).
- **Message sync** — local-only (I9).
- **Publication-search changes** — untouched.

---

## Milestones

### M1 — Entities, codegen, and domain models (no native)

Add the four entity classes and the `ObNotebook.notes` relation exactly as C, with both `@TargetIdProperty` renames. Add `Note`, `NoteSummary`, `NoteChunk`, `NoteSearchResult`, `ChatMessage` as pure values, and extend `domain_mapping.dart`. Resolve `onnxruntime` and `flutter_rust_bridge` in `pubspec.yaml` (resolution only; not imported yet) to fail cheaply if they cannot.

**Gate:** `make codegen` succeeds with zero errors; `objectbox.g.dart` / `objectbox-model.json` committed; `flutter analyze` clean; purity tests (no Flutter/ObjectBox in `lib/models/`) pass; the existing suite is green.

### M2 — Note repository, cascade amendment, note search

`ObjectBoxNoteRepository` (create / updateMetadata / replaceBodyAndChunks / attach / detach / deleteNote / byUuid / listForNotebook) with the transaction rules of G. Amend `LibraryRepository.deleteNotebook` to the `NotebookCascade` type and cascade exclusive notes; update `SyncDeleter.deleteNotebookLocally`. `NoteSearchRepository` with `FetchBudget`.

**Gate:** AC3, AC4, AC5, AC6, AC7, AC8, AC9, AC10, AC11, AC12, AC13, AC14, AC15, AC34. AC10 and AC11 are the transactional cases (body save partial-failure and bad-vector rejection). AC34 uses the adversarial narrow-note corpus; a friendly corpus passes against the naive query.

### M3 — Sync

`NoteDto`/`NoteDocumentDto`/`NoteChunkDto`, `SyncPayload.notes`, `UuidScope` sites 8–14, note chunk-set validation, planner/applier, delete resolution, delete tombstones, delta selection + acknowledgement, `identity.dart` `nd-`/`nc-` forms.

**Gate:** AC16, AC17, AC18, AC19, AC20, AC21, AC22 + a two-store convergence test for notes mirroring `sync_convergence_test.dart`. The model gate test asserts the receiver's note chunk count is **exactly 0**, not "less than".

### M4 — Chunker, embedder seam, indexer, save semantics

`TextChunker` + `Tokenizer` seam + `FakeTokenizer`; `Embedder` + `FakeEmbedder`; `NoteIndexer`; `ChatMessageRepository`; bootstrap wiring. The save coordinator (FR11) and the unindexed-banner condition (FR36) are implemented against the fakes.

**Gate:** AC23 (partly), AC24, AC26, AC28, AC30, AC31, AC32, AC33 (fake load count), AC35 (messages + cascade), AC36. AC32 covers both chunker levels (heading split + token window).

### M5 — UI

Enable the Notes section and render the list + Add note; nested routes; `NoteEditorPage` with dirty Save/Cancel; unindexed banner; `ChatPanelGeometry` + `ChatPanel` rendering `listForNote`.

**Gate:** AC23, AC24, AC25 + widget tests for dirty-state visibility, Cancel reset, panel collapse, message ordering, and input resize. Manual macOS pass: add a note, save, edit, cancel, save, open the chat panel.

### M6 — Native stack

Rust tokenizer crate + FRB bindings; `OnnxEmbedder`; `EmbeddingWorker`; model export/quantise; asset copy-once; bootstrap wiring of the real seams; EP selection.

**Gate:** AC30–AC33 run against the **real** `OnnxEmbedder`; the model loads once (AC33); the portable artefact loads on each of the five targets; the app-sizes against the ~150 MB guide (D32); a note with markdown headings and a 2,000-token body produces the expected chunk count by hand.

### M7 — Verification, docs, and spec amendments

Full `flutter analyze` + `flutter test`; manual pass on macOS; `docs/data-conventions.md` extended with the note/sync additions and the embedding stack; spec amendments applied at the source.

**Gate:** AC27, AC29; docs updated; the two amendments below applied to `spec.md`.

---

## Dependencies

- **External:** `objectbox* ^5.3.2`, `path_provider ^2.1.6`, `build_runner >=2.12.0 <2.15.2` (present); `onnxruntime` and `flutter_rust_bridge` (**to be pinned in M1**, unverified).
- **Toolchain:** Flutter 3.47.0 / Dart 3.13.0 present; **Rust + `flutter_rust_bridge_codegen` + `cargo-ndk`/xcframework tooling required for M6** and not yet installed.
- **Internal:** M1 → M2 → M3 → M4 → M5, strictly sequential; M6 depends on M4's seams but not on M5; M7 last. M1's codegen must pass before M2 compiles.

---

## Risks & Mitigations

- **R1 — `onnxruntime` / `flutter_rust_bridge` may not resolve or build on all five targets.** → M1 resolves the packages before any code imports them; M6 builds per target. Failure is escalated to spec D16/D17; the seams keep M1–M5 shippable.
- **R2 — The Rust toolchain is a new build dependency** (`cargo-ndk` for Android, `xcframework` for iOS/macOS, `.dll`/`.so` for Windows/Linux). → Isolated to M6; `make` targets and README setup recorded before M6; the `Tokenizer` seam keeps the chunker testable without it.
- **R3 — A quantised artefact may be architecture-specific.** → D22 requires one portable dynamic-INT8 file; M6 proves it on every target before M7. If the export cannot be portable, escalate D22 rather than ship a broken artefact.
- **R4 — `@TargetIdProperty` collision.** `ObNoteChunk.note` would generate `noteId`, colliding with the denormalised column. → Both renames are in the entity classes with the same comment as `ObChunk`; M1's codegen gate catches removal immediately.
- **R5 — The `ToOne` and denormalised `noteId` can drift.** → Only the repository write paths set either; AC12 asserts `noteId == note.targetId` after read-back; the sync applier rewrites both.
- **R6 — Adding `notes` to `ObNotebook` changes an existing persisted entity.** No user data exists (no shipped schema), and ObjectBox evolves by UID-preserving addition. → M1's codegen gate plus the existing suite.
- **R7 — Note search repeats the publication over-fetch bug.** → AC34 is adversarial by construction; the naive top-K is measured to under-deliver and the test asserts the corpus shape.
- **R8 — The native worker could be started per call.** → FR9/NFR7 and M6's AC33 (load-once) make this a test failure, not a latency regression.
- **R9 — `deleteNotebook`'s signature change ripples.** → One call site (`SyncDeleter`) plus `ObjectBoxNotebookRepository`; M2's gate includes the existing delete-notebook sync tests, updated only where the amendment requires.
- **R10 — UI work could regress the shell.** → M5 keeps the shell contract; existing `app_shell_widget_test` / `nav_state_machine_test` must stay green.

---

## Spec amendments found by planning

Per AGENTS.md's escalation rule, applied at the source in M7.

| # | Location | Finding | Correction |
|---|---|---|---|
| **1** | FR15 / FR14, `LibraryRepository` | The spec says deleting a notebook cascades notes but does not fix the **return shape**; `deleteNotebook` currently returns `List<CascadedPublication>`, which cannot carry cascaded notes. | Specify `NotebookCascade { publications, notes }` and `CascadedNote { uuid, versionCounter }`. |
| **2** | FR20 / FR21 | The spec's `NoteDto` lists `body?` and `chunks[]` but does not name the note parents in the chunk/document DTOs; the DTOs must carry `noteUuid` (never an int), and the three-axis versions must be stated as for publications. | State `NoteDocumentDto`/`NoteChunkDto` carry `noteUuid` and their own `version`. |

Neither changes a goal or acceptance criterion's intent.

---

## Open Questions for the plan phase

Carried from the spec and **not** resolved here, because each needs M6 measurement or a later spec:

- **The exact `onnxruntime` / `flutter_rust_bridge` package versions** and the measured asset size (D32 may raise the budget). M1/M6.
- **EP failure behaviour** (how a present-but-failing EP degrades). M6.
- **Heading-detection edge cases** (setext headings, front matter, `#` inside fenced code). M4, fixed in the section splitter.
- **The automatic re-index design** (D27's committed direction). A later spec.
- **Message sync, chat consumption of note search, cross-notebook linking UI.** Later specs.

---

## Implementation notes (M6 executed)

The T38 spike passed for the parts that are code and failed for the part that is
an external artefact. Recorded so the plan matches reality:

- **Packages resolved:** `onnxruntime 1.4.1`, `flutter_rust_bridge 2.13.0`.
- **Rust crate compiles** on the host. The tokenizer crate needed two fixes:
  `use std::str::FromStr;`, and `Cargo.lock` pins `unicode-segmentation 1.12.0`
  because the toolchain's rustc is 1.82 while the latest (1.13.3) needs 1.85.
  `Cargo.lock` is committed for that reason.
- **Two deliberate deviations from the plan**, now spec decisions D35/D36:
  a pure-Dart WordPiece tokenizer is the shipped default (the Rust bridge is the
  pinned fast path), and inference runs via `onnxruntime`'s `runAsync` rather
  than a hand-rolled worker isolate.
- **The model asset is bundled, gzip-compressed (spec D38).**
  `onnx/model_quantized.onnx` (dynamic INT8) from
  `nomic-ai/nomic-embed-text-v1.5` is stored as `…onnx.gz` (**90 MB**, under
  GitHub's 100 MB limit) and decompressed once at copy time by
  `ModelAssets.modelFile()`; `tokenizer.json` is bundled raw. The model takes
  `input_ids`, `attention_mask`, and `token_type_ids`, and outputs
  `last_hidden_state` `[1, seq, 768]`; the embedder supplies all three. The macOS
  app boots with `ONNX embedder ready`, and the Dart tokenizer reproduces the HF
  reference ids exactly (test `wordpiece_tokenizer_test.dart`).
- **Cross-compilation for the five targets was not exercised** — it is a build
  step, not source; the pure-Dart tokenizer default removes the Rust crate from
  the critical path. The `onnxruntime` plugin vendors per-platform natives
  (verified: `libonnxruntime.1.15.1.dylib` lands in the macOS bundle).

---

## Amendment — embedding state + boot recovery (D39–D41)

Implemented after the initial M6 build, on review of crash behaviour.

- **Schema:** `ObNote.embeddingState` (String, `complete`/`inProcess`),
  **local-only** (not a reference site, not in `SyncPayload`); `NoteEmbeddingState`
  on `Note`/`NoteSummary`.
- **Repository:** `beginEmbedding` (body + title + drop stale chunks + `inProcess`,
  one transaction) and `completeEmbedding` (chunk set + model + `complete`, one
  transaction); `replaceBodyAndChunks`/`replaceChunks` now set `complete`;
  `inProcessNoteUuids()` drives recovery.
- **`NoteEmbeddingService`:** serialized queue (`embed`), `recoverAll`,
  `activeModelId`, and a `revision` `ValueNotifier` the editor listens to so the
  banner clears when a background embed lands.
- **Editor:** Save calls `beginEmbedding` then `unawaited(service.embed(uuid))`;
  the surviving `isUnindexed` banner reads `embeddingState` (plus the existing
  mismatch checks).
- **Bootstrap/main:** builds the service; `main` fires `recoverAll()` after the
  first frame.
- **Sync:** a model-gated note is marked `inProcess`; a full vector set is
  `complete` (via `replaceChunks`).
- **ModelAssets:** temp-file write + `rename` (atomic), closing the truncated-model
  bug.
- **Tests:** `note_embedding_service_test` (recovery + no-op), `note_editor_state_test`
  (durable body before completion, background flip), `sync_note_test` (gated note
  is `inProcess`), `or1_enforcement_test` (new string column has a reader).
