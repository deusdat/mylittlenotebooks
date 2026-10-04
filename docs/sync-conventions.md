# Sync conventions

How peer sync is put together, and — more usefully — **where it goes wrong
silently**. Everything here governs `lib/data/sync/`. Read
[`data-conventions.md`](./data-conventions.md) first: this layer sits on that one
and inherits its transaction rule, its `@TargetIdProperty` rename, and its
`ToMany.removeWhere` trap.

Sync exists as payloads and stores only. There is no transport, no pairing, no
server, and no UI. Everything below is testable in-process against two in-memory
ObjectBox stores — no network, no emulator, no fixture files.

---

## The seven reference sites

**The first thing to know and the easiest thing to miss.** An incoming payload
names every record by uuid. Turning those into this device's int ids means
rewriting seven places, and ObjectBox stores a relation *twice* — once as a
denormalized int column, once as a relation row — so both must be written and
they must agree afterwards.

| # | Entity | Reference | Kind |
|---|---|---|---|
| 1 | `ObChunk` | `publicationId` | denormalized int column, indexed |
| 2 | `ObChunk` | `publication` | `ToOne` (`@TargetIdProperty('publicationRef')`) |
| 3 | `ObDocument` | `publicationId` | denormalized int column, indexed |
| 4 | `ObDocument` | `publication` | `ToOne` (`@TargetIdProperty('documentOwnerId')`) |
| 5 | `ObNotebook` | `publications` | `ToMany` (`@Backlink('publications')`) |
| 6 | `ObPublication` | `document` | `ToOne` |
| 7 | `ObPublication` | `chunks` | `ToMany` (`@Backlink('publication')`) |

**This list is enumerated, never discovered reflectively.** A reflective
implementation passes its tests while a site is missed, and the failure is
invisible: a chunk whose `publicationId` was not rewritten still exists, still
counts, still renders in a list, and is still returned by scoped search, because
the filter reads `publicationId`.

ObjectBox makes it worse. Deleting a publication row *without* its cascade leaves
the chunks behind and ObjectBox **zeroes the `ToOne` target id while leaving the
denormalized `publicationId` at the dead int**. Measured, not assumed:

```
BEFORE:           publicationId=1  targetId=1
AFTER raw delete: publicationId=1  targetId=0  hasValue=false
                  DIVERGED=true
```

The guard is the data layer's own AC9 — `chunk.publicationId == chunk.publication.targetId` —
asserted after every ingest.

> **Site 7 needed a `@Backlink` to work at all.** `ObPublication.chunks` and
> `ObChunk.publication` have different relation names, and ObjectBox pairs a
> `ToMany` with the *other* side's `ToOne` **by name**. Without the annotation the
> collection resolved to empty while `chunkCount` said 3 — silently, on the plain
> import path, before sync existed. If you add a relation, check the names line up.

## The declared chunk count

Every publication record carries `declaredChunkCount` **outside** its chunk list:
the number of chunks this payload contains. A mismatch **refuses the whole
payload**.

**Why a declaration is needed at all.** Measured during planning: a 50-chunk set
truncated to 30 **passed** a count-and-contiguity check that compared nothing
against a declaration. Thirty contiguous chunks are indistinguishable from a
legitimately thirty-chunk publication, so the receiver cannot infer truncation on
its own.

**It is a check, never a repair.** A mismatch refuses the payload and leaves the
receiver's existing set byte-for-byte unchanged. Pruning toward a declared number
is the boundary-marker approach this design replaced, and it is unsafe: it splits
the set across two travelling facts that must agree exactly, and a truncated
payload is indistinguishable from a complete one at the store.

An **empty** set is legitimate, not corruption: a publication that yielded no
chunks declares `0` and arrives with nothing.

> **A check that cannot be made to fail is not a check.** The validator tests build
> DTOs in memory, so they stayed green when the field was deleted from the wire
> format. AC7e's real assertion goes `encodePayload` → `decodePayload` →
> `ingestEncoded`. If you change the protocol, re-run that test; it is the one
> that notices.

