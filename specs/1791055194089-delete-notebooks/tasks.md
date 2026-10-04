# Tasks: Delete Notebooks

## Prerequisites

- [`spec.md`](./spec.md) — requirements, acceptance criteria, resolved decisions, prior-spec amendments.
- [`plan.md`](./plan.md) — architecture (I1–I9) and milestones (M1–M6).
- The peer-sync and publication-data-layer work must be present: `ObTombstone`/
  `TombstoneStore`, `(counter, deviceId)` versions, `DeleteDto`,
  `ObPeerWatermark`, `SyncApplier`, `PushSender`, and
  `ObjectBoxLibraryRepository`.
- `make install_objectbox` has been run once on the machine — ObjectBox's native
  library is required for the Dart VM running `flutter test` (the existing suite
  already needs it).
- Verify with `make analyze` and `make test`. **Do not run `make codegen`:** this
  feature adds no entity, property, or index, so `lib/objectbox.g.dart` and
  `lib/objectbox-model.json` must not change (plan I8).

Task order follows the dependency direction: data cascade (T1–T2) → local sync
delete (T3–T4) → receive and guard (T5–T7) → payload/convergence (T8) → UI
(T9–T12) → docs and gate (T13–T14). Write the test named in each task before the
code it guards.

## Task List

### T1: Data layer — one publication cascade, and the exclusive notebook cascade
- **Files:** `lib/data/library_repository.dart`, `lib/data/objectbox_library_repository.dart`
- **Effort:** Medium
- **Depends on:** —
- **Steps:**
    1. Extract a private `_cascadePublication(ObPublication)` in
       `ObjectBoxLibraryRepository` from the current body of `deletePublication`
       (`lib/data/objectbox_library_repository.dart:134`): remove chunks by
       `publicationId`, remove document rows by `publicationId`, then remove the
       publication row. Have `deletePublication` resolve the entity via
       `_requirePublication` and call it. There must be exactly one place that
       removes a publication's children.
    2. Add an immutable `CascadedPublication { final String uuid; final int
       versionCounter; }` to `lib/data/library_repository.dart`. It carries only
       row data — no sync type.
    3. Change `LibraryRepository.deleteNotebook` from `void` to
       `List<CascadedPublication>` and revise its doc comment: it now deletes the
       notebook **and every exclusive publication**, never a shared one
       (amends data-layer FR12; see [`spec.md`](./spec.md#amendments-to-prior-specs)).
    4. Implement `deleteNotebook`: `_requireNotebook`; in one
       `runInTransaction(TxMode.write, …)`, copy `notebook.publications` to a
       local list (cascading mutates the relation), and for each publication
       whose `notebooks.length <= 1` record `CascadedPublication(pub.uuid,
       pub.versionCounter)` **then** `_cascadePublication(pub)`; finally
       `_notebooks.remove(notebook.id)`. Return the recorded list.
    5. Keep both methods synchronous (the router guard depends on it) and leave
       `attach`/`detach`/`replaceChunks` untouched.

### T2: Data-layer tests — exclusive cascade, shared survival, amended AC13
- **Files:** `test/library_repository_test.dart`
- **Effort:** Medium
- **Depends on:** T1
- **Steps:**
    1. Revise the `AC13 — deleting a notebook never over-deletes` group. The
       exclusive-publication test ("an exclusive publication survives its only
       notebook") now asserts the opposite: the publication, its document row,
       and its chunks are gone, and scoped search returns empty.
    2. Keep the shared-publication test intact: the publication survives, its
       remaining edge is `[keep]`, `listForNotebook(keep)` returns it, and
       scoped search from `keep` still returns its chunks. This is the FR3/AC3
       assertion and it must stay.
    3. Add: a notebook with no publications deletes cleanly and returns an empty
       list.
    4. Add: `deleteNotebook` returns the cascaded `(uuid, versionCounter)` pairs,
       and each counter equals the value the publication held before delete.
    5. Keep the "unknown identifiers" case: `deleteNotebook('nope')` throws
       `StateError` at the data layer.

### T3: Sync — `SyncDeleter` with `deleteNotebookLocally`
- **Files:** `lib/data/sync/sync_deleter.dart` (new), `lib/data/sync/sync_apply.dart`
- **Effort:** Medium
- **Depends on:** T1
- **Steps:**
    1. Create `SyncDeleter` with the same dependency shape as `SyncApplier`:
       `Store`, `String? deviceId` (default `resolveDeviceId(store)`),
       `TombstoneStore? tombstones`, and an `ObjectBoxLibraryRepository`. It
       needs **no** `activeEmbeddingModelId`.
    2. Move the local publication delete out of `SyncApplier.deleteLocally`
       (`lib/data/sync/sync_apply.dart:336`) into
       `SyncDeleter.deletePublicationLocally`: resolve the publication for its
       counter, `nextVersion(local, deviceId)`, then one transaction with the
       cascade and `markDead`.
    3. Implement `deleteNotebookLocally(uuid)`:
       - Resolve the notebook. If absent, `markDead(uuid)` inside its own
         transaction and return — a repeated or unknown local delete is
         idempotent and does not throw (peer-sync FR12).
       - Otherwise compute the notebook death version, open the write
         transaction, call `_library.deleteNotebook(uuid)` (its inner
         transaction joins this one), then `markDead` the notebook and each
         returned `CascadedPublication` at `nextVersion(counter, deviceId)`.
       - Read every counter **before** the rows are removed. Keep the whole
         operation in the one transaction (plan I4, I5).
    4. Add an optional test-only `void Function()? faultHook` invoked after the
       data-layer cascade and before the tombstones, so T4 can inject a failure
       that must roll the whole thing back.
    5. Have `SyncApplier.deleteLocally` delegate to the `SyncDeleter` (or remove
       it and update its callers) so there is one local delete implementation.

### T4: Sync tests — versions, atomicity, idempotency of the local delete
- **Files:** `test/sync_delete_notebook_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T3
- **Steps:**
    1. Build the in-memory harness (see `test/sync_push_test.dart` and
       `test/sync_test_fixtures.dart`). Create a notebook with one exclusive
       publication (document + chunks) and one shared publication attached to a
       second notebook.
    2. Assert the notebook and exclusive publication have tombstones; the shared
       publication does not.
    3. Assert AC4: each tombstone's `versionCounter` is strictly greater than the
       version last pushed to a peer for that uuid. A concrete check: push once,
       delete, then `PushSender.selectDelta` must include both delete records.
    4. Assert AC5/NFR5: install the T3 fault hook to throw after the cascade;
       assert the notebook, exclusive publication, document rows, chunks, and the
       tombstone store are all unchanged.
    5. Delete twice: the second call neither throws nor changes state.

### T5: Sync receive — `_applyDelete` branches on the dead uuid
- **Files:** `lib/data/sync/sync_apply.dart`
- **Effort:** Small–Medium
- **Depends on:** T3
- **Steps:**
    1. In `_applyDelete` (`lib/data/sync/sync_apply.dart:352`), resolve the uuid
       against `_findNotebook` first, then `_findPublication` (uuids are globally
       unique).
    2. Notebook branch: one transaction removing the notebook row (its `ToMany`
       edges vanish with it) and `markDead(delete.uuid, versionCounter:
       delete.version.counter)`.
    3. Publication branch: keep today's `_cascade(publication)` (null-safe) plus
       the same `markDead`.
    4. Do **not** re-derive exclusivity on the receiver. Cascaded publications
       arrive as their own `DeleteDto`s and take the publication branch (plan I6,
       spec D2).
    5. Leave `selectDelta` untouched — it already emits a delete per moved
       tombstone.

### T6: Ingest guard — a dead notebook is never created by an edge list
- **Files:** `lib/data/sync/sync_apply.dart`
- **Effort:** Small
- **Depends on:** T5
- **Steps:**
    1. In `_applyPublication`, before `_syncNotebookEdges` (`sync_apply.dart:283`),
       filter `dto.notebookUuids` to those where `!_tombstones.isDead(u)`.
    2. Confirm `ingest` still applies deletes before publications, so a notebook
       delete in the same payload is visible to the filter.
    3. Do not touch `_planNotebook`'s existing tombstone refusal (it is the other
       half of FR14 for notebooks).

### T7: Sync tests — receive branching, dead-edge guard, anti-resurrection, falsification
- **Files:** `test/sync_delete_notebook_test.dart`, `test/sync_apply_test.dart`
- **Effort:** Medium
- **Depends on:** T5, T6
- **Steps:**
    1. Ingest a notebook `DeleteDto` for a notebook that exists → removed and
       tombstoned; for one that does not exist → no-op but still tombstoned
       (AC9). Ingest a publication `DeleteDto` → cascade as before.
    2. **AC10 + falsification:** a tombstoned notebook uuid refuses a later
       `NotebookDto` with a strictly higher version. Then temporarily make
       `isDead` respect version ordering ("apply unless newer"), confirm the test
       fails, and revert.
    3. **AC11:** a publication upsert whose `notebookUuids` includes a tombstoned
       notebook neither creates the notebook row nor keeps that edge; the
       publication's other edges are applied.
    4. **AC12:** a cascaded publication's tombstone refuses a later publication
       upsert with a higher version.
    5. Re-ingesting the same payload changes nothing (idempotency; fully covered
       in T8 but assert it here at unit level too).

### T8: Payload and convergence
- **Files:** `test/sync_push_test.dart`, `test/sync_convergence_test.dart`, `test/sync_tombstone_test.dart`
- **Effort:** Medium
- **Depends on:** T5
- **Steps:**
    1. Assert `selectDelta` emits a `DeleteDto` for the notebook tombstone and for
       each cascaded publication tombstone, and that the encoded payload contains
       no tombstone field and no entity-type field (AC6). Confirm `push_sender.dart`
       needed no code change.
    2. Extend `sync_convergence_test.dart`: store A deletes a notebook holding one
       exclusive and one shared publication; push A→B; assert B's notebook is
       gone, the exclusive publication and its chunks are gone, the shared
       publication survives with its surviving edge and is searchable; assert A
       and B are logically identical (AC8). Push B→A and assert nothing changes.
    3. Purge: a notebook tombstone older than one year is removed by the boot
       sweep exactly like a publication tombstone (AC20).
    4. Re-ingest the same encoded payload and assert no state change (AC7).

### T9: UI data — `NotebookRepository.delete`
- **Files:** `lib/data/notebook_repository.dart`, `lib/data/objectbox_notebook_repository.dart`
- **Effort:** Medium
- **Depends on:** T3
- **Steps:**
    1. Add `void delete(String id)` to the `NotebookRepository` interface. The
       interface stays sync-free — a `String` in, nothing out (plan I2).
    2. `InMemoryNotebookRepository.delete` removes the matching notebook (used by
       shell tests that substitute the repository).
    3. `ObjectBoxNotebookRepository` constructs a `SyncDeleter` over its `_store`
       (same overridable pattern as `SyncApplier`) and its `delete` delegates to
       `deleteNotebookLocally`. This is the single notebook-delete entry point
       (spec FR11).
    4. Keep it synchronous; `bootstrap.dart` needs no new wiring beyond the
       constructor's default.

### T10: UI state — `NotebooksState.delete` and the hook
- **Files:** `lib/state/notebooks_state.dart`, `lib/state/use_notebooks_state.dart`
- **Effort:** Small
- **Depends on:** T9
- **Steps:**
    1. Add `final void Function(String id) delete;` to `NotebooksState` and its
       constructor.
    2. In `useNotebooksState`, define `delete(id)` as `repo.delete(id)` followed
       by `notebooks.value = repo.list()`, and pass it into the returned state.
    3. No change to `app.dart`: the hook already receives `repo`.

### T11: UI — trash-can control, confirmation modal, navigation
- **Files:** `lib/pages/notebook_detail_page.dart`
- **Effort:** Medium
- **Depends on:** T10
- **Steps:**
    1. Turn the header (`notebook_detail_page.dart:49`) into a `Row`: the title
       `Text` wrapped in `Expanded`, then an `IconButton` with
       `Icons.delete_outline`, a `tooltip`, and the tooltip text as its semantic
       label. This is the only delete affordance in the app.
    2. `onPressed` shows `showDialog<bool>` with an `AlertDialog`: it names the
       notebook and states the deletion is permanent, that sources used only by
       this notebook are deleted, and that shared sources are kept. Actions are
       Cancel (default) and a destructive-styled confirm; the dialog's `Escape`/
       scrim/back dismiss returns `false`.
    3. On `true`, call `notebooks.delete(notebookId)`; then leave the page
       (`context.canPop() ? context.pop() : context.go('/')`), guarding the
       post-`await` use of `context` with `context.mounted`.
    4. Do not touch `NavDestinationTile` or `NavPanelListLevel` — no panel or
       rail affordance (spec FR13, D8).

### T12: UI tests and import purity
- **Files:** `test/notebook_flow_test.dart`, `test/app_shell_widget_test.dart`, `test/domain_model_purity_test.dart` (or a new `test/ui_purity_test.dart`)
- **Effort:** Medium
- **Depends on:** T11
- **Steps:**
    1. AC13: the open notebook's page header shows exactly one delete control
       beside the title; the panel and rail show none.
    2. AC14: cancelling the dialog performs no write and writes no tombstone;
       confirming performs the AC2/AC3 delete.
    3. AC15: confirming removes the notebook, refreshes the list, returns to the
       list, and a route/`go` to the deleted notebook redirects to `/`.
    4. AC16: deleting the last notebook shows the empty state and Add Notebook
       still creates and opens one.
    5. AC17: the control is keyboard reachable; the dialog focuses a control,
       dismisses on `Escape`, and does not trap focus.
    6. AC18: add an import assertion that no file under `lib/shell/` or
       `lib/pages/` imports `lib/data/sync/`. Extend the `storage layer
       locality` group in `test/domain_model_purity_test.dart`, reusing its
       `importedPackages` helper.

### T13: Conventions docs
- **Files:** `docs/sync-conventions.md`, `docs/data-conventions.md`
- **Effort:** Small
- **Depends on:** T5, T9
- **Steps:**
    1. `docs/sync-conventions.md`: update **Deletes** and **Notebooks are
       records, not just references** to describe the notebook-root cascade, the
       authoritative deleting-device decision, and the dead-edge guard.
    2. `docs/data-conventions.md`: update the delete-cascade description to the
       exclusive-publication rule.
    3. Grep the docs for the association-only wording and confirm no page still
       states it; add a pointer to this spec's amendment section.

### T14: Acceptance gate and verification
- **Files:** `test/acceptance_gate_test.dart` (extend if it aggregates), `Makefile` (no change expected)
- **Effort:** Small
- **Depends on:** T1–T13
- **Steps:**
    1. Run `make analyze` and `make test`; both clean.
    2. Walk AC1–AC20 in [`spec.md`](./spec.md#acceptance-criteria) and map each
       to the test that asserts it; add any missing aggregate assertion where the
       repo keeps one (`test/acceptance_gate_test.dart`).
    3. Run both falsification tests (AC10's version-ordering change, AC11's edge
       filter removed) and confirm they fail; revert.
    4. Confirm `git status` shows no change to `lib/objectbox.g.dart` or
       `lib/objectbox-model.json` (no codegen needed; plan I8).

## Milestone → Task Map

| Plan milestone | Tasks |
|---|---|
| M1 — Data-layer cascade | T1, T2 |
| M2 — Local delete + tombstones | T3, T4 |
| M3 — Receiver branching and guard | T5, T6, T7 |
| M4 — Payload and convergence | T8 |
| M5 — UI | T9, T10, T11, T12 |
| M6 — Docs | T13 |
| Gate | T14 |
