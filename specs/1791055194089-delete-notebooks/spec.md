# Feature: Delete Notebooks

**Spec directory:** `1791055194089-delete-notebooks`
**Feature name:** `delete-notebooks`
**Builds on:** [`1790958509972-publication-data-layer`](../1790958509972-publication-data-layer/) (schema, transactions, cascade), [`1790968315311-peer-sync`](../1790968315311-peer-sync/) (tombstones, versions, delete records, ingest), and [`1790815734133-add-menu`](../1790815734133-add-menu/) (shell, notebook list).
**Amends:** data-layer FR12/AC13 (the "a notebook delete never deletes publications" clause) and peer-sync FR17 (the receive-side cascade) — see [Amendments to prior specs](#amendments-to-prior-specs).

## Context

Notebooks can be created and opened but never removed. The shell spec
(`add-menu`) put deletion explicitly out of scope and constrained the list row to
"tolerate these hit targets later"; the data-layer spec specified a delete
*cascade* but deliberately made a notebook delete association-only, so that a
publication shared between notebooks could never be destroyed from one of them.

Since then the sync infrastructure has landed: every syncable entity carries a
`@Unique()` uuid and a `(counter, deviceId)` version, `ObNotebook.versionCounter`
exists, `ObTombstone` records a dead uuid with the version it died at, deletes
travel as `DeleteDto { uuid, version }`, the delta is selected per record and per
axis, and the receive path already runs a full publication cascade. There is no
publication-delete path that a user can reach, and no notebook-delete path at
all.

This spec adds the missing capability. The decision that shapes all of it is the
cascade scope: **deleting a notebook deletes the notebook and every publication
that exists only inside it, and keeps every publication that is also attached to
another notebook.** A publication a user can still reach from a surviving
notebook is not data the user asked to lose.

That decision is a genuine revision of the data-layer spec. It is recorded as
such rather than implemented quietly, because the data layer's AC13 currently
asserts the opposite for exactly this case.

## Goals

- Let the user delete a notebook from the navigation panel.
- Delete the notebook and every **exclusive** publication (with its document and
  chunks), atomically.
- Keep every **shared** publication and its other associations intact.
- Record the notebook deletion and each cascaded deletion as versioned
  tombstones, so the deletion survives a stale push and propagates to peers.
- Apply a notebook delete on a peer and converge to the same state.
- Surface the consequence before the user commits, since the operation is
  permanent.
- Preserve every existing invariant: atomic cascades, never-over-delete for
  shared data, no resurrection, no sync vocabulary in the domain layer.

## Non-Goals

- **No trash, no undo, no soft delete.** A deleted notebook does not come back.
  Whether a recovery surface should exist is an Open Question.
- **No bulk or multi-select delete.** One notebook at a time.
- **No notebook rename or reorder.** Still deferred.
- **No change to publication deletion.** Deleting a single publication is
  unchanged and out of this spec's UI scope.
- **No new transport, pairing, or protocol.** Deletes travel over the existing
  `DeleteDto`; no transport exists and none is added here.
- **No entity-type column on the tombstone.** peer-sync FR15 stands.
- **No server-side or background sweep.** Deletion is user-initiated, matching
  peer-sync D4.

## Definitions

- **Exclusive publication** — a publication whose *only* notebook association is
  the notebook being deleted. Deleting the notebook leaves it unreachable, so it
  is deleted with the notebook.
- **Shared publication** — a publication attached to two or more notebooks. It
  survives a delete of any one of them and keeps its remaining associations.
- **Notebook cascade** — the local delete operation: the notebook row, every
  exclusive publication and its children, and a tombstone per deleted uuid, all
  in one transaction.
- **Death version** — the `(counter, deviceId)` stored on a tombstone. It is
  `nextVersion(current, deviceId)`, the same rule the publication delete path
  already uses.
- **Delete record** — the `DeleteDto { uuid, version }` that travels; it names
  nothing about the object's type (peer-sync FR13, FR15).

---

## Requirements

### Cascade semantics

- **FR1 — A notebook delete deletes the notebook and its exclusive
  publications.** On the device whose user performs the delete, for every
  publication associated with the notebook: if it has no other notebook
  association, delete it (publication, document, chunks) together with the
  notebook; if it has another association, keep the publication and remove only
  the edge to the deleted notebook.

- **FR2 — Exclusivity is resolved at delete time, from the deleting device's own
  edges.** A publication is exclusive exactly when the notebook being deleted is
  its only association. The decision is not cached, not stored on the
  publication, and not carried in the payload.

- **FR3 — Shared publications are never over-deleted on the deleting device.**
  After the cascade, a shared publication still exists, its remaining notebook
  associations are intact, its chunks remain searchable from those notebooks,
  and its document text is unread. This preserves the data-layer spec's
  never-over-delete rule for the shared case (AC13 there, minus the exclusive
  case this spec revises).

- **FR4 — The cascade is one transaction.** The notebook row, every exclusive
  publication, its document row, its chunks, and every tombstone are written in a
  single `runInTransaction(TxMode.write, …)`. A failure at any point leaves the
  notebook, its publications, its chunks, its documents, and the tombstone store
  exactly as they were. A partially deleted notebook is never observable.

- **FR5 — Every deleted uuid is tombstoned, in that same transaction.** The
  notebook uuid and each cascaded publication uuid get an `ObTombstone` whose
  `versionCounter` is the death version. Written in the delete transaction for
  the same reason peer-sync FR17 gives: after a commit it can be lost, before it
  a rollback leaves a live object nothing can update.

- **FR6 — The deletion travels as an ordinary delete record.** The notebook
  tombstone is selected into a delta like any other dead record and emitted as a
  `DeleteDto { uuid, version }`; each cascaded publication tombstone is emitted
  the same way. Tombstones are never part of a payload (peer-sync FR13), and no
  field identifies the dead object's type (peer-sync FR15).

- **FR7 — The receiver resolves a delete uuid against the notebook and
  publication boxes.** A delete record carries no type, so the receive path must
  look up the uuid in both. If it names a notebook, the notebook row and its
  edges are removed and the uuid is tombstoned; its exclusive publications are
  removed by their own delete records in the same payload, not re-derived on the
  receiver (see D2). If it names a publication, today's full publication cascade
  runs. If it names neither, the delete is a no-op that still tombstones the
  uuid (peer-sync FR12, AC9).

- **FR8 — A publication edge naming a dead notebook is dropped, not
  resurrected.** The ingest path creates a notebook row for any unknown uuid in
  a publication's edge list. That would resurrect a tombstoned notebook as an
  untitled row and falsify FR14 for notebook uuids. A notebook uuid with a
  tombstone must never be created by an edge list, and an edge to it must be
  omitted rather than materialised. A later notebook record for that uuid is
  refused by the same tombstone rule as any other upload.

- **FR9 — peer-sync FR14 applies verbatim to notebook uuids.** A tombstoned
  notebook uuid refuses a subsequent `NotebookDto` carrying a *strictly higher*
  version. A cascaded publication uuid refuses a subsequent publication upsert
  the same way. There is no version comparison in the dead branch for either.

- **FR10 — Delta selection is unchanged.** A notebook tombstone and a cascaded
  publication tombstone are selected by the existing per-record, per-axis
  watermark, exactly like a publication delete today. No new watermark axis and
  no new payload field is introduced.

- **FR11 — There is one notebook-delete entry point, and it always tombstones.**
  No caller can delete a notebook without writing its tombstone and the
  tombstones of its cascaded publications in the same transaction. The physical
  cascade and the tombstone write are not separable by any public path.

- **FR12 — Deletion is permanent.** No soft-delete flag, no trash table, no undo
  record is written. The tombstones exist to prevent resurrection, not to enable
  recovery.

### UI

- **FR13 — One delete control, on the notebook page.** The notebook detail
  page's header — the row that renders the notebook title — carries a single
  trash-can `IconButton` immediately beside the title. There is no delete
  affordance in the navigation panel, on list rows, or in the rail. The control
  is reachable by pointer and by keyboard and carries an accessible label.

- **FR14 — A confirmation modal gates the delete.** Activating the icon opens a
  modal confirmation naming the notebook and stating that the deletion is
  permanent and that sources used only by this notebook are deleted with it
  (sources also attached to another notebook are kept). Confirming performs the
  delete; dismissing the modal — Cancel, the scrim, `Escape`, or the platform
  back affordance — ignores the request and changes nothing. The confirm action
  is visually destructive and Cancel is the default.

- **FR15 — Post-delete navigation is safe.** Confirming deletes the notebook and
  returns to the notebook list. A route naming a deleted notebook redirects to
  the list; this already holds via `exists` and must remain true regardless of
  the order in which the list refresh and the route change happen.

- **FR16 — The last delete leaves a usable empty state.** Deleting the final
  notebook renders the existing empty-state message, and Add Notebook continues
  to work.

- **FR17 — Accessibility.** The trash-can control is keyboard reachable and
  carries an accessible label; the confirmation modal is keyboard-operable,
  focuses a control on open, and does not trap focus.

### Non-Functional Requirements

- **NFR1 — The domain layer stays sync-free.** No type under `lib/models/`
  learns about deletion-in-sync, tombstones, or versions (peer-sync NFR2). The UI
  reaches the delete through an injected callback and does not import
  `lib/data/sync/`.

- **NFR2 — Convergence is testable in-process.** Two in-memory stores exercise
  the delete and its propagation with no network, emulator, or fixtures
  (peer-sync NFR4).

- **NFR3 — The bounded-window premise is inherited unchanged.** This design is
  correct for short, coordinated, direct transfers between live devices. The
  authoritative-exclusivity decision in D2 leans on that premise and is where it
  would first break (peer-sync NFR3).

- **NFR4 — No resurrection.** A tombstoned notebook or cascaded publication
  cannot be brought back by any later upsert, from any device, for the tombstone
  retention window.

- **NFR5 — No silent partial delete.** A failed cascade throws and rolls back;
  it never leaves a notebook without some of its exclusive publications, or a
  publication without its chunks.

- **NFR6 — The protocol surface does not grow.** No new DTO, no new payload
  field, no new tombstone column, no change to the `embeddingModelId` gate.

- **NFR7 — Tombstone retention is unchanged.** The one-year boot purge
  (peer-sync FR16) applies to notebook tombstones exactly as to publication ones.

---

## Acceptance Criteria

- [x] **AC1:** Deleting a notebook removes the notebook row; it no longer appears
  in the list; `exists(uuid)` is false.
- [x] **AC2:** Every exclusive publication of the deleted notebook is removed
  with its document row and its chunks. After the delete, no chunk, document, or
  publication row remains that is not reachable from a live notebook.
- [x] **AC3:** A publication shared between the deleted notebook and a surviving
  one still exists, is still attached to the surviving notebook, and is still
  returned by scoped search from it. A test asserts the search result, not merely
  survival.
- [x] **AC4:** The notebook and every cascaded publication have a tombstone
  whose version is strictly greater than the last version pushed to a peer for
  that uuid.
- [x] **AC5:** A fault injected after the notebook row is removed and before the
  transaction commits leaves the notebook, every publication, every document,
  every chunk, and the tombstone store exactly as they were (FR4, NFR5).
- [x] **AC6:** The notebook deletion travels as a `DeleteDto`; the payload
  contains no tombstone and no entity-type field (peer-sync FR13, FR15).
- [x] **AC7:** An encoded-then-decoded push carries a notebook delete and each
  cascaded publication delete, and re-ingesting it is idempotent (AC8).
- [x] **AC8:** Two stores exchange pushes after `A` deletes a notebook with one
  exclusive and one shared publication, and converge to byte-identical logical
  state: notebook gone, exclusive publication and its chunks gone, shared
  publication alive with its surviving edge.
- [x] **AC9:** A delete for a notebook the receiver never had is a no-op that
  still writes the tombstone and applies without error.
- [x] **AC10:** A tombstoned notebook uuid refuses a later `NotebookDto` with a
  higher version. Falsification: making `isDead` respect version ordering must
  fail this test.
- [x] **AC11:** A publication upsert whose `notebookUuids` names a tombstoned
  notebook neither creates the notebook row nor attaches an edge to it; the
  publication's other edges are applied.
- [x] **AC12:** A cascaded publication uuid refuses a later publication upsert
  carrying a higher version (the FR9 extension of AC10).
- [x] **AC13:** The open notebook's page header shows exactly one trash-can
  control beside the title, reachable by keyboard and pointer; the navigation
  panel and rail expose no delete affordance; activating the control opens a
  confirmation modal naming the notebook; dismissing it leaves the store
  unchanged.
- [x] **AC14:** The confirmation names the notebook and states the deletion is
  permanent; confirming performs the delete described by AC2/AC3, and cancelling
  performs no write and no tombstone.
- [x] **AC15:** Confirming deletes the notebook and returns to the notebook list;
  a deep link to the deleted notebook redirects to the list.
- [x] **AC16:** Deleting the last notebook renders the empty state, and Add
  Notebook still creates and opens a notebook.
- [x] **AC17:** The trash-can control and the confirmation are operable by
  keyboard, and the confirmation does not trap focus and is dismissed by
  `Escape`.
- [x] **AC18:** No `lib/models/` type references a sync concept, verified by the
  existing import test; no UI file under `lib/shell/` or `lib/pages/` imports
  `lib/data/sync/`.
- [x] **AC19:** Every test runs against in-memory stores in a plain `flutter
  test` on the host; no network, emulator, or fixture file is used.
- [x] **AC20:** The one-year boot purge removes old notebook tombstones exactly as
  it removes old publication tombstones.

---

## Resolved Decisions

| # | Question | Resolution | Why |
|---|---|---|---|
| **D1** | Does deleting a notebook delete its publications? | **Exclusive publications only.** | A publication the user can still reach from a surviving notebook is not what "delete this notebook" means. A blanket cascade would destroy data another notebook depends on; keeping everything would leave unreachable orphans the user cannot clear. |
| **D2** | Is exclusivity decided on the deleting device or re-derived on each peer? | **On the deleting device; the resulting delete records are authoritative and propagated.** | The receiver sees only `{uuid, version}` and cannot distinguish a publication delete that resulted from a cascade from one the user made directly. Re-deriving on the receiver fails under divergence: if a peer held an extra edge, it would keep the publication while the sender's unconditional tombstone (FR14) keeps it deleted there — a *permanent* divergence with no healing path. Propagating the deletes converges in every case. |
| **D3** | What is the cost of D2? | **Under a divergent edge set a peer can over-delete a publication the deleting device believed was exclusive.** | Accepted, and the same class of loss as peer-sync D3 (a concurrent edit loses one side). Under NFR3 the edge sets are converged at delete time, so the case does not arise in the supported topology; it is recorded rather than hidden. |
| **D4** | Do cascaded publication tombstones travel? | **Yes, as ordinary delete records.** | They must exist locally to block resurrection (NFR4); once they exist the existing per-record watermark selects them. Suppressing them would need either a new tombstone flag or receiver-side re-derivation, and the latter is unsound per D2. |
| **D5** | Does the tombstone gain an entity type? | **No.** peer-sync FR15 stands. | The uuid is globally unique, so the receiver can resolve it against both boxes. Adding a type column is exactly the change FR15 forbids. |
| **D6** | Is a shared publication's version bumped when the notebook's edge is removed? | **No.** | The notebook delete record is what tells every device to remove the notebook and its edges; a second version bump would ship a redundant metadata record and add a write to the delete transaction for nothing. |
| **D7** | Is a confirmation modal required? | **Yes, naming the notebook and the permanence.** | The operation is permanent and can delete more than the notebook. A modal is the minimum that makes "you are about to lose these" visible before committing (peer-sync NFR5). |
| **D8** | Where is the delete affordance? | **A single trash-can icon in the notebook page header, beside the title.** | The act is scoped to the open notebook, so the page that shows the notebook is where it belongs. It also keeps the navigation panel and rail free of row-level controls, preserving their existing shape and keyboard traversal order. |
| **D9** | What happens to the open notebook on delete? | **Return to the notebook list.** | The route would redirect anyway (peer-sync-era `redirect`), but navigating explicitly avoids a frame of a deleted notebook and is the behaviour the user expects. |
| **D10** | Trash or permanent? | **Permanent.** | No recovery surface is specified. A tombstone is an anti-resurrection record, not a trash row, and nothing in this spec turns one into the other. Recovery is an Open Question. |

---

## Open Questions

- **Undo / recovery.** Whether a deleted notebook should be recoverable, and if
  so for how long and by what surface. This spec deletes permanently; a later
  spec may revisit, but it is a product decision, not a data decision.
- **Bulk delete.** Multi-select delete in the panel. The cascade is per notebook
  and would repeat; the UI question is whether it is worth it.
- **Divergence visibility.** D3 accepts that a divergent peer may over-delete.
  Whether the app should surface "a source was deleted on another device" is
  undecided, and would extend peer-sync NFR5's conflict visibility.
- **An open detail page with unsaved state.** The notebook detail body is a
  placeholder today. When it holds live editing state, deleting the notebook
  while it is open needs a teardown story; none exists yet.
- **Public API for a caller that wants to delete without sync.** This spec makes
  the only notebook-delete path the sync-aware one (FR11). If a purely local
  build ever needs to delete a notebook (e.g. tests, a future import tool), the
  seam for that is undecided.

---

## Amendments to prior specs

This feature deliberately changes two existing requirements. Per the
root-cause rule in `AGENTS.md`, they are stated here rather than absorbed
silently in code.

### data-layer FR12 and AC13

**Was:** "Deleting a `Notebook` removes the association and **never** deletes
publications or chunks, because those may be attached to other notebooks."
AC13 asserted that an exclusive publication survives its only notebook.

**Now:** Shared publications still survive and stay searchable (unchanged).
Exclusive publications — those with no other notebook — are deleted with the
notebook, by D1. AC13's exclusive-publication test
(`test/library_repository_test.dart`, "an exclusive publication survives its only
notebook") must be revised to assert deletion, and a shared-publication test
retained to assert survival.

### peer-sync FR12, FR14, FR17

**FR12/FR14** are extended from publication uuids to notebook uuids: a notebook
delete is a tombstone, and a tombstone beats any live notebook record.

**FR17** ("the receive-side delete runs the full local cascade") is extended: the
receive-side notebook delete removes the notebook row and its edges, while its
cascaded publications arrive as their own delete records and run today's
publication cascade. The receiver does not re-derive exclusivity (D2).

### Documentation to follow (implementation phase)

- `docs/sync-conventions.md` — the **Deletes** section and **Notebooks are
  records, not just references** section describe the cascade as
  publication-only; both need the notebook-root case.
- `docs/data-conventions.md` — the delete-cascade description, if it states the
  association-only rule.
- The generated ObjectBox model is unchanged: no entity, property, or index is
  added by this spec.