## `chunksIncluded` — the field that stops a metadata push wiping the index

`declaredChunkCount` counts the chunks **in this payload**. `chunksIncluded` says
whether a set was selected for transfer at all.

Without it, a metadata-only push — a retitle, an attach, which FR5a says must not
ship the corpus — erases the receiver's chunks:

| State | Without `chunksIncluded` | What the receiver concludes |
|---|---|---|
| no chunks, declared 0 | identical | the set genuinely shrank to nothing |
| set not selected | identical | ditto — **and it applies an empty set** |
| set shrank to nothing | identical | correct, by luck |

The receiver acts on "the chunk-set version advanced", and the payload carries the
sender's *current* chunk-set version, which compares as newer than anything the
receiver holds. So it replaces fifty chunks with none, reports `chunkCount == 0`,
and throws nothing. The document is still there.

## The two versions, and three axes

A publication's payload has three **independently versioned** parts:

| Event | metadata + edges | chunk set | document text | Transfers |
|---|---|---|---|---|
| Retitle | bumps | — | — | metadata only |
| Attach / detach to a notebook | bumps | — | — | metadata only |
| Re-index | bumps | bumps | — | metadata **and** the whole set |
| Re-import of the text | — | — | bumps | the text only |

Without the split, any edit to a publication drags its entire chunk set across, so
**renaming something would cost a full corpus transfer**.

Measured, 10 publications × 300 chunks: first push **4,575,811 bytes**; retitle
**269 bytes** — 0.06%.

### The watermark is per record and per axis, and that is not incidental

A single scalar per peer is **lossy**, and the loss is silent. A freshly imported
publication ends at `versionCounter == 2`, `chunkSetVersion == 1`. Push it; the
watermark becomes 2. Now re-index it: the set version moves 1 → 2, and `2 > 2` is
false, so **the re-index is never selected again**. That is every re-index after
the first push, on every publication.

Two repairs were rejected:

- **A device-level clock** for version counters. Sound for the watermark, but it
  reintroduces exactly what per-record counters exist to prevent: a device that
  imports ten thousand publications once outranks a quiet device on every record
  forever, discarding the quiet device's genuinely later edits.
- **Comparing with `>=`.** Sound for loss, fatal for the delta: in a corpus
  imported in one batch every record shares a counter, so the highest-versioned
  record is re-sent on every push forever.

Per-record counters cost one row per record per peer (`ObPeerWatermark`) and are
exact: a comparison is only ever between two numbers this device produced.

> **The composite key is `'peerDeviceId|recordUuid'`, not two `@Unique()`
> properties.** ObjectBox Dart treats two of those as two *independent* unique
> constraints, so every peer would be limited to one row. And the separator is `|`
> and not `\u0000`: ObjectBox compares string conditions in C, where NUL
> terminates, so a NUL-separated key is compared as its first segment and the
> lookup matches nothing. Both measured, both silent.

## The watermark advances only on acknowledgement

```dart
final payload = selectDelta(peer);
await deliver(encodePayload(payload));   // throws ⇒ nothing recorded
acknowledge(peer, payload);               // only now
```

An interrupted push that advanced the watermark would skip those records on the
next attempt and lose them permanently. **This is the one failure mode idempotency
does not cover**, because nothing throws on the retry — it just quietly sends
less.

Acknowledged versions move forward only. A straggling acknowledgement from an
earlier interrupted attempt must not unwind the cursor, or every interruption
becomes a permanent re-send loop.

A peer with **no rows** means "everything", not "nothing". Named explicitly rather
than defaulted to zero, because "never pushed to" and "fully up to date" are
opposite situations that a zero default conflates.

## The `embeddingModelId` gate

> **The single most important correctness requirement in the protocol, and it did
> not exist until revision 2** — because vectors did not move until revision 2.

Two vectors are only comparable if they came from the same model *and
configuration*. Mixing them returns confident nonsense, and **nothing in the
stored data would reveal it afterwards.**

