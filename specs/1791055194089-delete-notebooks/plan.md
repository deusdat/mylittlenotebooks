# Plan: Delete Notebooks

## Approach

This feature adds no new protocol. Everything it needs already exists and is
proven: globally-unique uuids, `(counter, deviceId)` versions,
`ObTombstone` + `TombstoneStore`, `DeleteDto { uuid, version }`, per-record
per-axis watermarks, the receive-side delete transaction, and the data-layer
cascade. The work is three additions on top of that:

1. **The data layer learns one new cascade.** `deleteNotebook` stops being
   "remove the association" and becomes "remove the notebook and every
   publication that exists only inside it", reusing the publication cascade.
2. **The sync layer learns to tombstone a notebook and to receive one.** The
   local delete is a new `SyncDeleter.deleteNotebookLocally`; the receive path
   branches on the dead uuid's type; and ingest stops resurrecting a dead
   notebook through a publication's edge list.
3. **The UI gets one control and one confirmation.** A trash-can `IconButton` in
   the notebook page header, an `AlertDialog`, and a `delete` on
   `NotebookRepository` that the page calls.

The ordering is deliberate and follows the existing dependency direction:
data-layer cascade → sync delete/receive → ingest guard → UI → docs. Each
milestone is independently testable in-process, and every sync test runs against
two in-memory stores with no device (peer-sync NFR4).

**Tests come first within each milestone.** The falsification tests the spec
names (AC10's `isDead`-with-version test, AC11's dead-edge test, AC5's
fault-injection test) are the ones that keep the tombstone rule honest, and they
are written before the code they guard.

## Architecture & Design Decisions

### I1 — The cascade physics live in the data layer; tombstones live in sync

`ObjectBoxLibraryRepository` owns exactly one implementation of "remove a
publication and its children" (a private `_cascadePublication(ObPublication)`)
used by both `deletePublication` and the new `deleteNotebook`. It writes no
tombstone and knows nothing about versions beyond the `versionCounter` column it
already maintains. The sync layer does every tombstone and version write. This
preserves the existing split (`deletePublication` vs `deleteLocally`) and keeps
the sync seam in one place.

`deleteNotebook` has to report what it removed so the sync caller can tombstone
it. It returns the cascaded publications as `(uuid, versionCounter)` pairs,
captured **before** their rows are deleted. The data layer exposes no sync type:
a uuid and an int are just row data.

### I2 — One notebook-delete entry point

The only path that deletes a notebook is
`ObjectBoxNotebookRepository.delete(uuid)` → `SyncDeleter.deleteNotebookLocally(uuid)`.
`delete` is added to the `NotebookRepository` interface, so the UI's existing
dependency (`repo`) grows the capability with no new plumbing and no service
locator. `InMemoryNotebookRepository` implements `delete` for shell tests. This
satisfies spec FR11: there is no public path that removes a notebook without
writing its tombstone and its cascaded publications' tombstones in the same
transaction.

`ObjectBoxNotebookRepository` is a `lib/data/` class and may import
`lib/data/sync/`; the sync-free constraint is on `lib/models/` (peer-sync NFR2),
and the `NotebookRepository` *interface* carries only `void delete(String id)` —
no sync vocabulary. This is the same shape as `ObjectBoxLibraryRepository`
already writing a `versionCounter` without importing sync.

### I3 — Exclusivity is `publication.notebooks.length == 1`

Resolved inside the delete transaction, from the backlink already on
`ObPublication` (`@Backlink('publications')`). Iterating `notebook.publications`
is copied to a list first, because cascading a publication mutates that
relation. A publication with any other notebook association is left alone; the
notebook row's removal drops its edge to this notebook automatically.

### I4 — One transaction, nested

`SyncDeleter.deleteNotebookLocally` opens the write transaction, calls
`_library.deleteNotebook` (whose own `runInTransaction` joins the enclosing one),
then writes every tombstone, then commits. This is the mechanism
`_applyPublication` already relies on for `replaceChunks`, and the codebase has a
measured note on it in `docs/sync-conventions.md`. A throw anywhere rolls back the
notebook, its publications, its documents, its chunks, and the tombstones
together (spec FR4, NFR5).

### I5 — Death version is `nextVersion(localCounter, deviceId)`

The notebook tombstone uses the notebook's own counter; each cascaded publication
tombstone uses that publication's counter, both incremented once and stamped with
this device. That is exactly the rule the publication delete path already uses,
and it guarantees the delete outranks anything previously pushed for that uuid
(spec FR5, AC4). The counters are read before the rows are removed.