```
if payload.embeddingModelId != localActiveModel:
    apply metadata and document      ← the user's data is not held hostage
    transfer NO vectors
    leave the publication unindexed  ← chunkCount == 0
```

Three consequences that are easy to get wrong:

- **The document transfers regardless.** The failure must be *visible* — a
  publication marked not-indexed — not an absence.
- **The refused set stays pending.** `chunkSetVersion` is *not* advanced, so a
  later push after a model change still carries it. Advancing it would make the
  refusal permanent and lose the vectors. What the app does on a model change is
  the embedding spec's decision, not this layer's.
- **The model label is not relabelled on a publication that already holds local
  chunks.** `embeddingModelId` describes the vectors the row actually holds. If
  the gate refuses a peer's set while this device holds its own, relabelling the
  row to the peer's model would make the label describe vectors it does not have
  — the same mix the gate prevents, arriving through the metadata field.

AC7b asserts the receiving chunk count is **exactly 0**. "Less than" passes while
some vectors land.

## No clocks, anywhere

A version is `(counter, deviceId)` and nothing else — never `DateTime.now()`.

A laptop whose clock is five minutes fast would, under timestamp-based LWW, win
**every** conflict permanently, including against a correctly-clocked phone. The
`deviceId` tiebreak exists so two devices that independently edited from the same
base version still agree on a winner; without it each believes its own edit won
and the next push flips it back.

`ObTombstone` stores only counters for the same reason.

## Deletes

A delete is a **record type, not a flag**. There is no `isDeleted` boolean and no
tombstone field anywhere in a payload (FR13). A delete carries a uuid and a
version and **no entity type** (FR15); the receiver resolves the uuid against the
notebook box first, then the publication box.

- The receive path runs the **full local cascade** — chunks, document,
  publication — in one transaction. ObjectBox will not do it; see site 7 above.
- **A notebook delete cascade does not re-derive exclusivity on the receiver.**
  The deleting device decides which publications are exclusive and emits a
  separate `DeleteDto` for each one it cascaded; the receiver obeys those records
  rather than recomputing them. Re-deriving would diverge permanently whenever
  the two devices' edge sets differ: the sender's unconditional tombstone (FR14)
  keeps the publication dead on one side while the receiver would keep it alive.
  The cost — a divergent peer can over-delete — is the same accepted loss as D3.
- **A publication edge naming a tombstoned notebook is dropped, not
  materialised.** `UuidScope.resolveNotebook` creates the row it resolves, so an
  edge list is filtered through the tombstone store before it is applied.
  Otherwise a dead notebook returns as an untitled side-bar row — FR14 reached
  through an edge instead of a record.
- The **tombstone goes in the same transaction as the delete.** Written after a
  commit it could be lost, leaving a deleted object resurrectable by an in-flight
  push; written before, a rollback leaves a live object nothing can update. There
  is no safe order outside the transaction.
- A delete for an object this device **never had** is still tombstoned. No
  deletion happens, but without the tombstone an in-flight upsert for the same
  uuid would resurrect it — FR14 has to hold for records we have never seen.
- The tombstone's version is what lets the delete be selected into a later delta.
  The local delete path stamps it; a tombstone stuck at counter 0 would never be
  pushed and the deletion would never reach the peer.

### The notebook cascade, exclusive vs shared

A notebook delete deletes the notebook **and every publication that exists only
inside it**. A publication attached to any other notebook is **shared**: its edge
to this notebook goes away with the notebook, but the publication, its document,
and its chunks survive and stay reachable from the other notebook.

That decision is made on the deleting device, once, at delete time, and is
carried to peers as the delete records it produced (`SyncDeleter.deleteNotebookLocally`).
The physical cascade lives in `ObjectBoxLibraryRepository._cascadePublication` —
one implementation shared by `deletePublication` and the notebook cascade — while
every tombstone and version write lives in `lib/data/sync/`. The tombstone and the
cascade share one transaction, so a failure cannot leave a deleted object
resurrectable or a live object that nothing can update.

## A tombstone beats any live record

**Unconditionally. Regardless of version.** This is stronger than ordering, and it
is what removes the resurrection window: no sequence comparison can ever conclude
that an upsert is newer than a tombstone.