### I6 — The receiver branches on the dead uuid, and does **not** re-derive exclusivity

`_applyDelete` looks the uuid up in the notebook box first, then the publication
box. A notebook uuid removes the notebook row (its edges vanish with it) and
tombstones it; the cascaded publications arrive as their own `DeleteDto`s in the
same payload and run the existing publication cascade. The receiver never
computes exclusivity — that is the deleting device's decision and it is carried
in the delete records (spec D2). Re-deriving was rejected because the sender's
unconditional tombstone (FR14) would keep the publication dead on one side and
alive on the other, a permanent divergence.

`selectDelta` needs no change: it already walks `_tombstones.all()` and emits a
`DeleteDto` per moved tombstone, regardless of what the uuid names.

### I7 — A dead notebook is never created by a publication edge

`UuidScope.resolveNotebook` creates a row for any unknown uuid, which is correct
for a genuine new notebook and wrong for a tombstoned one. `_applyPublication`
filters `dto.notebookUuids` through `_tombstones.isDead` before calling
`_syncNotebookEdges`. `_planNotebook` already refuses a tombstoned notebook
record; this closes the other door into the same resurrection (spec FR8).

### I8 — No schema, no DTO, no codegen change

No entity, property, or index is added. `ObTombstone` keeps `(uuid, deletedAt,
versionCounter)` with no entity-type column (peer-sync FR15). `DeleteDto` is
unchanged. `objectbox.g.dart`/`objectbox-model.json` are untouched, so no
`make codegen` run is needed.

### I9 — UI shape

`notebook_detail_page.dart`'s header — today a `Padding` around a `Text(title)` —
becomes a `Row` with the title (`Expanded`) and a trailing `IconButton` with
`Icons.delete_outline` and a tooltip/semantic label. `onPressed` shows
`showDialog<bool>` (`AlertDialog`, destructive `TextButton` for confirm, Cancel
default). On `true`, it calls `notebooks.delete(notebookId)`, then leaves the
page (`context.pop()` when poppable, else `context.go('/')`). The page is a
`HookWidget` Coordinator, so this navigation is its job. No delete affordance is
added to `NavPanelListLevel` or `NavDestinationTile`, keeping the panel and rail
unchanged (spec FR13, D8).

### Changed / new files

| File | Change |
|---|---|
| `lib/data/library_repository.dart` | `deleteNotebook` returns cascaded `(uuid, versionCounter)`; docs revised. |
| `lib/data/objectbox_library_repository.dart` | extract `_cascadePublication`; exclusive cascade in `deleteNotebook`. |
| `lib/data/notebook_repository.dart` | add `void delete(String id)`; `InMemoryNotebookRepository` implements it. |
| `lib/data/objectbox_notebook_repository.dart` | `delete` delegates to a `SyncDeleter`. |
| `lib/data/sync/sync_deleter.dart` | **new** — `SyncDeleter` (local publication + notebook delete). |
| `lib/data/sync/sync_apply.dart` | `_applyDelete` branches; dead-notebook edge filter; delegate local delete. |
| `lib/state/notebooks_state.dart` | add `delete` to the state. |
| `lib/state/use_notebooks_state.dart` | wire `repo.delete` + list refresh. |
| `lib/pages/notebook_detail_page.dart` | trash-can control + confirmation + navigation. |
| `test/library_repository_test.dart` | revise AC13; exclusive-cascade tests. |
| `test/sync_delete_notebook_test.dart` | **new** — local delete, receive, guards. |
| `test/sync_convergence_test.dart` | notebook-delete convergence. |
| `test/notebook_flow_test.dart`, `test/nav_state_machine_test.dart` | UI delete + no-affordance assertions. |
| `docs/sync-conventions.md`, `docs/data-conventions.md` | notebook-root cascade. |

## Milestones

### M1 — Data-layer cascade (exclusive only)
**Delivers:** `LibraryRepository.deleteNotebook` deletes the notebook and every
exclusive publication (document + chunks) in one transaction; shared
publications survive. **Effort:** Medium.

1. Extract `_cascadePublication(ObPublication)` from `deletePublication`; call it
   from both paths so there is one cascade implementation (I1).
2. Rewrite `deleteNotebook` to resolve and cascade exclusive publications and
   return `List<(String uuid, int versionCounter)>`; remove the notebook row
   after, so its edges to shared publications disappear with it.