`isDead` deliberately takes **no version argument**, and `shouldApplyIncoming` has
no comparison in its dead branch. Adding `if (incomingVersion > tombstoneVersion)`
is the single most likely way to break this, and it restores the resurrection hole
without any test going red — so both live in one tested function rather than being
re-decided by each caller.

Purged after a year at boot, outside any transaction doing real work. Safe *only*
because long-late records do not occur under the topology below.

## Ingest order

```
validate every chunk set      ← refuses WHOLE, before any write
plan: decide what applies     ← read-only, resolves nothing
for each delete:              one transaction
for each notebook:            one transaction
for each publication:         one transaction   (metadata → document → chunk set)
```

Three properties fall out, and each is a test:

- **Nothing to roll back on a refused payload.** Validation precedes the first
  write, so "refuse whole, store untouched" is structural rather than a claim.
- **No placeholder row ever survives.** `UuidScope` *creates* the rows it
  resolves — a well-formed uuid for an unknown object means "create it" — so the
  decision to apply has to be made **before** resolving. Planning first does that.
  Resolving first and deciding afterwards leaves an untitled publication row for
  every record that lost or was tombstoned, and such a row still renders.
- **Deletes land before upserts.** A payload may carry both for one uuid, and a
  tombstone wins unconditionally. Applying deletes first means the tombstone is
  already written when the upsert is planned, so the upsert is refused by the same
  rule as any other rather than by a special case.

**One transaction per DAG, not one per payload.** Whole-payload atomicity would be
stronger and is deliberately not what this does: a 10,000-chunk first push would
hold a single write lock for the entire transfer, and a failure at the end would
discard everything. Per-DAG transactions bound the lock to one publication and
make a partial push resumable.

`replaceChunks` opens its own transaction. That is safe and *required* to be:
ObjectBox reuses the enclosing transaction for a nested `runInTransaction`
(`Store._runInTransaction`: `final reused = _tx != null`), so the inner call joins
the outer one and neither commits independently.

### The `Never` trap

**A transaction callback whose static return type is `Never` is never invoked.**
`Store.runInTransaction` throws `UnsupportedError('Given transaction callback
always fails.')` without ever calling it. A test that injects a fault and then
asserts "no partial state" would pass **vacuously** under that path, because
nothing ran.

Every ingest transaction body therefore ends in an explicit `return null`, and the
fault hook is called from inside rather than thrown on a `Never`-returning path.
`IngestFaultPoint` exists so a test can throw *after* real writes have landed — a
fault thrown before the first write proves nothing.

## Notebooks are records, not just references

`PublicationDto.notebookUuids` names notebooks; `NotebookDto` carries their titles
and versions.

They have to be records. Referencing a notebook by uuid alone makes the receiver
create a row for it, and that row has an **empty title** — a notebook in the
sidebar with no label, indistinguishable from a bug. It also makes the DAG honest:
a notebook is a *root*, applied before anything that references it, rather than a
row conjured into existence by a reference.

A notebook is also a **delete root**. A notebook tombstone refuses a later
`NotebookDto` (FR14), and the receive path removes the notebook row for a
notebook `DeleteDto`. The exclusive publications it cascaded arrive as their own
delete records, so the receiver needs no notion of exclusivity — see **Deletes**
above.

## AI configs: applied, refused, unshared, deleted

The payload carries a **fifth entity type**, `AiConfigDto` (settings-for-ai).
It has **no relation sites** — a tuple references nothing — so the seven-site
list above is unaffected.

The important difference from every other record type is that a config has
**four** outcomes, not two. The `shared` flag decides:

| Incoming | Local | Outcome |
|---|---|---|
| `shared: true` | anything | upsert (LWW); the token travels and is written |
| `shared: false` | present | **removed** — the row and the token go |
| `shared: false` | absent | no-op (never creates a row) |
| tombstoned uuid | anything | refused, with **no version comparison** (FR14) |