3. Update the `LibraryRepository` doc comment: the operation now over-deletes
   *exclusive* data and must say so (spec Amendment, data-layer FR12).
4. Revise `test/library_repository_test.dart` AC13: the exclusive-publication
   test now asserts deletion (publication, document rows, chunks all gone); the
   shared-publication test keeps asserting survival and searchability.
5. Add tests: exclusive cascade leaves no orphan chunk/document; shared
   publication's remaining edge intact; search from the surviving notebook still
   returns the shared chunks.

**Gate:** AC2, AC3 pass; the amended AC13 tests are the only intentional test
deletions in this feature.

### M2 — Local notebook delete: versions and tombstones
**Delivers:** `SyncDeleter.deleteNotebookLocally` writes the notebook and each
cascaded publication tombstone in the delete transaction, at
`nextVersion(local, deviceId)`. **Effort:** Medium.

1. Add `SyncDeleter` (`lib/data/sync/sync_deleter.dart`) depending only on
   `Store`, `ObjectBoxLibraryRepository`, `TombstoneStore`, and `deviceId`
   (defaulting like `SyncApplier`). Move the existing publication local delete
   into it as `deletePublicationLocally`, and have `SyncApplier.deleteLocally`
   delegate or be removed in favour of it.
2. Implement `deleteNotebookLocally`: resolve the notebook for its counter, open
   the transaction, call `_library.deleteNotebook` (nested, returns the cascaded
   pairs), tombstone the notebook and each cascaded publication, commit (I4, I5).
3. Make a repeated/absent delete idempotent: if the notebook is absent, tombstone
   the uuid and return without calling the data-layer method (no throw).
4. Tests: tombstone versions strictly exceed the last pushed version (AC4); a
   fault hook injected after the cascade rolls back notebook, publications,
   documents, chunks, and tombstones (AC5, NFR5); double-delete is a no-op.

**Gate:** AC4, AC5 pass.

### M3 — Receiver branching and the dead-edge guard
**Delivers:** A received notebook delete removes the notebook and is tombstoned;
a publication edge naming a dead notebook is dropped. **Effort:** Medium.

1. In `SyncApplier._applyDelete`, resolve the uuid against `_findNotebook` first,
   then `_findPublication`; run the matching cascade and tombstone the uuid in
   the same transaction (I6). Absent → tombstone only (AC9).
2. In `_applyPublication`, filter `dto.notebookUuids` through
   `_tombstones.isDead` before `_syncNotebookEdges` (I7). Leave `_planNotebook`'s
   existing tombstone check as the other half of FR14.
3. Tests: notebook uuid vs publication uuid both dispatch correctly; a notebook
   delete for an unknown uuid is a no-op + tombstone; a tombstoned notebook uuid
   rejects a higher-version `NotebookDto` — and the falsification test that adds
   a version comparison to `isDead` makes that test fail (AC10); a publication
   upsert naming a dead notebook neither creates it nor keeps the edge (AC11); a
   cascaded publication tombstone rejects a higher-version upsert (AC12).

**Gate:** AC9–AC12 pass, including both falsification tests.

### M4 — Payload and convergence
**Delivers:** The deletion pushes and re-applies idempotently; two stores
converge. **Effort:** Medium.

1. Confirm `selectDelta` emits the notebook delete and each cascaded publication
   delete with no code change; add a test that asserts their presence and that no
   tombstone or type field is in the encoded payload (AC6).
2. Extend `sync_convergence_test.dart`: store A deletes a notebook with one
   exclusive and one shared publication; push A→B; assert B's notebook is gone,
   the exclusive publication and its chunks are gone, the shared publication
   survives with its surviving edge and remains searchable; assert byte-identical
   logical state (AC8).
3. Re-ingest the same payload and assert no change (AC7); assert a notebook
   tombstone older than a year is purged like any other (AC20).

**Gate:** AC6–AC8, AC20 pass.

### M5 — UI: the delete control
**Delivers:** A trash-can button in the notebook page header, a confirmation
modal, and a working delete from the UI. **Effort:** Medium.

1. Add `void delete(String id)` to `NotebookRepository`; implement in
   `InMemoryNotebookRepository` (remove from the list) and in
   `ObjectBoxNotebookRepository` (delegate to a `SyncDeleter` it constructs over
   its store, I2).