**An unshare is not a delete.** It is a record that says "not for you"; the
sender's tuple is still alive and may be re-shared. Implementing it as a
tombstone would make the uuid permanently unresurrectable and break re-sharing,
so `isDead` is not called on the unshare path.

**A private tuple never travels.** Selection includes an unshared record **only
when the peer already has a watermark for that uuid** — that is, it was shared
with that peer before. Without that guard, every private configuration would be
broadcast as a "remove this" record on the first push. A test removes the guard
and asserts the never-shared case fails.

A **deleted** tuple is ordinary: it is tombstoned locally and travels as a
`DeleteDto`, resolved as the third branch of `_applyDelete` (notebook,
publication, config). The receiver removes the row and writes the tombstone.

### Secrets are flushed separately from the rows

`SyncApplier.ingest` applies ObjectBox rows synchronously and collects the token
operations it implies; `ingestEncoded` is the async entry point that then writes
or deletes them. A caller that used `ingest` alone and skipped the flush would
leave a shared tuple without its token. See
[`settings-conventions.md`](./settings-conventions.md).

## `ToMany.removeWhere`, not `remove`

Inherited from the data layer and equally load-bearing here.

A `ToMany` is a `ListMixin` and ObjectBox entities have **no value equality**, so
`List.remove` compares by *identity*. The entity returned by a query is a
different instance from the one inside the relation, so `remove` silently returns
false — the detach appears to succeed and changes nothing. Compare ids:

```dart
notebook.publications.removeWhere((p) => p.id == publication.id);
```

## OR1 — children are always separate entities

**An over rule.** It governs the schema unconditionally, in every context, whether
or not sync exists. `test/or1_enforcement_test.dart` enforces it, and the check has
two halves because either alone has a hole: a schema scan that flags a column
whose *name* says it holds a set, and a scan of every stored *value* that catches
an innocent name holding a JSON array or a delimited run of identifiers.

The motivating failure is silent. Embedding a card list in a deck row turns "add
three cards" into an edit to the deck, so LWW must choose between dropping the
cards and dropping the title. No error, no failing test, no user signal.

That is exactly this app's `ObPublication` / `ObChunk`: a peer re-indexes (five new
chunks) while this device renames. Both must survive, and they do — because the
chunks are rows.

## NFR2 — the domain layer knows nothing about sync

No `Sync*`, no protocol enum, no uuid-carrying wire concept in `lib/models/`.
A UI component cannot express an opinion about synchronization because it has no
vocabulary for it.

`lib/data/sync/` sits under `lib/data/`, so the existing data-layer locality rules
apply unchanged. The cheapest way to lose this is a *helper on a domain class* that
knows about pushes — `publication.needsPush(peer)` — which involves no import at
all, so the import check stays green while the boundary is gone. Both are tested.

## The topology premise — and when to throw this away

**This design is correct for short, coordinated, direct transfers between live
devices. It is not correct for long-offline divergence, many-peer meshes, or a
server assigning a global order.**

If the product ever needs those, this is **superseded, not extended**. Three things
would have to be replaced, and that is a redesign rather than a patch:

1. **The year-long tombstone purge.** Purging re-opens the resurrection window for
   records arriving more than a year late. Direct pushes over wifi do not produce
   those, which is why a year is safe here and would not be elsewhere.
2. **The reconstructed `deviceId` half.** Each row stores only a counter; the
   device id is read once per store (plan I2). That is exact for records this
   device authored, and for a peer's records it is the tiebreak label this device
   now claims — which cannot reverse an outcome the peer already won, because a
   peer record is only accepted when it *superseded* what was held. Under a
   two-device topology no record can have a third author, so the reconstruction
   never decides anything. **A third peer breaks that**, and it is the first thing
   to re-examine.
3. **The watermark table.** Per record and per axis, which is what makes it exact
   and what makes a third peer expensive rather than wrong.

**Not implemented, and not claimed:** no transport, no pairing, no encryption, no
multi-peer conflict visibility, no re-index-on-model-change. Two peers pushing to
one device converge under LWW, but whether that is *supported* is undecided.