2. Add `delete` to `NotebooksState`; in `useNotebooksState`, call `repo.delete`
   then reassign `notebooks.value = repo.list()`.
3. In `notebook_detail_page.dart`, turn the header into a `Row`: title
   (`Expanded`), delete `IconButton`. `onPressed` shows the confirmation dialog
   and, on confirm, calls `notebooks.delete(notebookId)` and leaves the page
   (I9). Guard the post-`await` context with `context.mounted`.
4. Tests: exactly one delete control in the page header and none in the panel or
   rail (AC13); cancel performs no write (AC14); confirm removes the notebook,
   refreshes the list, and returns to the list (AC15); the last delete renders
   the empty state and Add Notebook still works (AC16); keyboard operation and
   `Escape` (AC17). Extend `notebook_flow_test.dart` / `app_shell_widget_test.dart`.
5. Add an import assertion that no `lib/shell/` or `lib/pages/` file imports
   `lib/data/sync/` (AC18, extend the existing purity tests).

**Gate:** AC13–AC18 pass.

### M6 — Conventions docs
**Delivers:** The prose matches the code. **Effort:** Small.

1. `docs/sync-conventions.md`: update **Deletes** and **Notebooks are records,
   not just references** to describe the notebook-root cascade and the
   dead-edge guard.
2. `docs/data-conventions.md`: update the delete-cascade description for the
   exclusive-publication rule.
3. Point the amendment note in this spec's [Amendments] section at the revised
   paragraphs.

**Gate:** No doc states the association-only rule.

## Dependencies

- **peer-sync M1–M5** (implemented): uuid identity, versions, tombstone store,
  `DeleteDto`, per-record watermarks, receive-side cascade, notebook records.
- **data-layer** (implemented): `ObNotebook`, `ObPublication`, `ObDocument`,
  `ObChunk`, the `@Backlink('publications')` pairing, and transaction helpers.
- **ObjectBox native library** installed via `make install_objectbox` before
  `flutter test` (already required by the existing suite).
- **No embedding model is needed.** The delete path touches no vectors; only the
  ingest gate does, and it is untouched. `SyncDeleter` takes no
  `activeEmbeddingModelId`.

## Risks & Mitigations

| # | Risk | Mitigation |
|---|---|---|
| **R1** | Over-delete of a genuinely-shared publication under a divergent edge set (spec D3). | Accepted and bounded by the topology premise (NFR3). The converged case never over-deletes and is the one tested (M4). Recorded, not hidden. |
| **R2** | A tombstoned notebook is resurrected as an untitled row by `UuidScope.resolveNotebook` through a publication's edge list. | The dead-uuid filter in `_applyPublication` (I7) plus AC11, which fails if the filter is removed. |
| **R3** | The cascade and its tombstones land in different transactions, leaving a live-but-deleted or dead-but-present record. | One enclosing transaction with a nested data-layer call (I4), proven by a fault-injection test in M2 (AC5). |
| **R4** | `_applyDelete` misclassifies a uuid (looks up the wrong box), deleting nothing or the wrong thing. | Uuids are globally unique (peer-sync FR2); branch notebook-first then publication; test both paths and the absent case (M3). |
| **R5** | Adding a sync import to a data-layer class (`ObjectBoxNotebookRepository`) or to the UI. | The `NotebookRepository` interface stays sync-free; only the ObjectBox implementation imports `sync_deleter.dart`; the import test in M5 fails on a UI sync import. |
| **R6** | Leaving the second publication-cascade copy in `SyncApplier._cascade` while adding a third. | M1 extracts one `_cascadePublication`; M2 routes the local delete through `SyncDeleter`; the receive path calls the same data-layer method. A grep for the chunk-removal query should find one site. |
| **R7** | The UI wires the wrong dependency after the repository interface changes, breaking shell tests that substitute `InMemoryNotebookRepository`. | `InMemoryNotebookRepository` implements `delete`; the shell tests keep passing unmodified except where they assert on the new control (M5). |
| **R8** | A route to the just-deleted notebook lingers for a frame or redirects mid-frame. | Navigate explicitly after the delete and keep the existing `redirect` guard; tested by the deep-link case (AC15). |

## Verification

`make analyze` and `make test` after every milestone. `make codegen` is **not**
run: no entity changes (I8). The acceptance gate is the spec's AC1–AC20; the two
falsification tests (AC10's version comparison, AC11's dead edge) are run with
the guard removed to confirm they fail, per the convention that a check which
cannot fail is not a check.
