# Feature: Peer Device Sync

**Spec directory:** `1790968315311-peer-sync`
**Feature name:** `peer-sync`
**Revision:** 3 — chunks and their embeddings are now synced (rev 2), and four implementation defects were corrected at the requirement level (rev 3; see the **Revision 3 Record**). Revision 2: This reverses D5 of revision 1, and the reversal has four structural consequences beyond the decision itself: `ObChunk` gains a uuid, chunk identity becomes derived rather than assigned, the chunk set is replaced wholesale rather than merged, and vectors become subject to `embeddingModelId` gating. See the **Revision 2 Record**.
**Builds on:** [`1790958509972-publication-data-layer`](../1790958509972-publication-data-layer/) — schema, transactions, and cascade semantics defined there and referenced throughout as "the data-layer spec".

## Over Rules

Over rules govern the whole data layer, not just this feature. They take
precedence over ordinary convenience, over local optimisation, and over any
requirement that would conflict with them. If a future change appears to need to
break one, that change is the thing that needs re-specifying.

### **OR1 — Children are always separate entities with their own identity.**

A parent's child collection is **never** embedded in the parent's row: not as a
JSON or blob column, not as a serialized list, not as a delimited string. Every
child is its own row with its own globally-unique uuid.

This is not a sync detail. It governs the schema unconditionally, in every
context, whether or not sync ever exists.

**Why it is an over rule.** Last-write-wins is only able to produce the
obviously-correct result when children are independent. The canonical case: a
peer edits a deck's title and adds three cards while I edited the same title.

| Incoming | Local | Conflict? | Result |
|---|---|---|---|
| three new cards | absent | none — distinct uuids | all three land |
| title = "X" | title = "Y" | same entity | newer wins; "Y" stays |

Whole-entity LWW rejects the stale title record while the cards pass through as
ordinary inserts. That is the desired outcome, and it needs no field-level or
collection-level merging.

Embed the card list in the deck row instead and adding three cards *becomes* an
edit to the deck. LWW must then choose between dropping the cards and dropping
the title — the outcome above becomes **unrepresentable**, and it fails silently
by losing one or the other. There is no error, no test failure, and no user
signal.

Embedding is a plausible-looking optimisation. It is banned.

**Consequence:** any feature that wants "one row holds many things" — flashcards
on a deck, notes on a publication, tags on a notebook — creates entities, not
columns.

---

## Context

The app is local-first: notebooks, publications, and chunks live in an embedded
store on the device, and nothing leaves it. This spec adds synchronization
between a person's **own devices**, and between partners collaborating on a
shared project.

**No server.** Not "no cloud server yet" — no server at all. A laptop pushes to
a phone over the household wifi. A partner pushes to their partner over the
same. ObjectBox Sync is explicitly not used: the database is free and stays
free, but Sync is a commercial product, and this design is built rather than
bought.

**The topology is what makes the design tractable.** Sessions are short and
coordinated — both devices are live, the transfer is direct, and the gap between
one person's edit and the other's is small. There is no long-offline divergence
to reconcile, no background daemon catching up after a week, and no server
assigning a global sequence number. The absence of those cases is a *load-bearing
premise*, not an oversight, and it is recorded as such in NFR3.

The consequences of that premise are deliberate and visible:

- Deletes are handled by a **tombstone heuristic** rather than by ordering.
  Tombstones beat live records unconditionally. See D1.
- Updates are **last-write-wins**, stated outright rather than as a default. See D2.
- Concurrent edits to the same entity lose one side. This is accepted, named,
  and visible to the user rather than papered over. See D3.

This is not a general-purpose sync engine and does not claim to be one.

## Goals

- Push local changes to another owned device with **no server component**.
- Converge: after a push, every device agrees on the resulting state.
- Make identity **portable across devices** without polluting the domain layer.
- Propagate deletes reliably enough that a deleted publication does not come
  back from a stale push.
- Keep the domain layer and every UI consumer **completely unaware** that sync
  exists.
- Preserve the data-layer spec's transactional and cascade invariants through
  ingest.

## Non-Goals

- **No server of any kind.** No cloud, no relay, no device acting as a hub.
- **No ObjectBox Sync**, and no dependency that implies it.
- **No continuous or background synchronization.** A push is an explicit user
  action. See D4.
- **No field-level or collection-level merging.** LWW operates on whole
  entities. OR1 is what makes this sufficient.
- **No vector-clock / causal-consistency machinery.** Explicitly rejected; NFR3
  explains why it is not needed here and what it would cost if the topology
  changed.
- **No encryption, authentication, or authorisation protocol design.** Transport
  security is the transport's problem. The threat model — a household wifi link
  between two consenting people — is recorded as an Open Question rather than
  assumed away.
- **No multi-user simultaneous editing of one entity.** Accepted loss, D3.
- **No syncing of embedding vectors.** See D5.
- **No undo of a push.** A push is not itself undoable; corrections are made by
  further edits.

## Definitions

- **Push** — a one-directional, user-initiated transfer of local changes to one
  peer device.
- **Payload** — the set of records in a push. Contains uuids; contains no ints.
- **Bounded context** — the two worlds an identifier lives in. The
  **application context** uses int64 storage ids. The **transfer context** uses
  uuids. No value ever occupies both roles.
- **Tombstone** — a local record that a uuid is dead. Never part of a payload.
- **Version** — the pair `(counter, deviceId)` carried by every synced record.
- **DAG** — a publication and everything hanging off it: its document row, its
  chunks, and the notebook association edges.

---

## Requirements

### Identity

- **FR1 — Two representations, two contexts.** Inside the application an entity
  is addressed by its int64 storage id. On the wire it is addressed by its
  uuid. Each context uses exactly one representation; the conversion happens
  only at the storage boundary.

- **FR2 — Every syncable entity carries a globally-unique uuid, `@Unique`.**
  Not `@Index()`. A non-unique index permits duplicates, and a lookup by a
  duplicated uuid then returns an arbitrary one — a silent wrongness of exactly
  the kind this codebase otherwise guards against. `@Unique()` implies an index
  and throws `UniqueViolationException` on the duplicate write.

  Required on `ObNotebook`, `ObPublication`, `ObDocument`, **and `ObChunk`**.
  Chunks are synced in revision 2, so a chunk must be addressable across
  devices — see FR5a for how its uuid is derived.

- **FR2a — A chunk's uuid is derived, not assigned.** A chunk's identity is
  `(publicationUuid, chunkIndex)`, and its uuid is computed deterministically
  from that pair. It is never randomly generated and never persisted as an
  independently chosen value.

  This matters more than it first appears. Chunk identity must be *derivable*,
  never randomly assigned.

  With a random chunk uuid, every re-index mints a wholly new set of identities,
  so a peer receiving one must reconcile N new chunks against N−M identities it
  no longer recognises. Deriving the uuid from `(publicationUuid, chunkIndex)`
  makes chunk identity a pure function of what the chunk *is* — the same value on
  every device, for the lifetime of the publication, needing no coordination and
  no exchange. Re-applying the same chunk set is then idempotent, which matters
  because FR5a re-applies whole sets.

  And if the two devices' chunkers disagree about where chunk 7 ends, both
  compute the same identity for it and LWW resolves the content, exactly as it
  would for any other conflicting edit.

- **FR2b — Identifiers are UUIDv7, not timestamp-plus-counter.** The current
  generator is `microsecondsSinceEpoch` plus a process-local counter, which
  collides across devices by construction: two devices creating a record in the
  same microsecond with the same starting counter produce the *same* identifier.
  That is precisely the failure sync cannot tolerate.

  UUIDv7 is a 48-bit millisecond timestamp (so insertion order survives) plus 62
  bits from `Random.secure()`. Roughly fifteen lines and no new dependency —
  `Random.secure()` is already in `dart:math`. Insertion order matters here
  because it keeps the store's natural ordering aligned with creation order.

  Chunk uuids are the exception: they are derived per FR2a and need no
  randomness or timestamp component.

### Payload

- **FR4 — Serialization lives in `lib/data/sync/`, at the storage layer.** The
  domain layer is never serialized and never learns it is being synchronized.
  The serializer reads `Ob*` rows and emits explicit **transport DTOs** — classes
  that exist only on the wire, built from entity rows and mapped back to entity
  rows on receipt.

  Transport DTOs rather than raw entity serialization, so a property rename
  cannot silently change the protocol.

- **FR5 — Every reference in a payload is a uuid.** Including both
  representations of a relation: the denormalized integer column *and* the
  `ToOne`/`ToMany`. The receiver builds a uuid → local-int map during ingest and
  rewrites each reference as it applies.

  Seven reference sites exist across four entities:

  | Entity | Reference |
  |---|---|
  | `ObChunk` | `publicationId` (denormalized int) + `publication` (ToOne) |
  | `ObDocument` | `publicationId` (int) + `publication` (ToOne) |
  | `ObNotebook` | `publications` (ToMany) |
  | `ObPublication` | `document` (ToOne) + `chunks` (ToMany) |

  ObjectBox stores a `ToOne`/`ToMany` as relation rows *separate* from the
  denormalized column, so both are rewritten and they must agree afterwards.

- **FR5a — A chunk set is replaced wholesale, never merged.** If a payload
  carries chunks for a publication, it carries **all** of that publication's
  chunks. The receiver does not merge the arriving set into what it holds: it
  confirms the set is complete, then **removes every existing chunk for that
  publication and inserts the replacement set**, in one transaction.

  The sequence is: decode the payload, validate it in memory, and only then
  enter a transaction that removes all, inserts all, and sets `chunkCount`. A
  payload that fails validation is rejected **before anything is written** — the
  receiver's existing chunk set is left exactly as it was.

- **FR5a-bis — Completeness is validated against a declared count, never
  inferred.** The payload carries the sender's declared chunk count *outside* the
  chunk list. The receiver checks that the received count matches it, that
  indices are contiguous from `0`, and that every vector is well-formed.

  The declared count is **load-bearing, not a convenience.** Without it,
  truncation is undetectable: thirty contiguous chunks are indistinguishable from
  a legitimately thirty-chunk publication, so a payload cut short mid-transfer
  would be accepted as a complete re-index and would silently shrink the
  publication. Measured in planning — a 50-chunk set truncated to 30 passed a
  count-and-contiguity check that did not compare against a declaration.

  The declared count is used **only as a check, never as a repair.** A mismatch
  refuses the whole payload; it does not prune the receiver's existing chunks
  toward the declared number. That is the difference between this design and the
  count-as-boundary approach it replaced: a boundary infers what *should* exist
  and acts on it, whereas a declaration proves what *was* sent and merely
  refuses a payload that disagrees with itself.

  An empty chunk set is **legitimate**, not corruption: a publication whose text
  yielded no chunks, or one whose vectors were refused by the model gate (FR5b),
  arrives with a declared count of zero.

  This is the same shape as `replaceChunks` in the data-layer spec (FR10 there),
  which is already the *only* write path that inserts chunks — there is no
  operation anywhere that edits one chunk in place. So **no capability is lost by
  discarding per-chunk deltas**: chunk sets already only ever change as a whole.

  **Why this rather than upserts plus a boundary.** Upserts cannot express a
  chunk set that *shrinks*. Thirty arriving chunks alongside fifty held leaves
  twenty that are present, counted by nothing, and returned by searches. A
  boundary marker such as "prune anything at or above `chunkCount`" appears to
  solve that, but it splits the set across two travelling facts — the chunks
  themselves and the count that describes them — which must agree exactly or
  the receiver silently truncates. And a truncated payload is indistinguishable
  from a complete one at the store.

  Wholesale replacement makes the set self-describing and the completeness check
  possible. The receiver either has every chunk or applies nothing.

  **Chunk sets carry their own version, separate from the publication's.** A
  publication's payload has two independently-versioned parts: its metadata and
  its chunk set. Retitling a publication bumps only the metadata version; a
  re-index bumps the chunk-set version and sends the whole set. Without this
  distinction, any edit to a publication would drag its entire chunk set across —
  so renaming a publication would cost a full corpus transfer, which is not what
  "if a publication sends chunks, it sends all of them" should mean.

- **FR5b — A payload carrying vectors is gated on `embeddingModelId`.** Two
  publications whose vectors come from different models are not comparable, and
  mixing them returns confident nonsense that nothing in the data would reveal.

  A push **must not** transmit chunk vectors whose `embeddingModelId` differs
  from the receiving device's active model, and a receiver **must** refuse to
  apply them. The publication metadata itself still transfers — the user gets the
  document, clearly marked as not yet indexed — so the failure is visible rather
  than silent.

  This gate did not exist in revision 1 because chunks were never transferred.
  It is now the single most important correctness requirement in the protocol:
  without it, a stale-model device silently poisons its own index.

- **FR5c — Vectors are encoded as base64 over raw float32 bytes.** 256 float32
  values are 1,024 bytes, which is 1,368 base64 characters.

  Measured: encoding the same vector with `jsonEncode` produces **5,319
  characters — 3.9× larger**. Dart emits doubles at full precision, so a
  float32 value costs 15–20 characters as JSON text against 4 bytes of base64.
  That is why the wire form is the `Float32List`'s bytes and not JSON numbers,
  and it is worth roughly 28 MB saved on a 10,000-chunk first push.

  Base64 rather than a binary frame because the payload is otherwise JSON and
  transport framing is out of scope (D11); base64 costs 33% overhead and keeps
  the whole payload inspectable with ordinary tooling.

- **FR6 — Ingest is applied per publication DAG, in one transaction.** A
  publication, its document, its chunks, and its association edges are applied
  atomically or not at all. A partial ingest must never become observable — the
  same rule the data-layer spec sets for `replaceChunks`.

- **FR7 — Payload order satisfies the DAG.** A chunk arrives after its
  publication. Records are sorted or grouped so no record is applied before its
  parent resolves. See Open Questions for the alternative.

- **FR8 — The data-layer invariants are the ingest post-conditions.** Ingest is
  verified by the checks the data-layer spec already defines, not by new ones:

  - `chunk.publicationId == chunk.publication.targetId` (AC9 there)
  - `publication.chunkCount` equals the actual chunk count (AC10 there)

  These are precisely the properties a botched reference rewrite breaks.

### Updates

- **FR9 — Last write wins.** Stated outright, not as a default. A record with a
  greater version replaces the local one; a record with a lesser version is
  ignored. Ties break on `deviceId`. Both devices evaluating the same pair of
  versions reach the same winner, so the system converges.

- **FR10 — Version is `(counter, deviceId)`, never a wall clock.** `counter`
  increments on every local modification; `deviceId` is a stable per-install
  identifier. Comparison is lexicographic: counter first, then `deviceId`.

  No clock trust is required, which matters because a laptop whose clock is
  minutes fast would otherwise win every conflict permanently.

- **FR11 — A push is a delta.** Everything whose version exceeds the
  watermark last pushed to that peer. The version makes dirty-tracking
  fall out of the data rather than requiring a separate flag, and it makes
  repeated pushes idempotent.

### Deletes

- **FR12 — A delete is a tombstone.** The receiving side resolves the uuid,
  and if the object is present, deletes it and writes a local tombstone. If it
  is absent, the delete is a no-op.

- **FR13 — Tombstones are local-only.** They are never part of a payload.
  Devices converge on deletes without exchanging tombstones: the sender deletes
  and tombstones locally, the receiver deletes and tombstones locally when the
  delete arrives.

- **FR14 — A tombstone beats any live record.** Unconditionally and forever,
  regardless of version. This is *stronger* than ordering and it is what removes
  the resurrection window: no sequence comparison can ever conclude that an
  upsert is newer than a tombstone.

- **FR15 — Tombstones are `(uuid, deletedAt)` only.** No entity-type field. A
  globally-unique uuid identifies what is dead on its own; the entity type is
  needed only at delete time to run the local cascade, and the local delete path
  already knows it.

- **FR16 — Tombstones are purged after one year, at boot.** A boot-time sweep
  deleting rows older than one year. It runs outside any transaction doing real
  work and needs no background thread.

  Purging re-opens the resurrection window for records arriving more than a year
  late. Direct device-to-device pushes over wifi do not produce those, which is
  why one year is safe here and would not be under a different topology.

- **FR17 — The receive-side delete runs the full local cascade.** Chunks, the
  document row, and the publication, in one transaction — mirroring
  `deletePublication` in the data-layer spec (FR12 there).

  This is not optional and ObjectBox will not save us here. Measured: deleting a
  publication's row **without** the cascade leaves its chunks behind, and
  ObjectBox **zeroes the `ToOne` target id while leaving the denormalized
  `publicationId` pointing at the dead int**:

  ```
  BEFORE:           publicationId=1  targetId=1
  AFTER raw delete: publicationId=1  targetId=0  hasValue=false
                     DIVERGED=true
  ```

  The chunk survives, still counts, still renders, and scoped search still
  returns it — because the filter reads `publicationId`. Chunks belonging to a
  publication that no longer exists, with nothing throwing. FR8's post-conditions
  catch exactly this.

### Non-Functional

- **NFR1 — No server, no account, no third party.** Everything is direct between
  two consenting devices.

- **NFR2 — The domain layer contains no sync types.** No `Sync*`, no protocol
  enum, no uuid-carrying wire concept in `lib/models/`. A UI component cannot
  express an opinion about synchronization because it has no vocabulary for it.
  This mirrors the data-layer spec's NFR5 rule and is enforced the same way, by
  a test that inspects imports and type references.

- **NFR3 — The bounded-window premise is load-bearing and is stated.** This
  design is correct for short, coordinated, direct transfers between live
  devices. It is **not** correct for long-offline divergence, many-peer meshes,
  or a server assigning a global order. If the product ever needs those, this
  spec is superseded rather than extended — the tombstone heuristic and the
  counter-based version would both need replacing, and that is a redesign, not
  a patch.

- **NFR4 — Convergence is testable without a second device.** The whole protocol
  is exercisable in-process against two in-memory stores. A test can push
  between them, interleave records, and assert both converge — no network, no
  emulator, no fixtures on disk.

- **NFR5 — Consequential conflicts are surfaced, not silent.** When an incoming
  record loses to a local one, that fact is recorded and available to the UI.
  OR1 means the *data* outcome is almost always right, but "I edited this and
  my change was discarded" is still something a person should be able to see.

- **NFR6 — A push is bounded and interruptible.** It reports progress and can be
  cancelled. It does not block the UI thread, and the local store stays readable
  and writable throughout.

---

## Acceptance Criteria

- [ ] **AC1:** `ObNotebook`, `ObPublication`, `ObDocument`, and `ObChunk` each declare a `@Unique()` uuid. A deliberate duplicate `put` throws `UniqueViolationException`.
- [ ] **AC2:** Generated identifiers are RFC-4122 UUIDv7: version nibble `7`, variant bits `10`, and `DateTime.now()` differences recoverable from the value. Two identifiers minted in the same microsecond differ. Chunk uuids are derived, not generated (FR2a).
- [ ] **AC3:** No payload field carries an int64 storage id. A test asserts every int in an encoded payload is a version counter, `chunkIndex`, `tokenCount`, or `byteSize` — never a storage id.
- [ ] **AC3a:** A chunk's uuid is byte-identical when computed independently on two devices from the same `(publicationUuid, chunkIndex)`.
- [ ] **AC3b:** An encoded chunk carries exactly 1,368 base64 characters for its 256-dimension vector and decodes back to the stored float32 values within float32 precision. The same vector encoded as JSON floats is asserted to exceed 5,000 characters, so a regression to JSON numbering fails rather than quietly inflating every push (FR5c).
- [ ] **AC4:** A record arriving with a lesser version is ignored; a greater version is applied; equal counters break on `deviceId`. All three cases are tested, and both sides independently reach the same winner.
- [ ] **AC5:** A push carries only records whose version exceeds the peer's watermark, and re-pushing the same range changes nothing.
- [ ] **AC6:** After any ingest, `chunk.publicationId == chunk.publication.targetId` holds for every chunk — including chunks whose references were rewritten from another device's ints. This is the FR5/FR8 guard and it must fail if a single reference site is missed.
- [ ] **AC7:** After any ingest, `publication.chunkCount` equals the actual chunk count.
- [ ] **AC7a:** A peer whose chunk set *changes shape* — 30 chunks replacing 50 — leaves exactly 30 after ingest, with the other 20 removed rather than left behind (FR5a).
- [ ] **AC7d:** A payload whose declared chunk count disagrees with what arrived is refused **whole**, and the receiver's existing chunk set is byte-for-byte unchanged. A payload declaring 50 and delivering 30 is refused; so is one declaring 3 and delivering indices `0,1,3`. A payload declaring `0` and delivering nothing is **accepted** (FR5a-bis).
- [ ] **AC7e:** Truncation is detected *because of* the declared count. A test constructs a payload with 30 contiguous chunks and a declaration of 50 and asserts refusal — it must fail if the declaration is removed (FR5a-bis).
- [ ] **AC7c:** Retitling a publication transfers its metadata and **no** chunks. A subsequent re-index transfers the full replacement set. The two versions advance independently (FR5a).
- [ ] **AC7b:** A push from a peer whose `embeddingModelId` differs transfers the publication and its document but **not** its vectors. The receiving publication reports zero chunks and is visibly unindexed. No vector from the mismatched model reaches the store.
- [ ] **AC8:** An ingest interrupted mid-DAG leaves no partial state: a transaction failure rolls back the publication, its document, its chunks, and its edges together.
- [ ] **AC9:** A delete for a uuid the receiver does not have is a no-op, not an error.
- [ ] **AC10:** A tombstoned uuid rejects a subsequent upsert carrying a *higher* version. This is the FR14 rule and the anti-resurrection test.
- [ ] **AC11:** Two stores exchange pushes in both directions and converge to byte-identical logical state, **including their chunk vectors** — which revision 1 could not claim, and which is the practical benefit of D5.
- [ ] **AC12:** OR1 is enforced by a test that fails if any entity gains a serialized child collection — a JSON, blob, or delimited-string column holding other entities.
- [ ] **AC13:** A boot-time purge removes tombstones older than one year and leaves newer ones untouched.
- [ ] **AC14:** No type under `lib/models/` references a sync concept. Verified by a test, not by inspection.
- [ ] **AC15:** The protocol is fully exercised in-process between two in-memory stores, with no network and no device.

---

## Resolved Decisions

| # | Question | Resolution | Why |
|---|---|---|---|
| **D1** | How does a receiver know a delete is not stale? | **Tombstone beats alive, unconditionally.** | Strictly stronger than ordering: it refuses resurrection rather than trying to order the delete against a late upsert. Removes the window instead of narrowing it. |
| **D2** | What resolves update conflicts? | **Last write wins, by `(counter, deviceId)`.** | Stated overtly rather than left as a default. Counter-based, so no clock trust is needed — a laptop with a fast clock would otherwise win every conflict permanently. |
| **D3** | What happens on a concurrent edit? | **One side is lost.** | Accepted. It is the same trade ObjectBox Sync itself makes, it is bounded by NFR3, and NFR5 requires it be visible to the user rather than silent. |
| **D4** | Continuous or user-initiated? | **User-initiated push.** | Matches the topology. A background daemon implies long-offline catch-up, which is precisely the case this design does not handle. |
| **D5** | Are chunk vectors synced? | **Yes — chunks and their embeddings are pushed.** | Revision 2, reversing revision 1. Synced for three reasons: a peer needs no local embedding run, so a synced publication is searchable the moment it lands; both devices then search the *same* vectors, so results agree across devices instead of differing by whatever CoreML and NNAPI did with the same text; and at ~1 KB per chunk a 10,000-chunk library is ~11 MB, which is a one-time cost over household wifi and then excluded from every subsequent push by the watermark (FR11). |
| **D13** | Random or derived chunk identity? | **Derived from `(publicationUuid, chunkIndex)`.** | Chunk identity becomes a pure function of what the chunk *is* — same value on every device, no coordination, no exchange. Makes re-applying a whole set idempotent, and lets two chunker versions disagree about chunk 7 without producing two identities. |
| **D16** | Merge chunk sets, or replace them? | **Replace wholesale.** | Upserts cannot express a shrinking set; twenty leftover chunks would linger uncounted and still searchable. A count-based boundary splits the set across two travelling facts that must agree, and a truncated payload is then indistinguishable from a complete one. Replacement is self-verifying and is already the shape of `replaceChunks`. |
| **D14** | How are vectors encoded on the wire? | **Base64 over raw float32 bytes.** | Measured: JSON float literals are 5,319 characters against base64's 1,368 — **3.9× larger**. With frequent pushes (D4) that is the difference between a snappy transfer and a noticeably slower one. |
| **D15** | What happens when the peer's model differs? | **Transfer the document, refuse the vectors.** | The document is the user's data and transfers regardless. The vectors are refused, because two models' vectors are not comparable and mixing them is undetectable after the fact. The publication arrives visibly unindexed instead. |
| **D6** | Do tombstones sync? | **No — local only.** | Devices converge on deletes without exchanging them. Keeps the payload clean and avoids reconciling disagreeing tombstones. |
| **D7** | Random uuid or content hash? | **Random uuid (v7).** | Forced by D1. Under content addressing a tombstone becomes a permanent blocker: delete a document, re-import the same bytes, same identity, dead forever with no way to revive. Under random uuid a re-import gets a fresh identity, so "already dead → ignore" is sound indefinitely. |
| **D8** | Is the delete record sufficient? | **Yes for acting; no for freshness.** | Chunks, document, and association edges are all derivable from the receiver's own local int — nothing else needs to travel. `ToMany` rows self-heal when a target is deleted (verified). Ordering is handled by D1's tombstone, not by the record. |
| **D9** | Does the domain gain an `Identity` type? | **No.** | One type able to hold either an int or a uuid cannot answer "which is this?" for `equals`/`hashCode`, and admits values the local store cannot resolve. The two representations live in separate bounded contexts and never meet in a single value. |
| **D10** | Serialize the domain or the storage layer? | **Storage layer, via transport DTOs.** | Sync needs the uuid, which lives on the entity row. Transport DTOs decouple the wire format from schema renames, and keep sync concepts out of the domain. |
| **D11** | Encrypt the payload? | **Out of scope here.** | The threat model is a household wifi link between two consenting people. Recorded as an Open Question rather than assumed away — a joint research project may not want plaintext on shared wifi. |
| **D12** | Purge tombstones? | **After one year, at boot.** | Bounds growth at a few hundred bytes per deletion. Safe only because long-late records do not occur under NFR3. |

---

## Open Questions

Genuinely undecided, each needing input this spec cannot supply for itself:

- **The embedding model's identity and dimensions.** Still undecided, and it now
  gates the protocol rather than merely annotating it. `embeddingModelId`'s value
  space determines what FR5b compares against, and the data-layer spec's FR6
  makes a mismatch detectable while leaving the *response* to the embedding spec:
  re-index, prompt, or refuse. D5's reversal does not make this urgent — a synced
  publication is searchable on arrival — but it does make a silent mismatch far
  more consequential, which is exactly what FR5b exists to prevent.
- **Transport security and pairing.** No protocol is designed here. How two
  devices discover each other, authenticate, and encrypt — and whether a shared
  research library warrants more than household wifi — is undecided.
- **Device identity.** `deviceId` must be stable per install and comparable
  across peers. Whether it is generated at install, derived, or user-chosen is
  undecided; it only has to be unique among devices that share a library.
- **Multi-peer ordering.** Two peers can push to the same third device with
  interleaved counters. Convergence still holds by D2, but whether a
  three-device topology is supported or explicitly out of scope is undecided.
- **Watermark storage.** Per-peer watermarks are implied by FR11. Whether they
  live in a table or in preferences is an implementation detail, but a push to a
  *new* peer (no watermark) means "everything", and that should be explicit.

---

## Revision 2 Record

Revision 1 specified **D5: chunks are not synced** — each device re-derives them
locally, on the reasoning that embedding is deterministic and ~1 KB per chunk
would not be worth sending. That is reversed.

### What changed and why

The user syncs a phone often, and a peer that must run the full embedding
pipeline before a received publication becomes searchable is the wrong shape for
that habit. Three things follow from pushing vectors that revision 1 did not
have to solve:

**1. `ObChunk` gains a uuid (FR2).** Revision 1 explicitly excluded chunks from
FR2 on the grounds that they were device-local derived data. They are not any
more.

**2. Chunk identity becomes derived rather than assigned (FR2a, D13).** This is
the consequence that would have been easy to miss. With a *random* chunk uuid,
every re-index mints a wholly new set of identities — so a peer receiving one
sees N new chunks and N−M orphans it was never told to delete. Revision 1 could
ignore this because chunks never crossed the wire. Deriving the uuid from
`(publicationUuid, chunkIndex)` makes a re-index an in-place update, on every
device, forever, and it needs no coordination: both sides compute the same value
from the same pair.

**3. The chunk set must be replaced wholesale (FR5a, D16).** Upserts alone
cannot express a *shrinking* chunk set, and a re-index can shrink one — a
different chunker, or the same document with less content. Thirty arriving
chunks alongside fifty held would leave twenty that are present, counted by
nothing, and returned by searches.

So a payload that carries chunks carries **all** of them. The receiver validates
completeness in memory, then removes every existing chunk for that publication
and inserts the replacement set in one transaction — the same shape as
`replaceChunks`, which is already the only write path that inserts chunks.
**No per-chunk delta capability is lost**, because no operation anywhere edits a
single chunk in place.

The obvious alternative — a `chunkCount`-based boundary, pruning anything at or
above the authoritative count — appears cheaper and is not. It splits one set
across two travelling facts, the chunks and the count describing them, which must
agree exactly or the receiver silently truncates. And a truncated payload is
indistinguishable from a complete one at the store, so the completeness check
that wholesale replacement makes possible simply cannot be written.

### What this made more important, not less

**`embeddingModelId` is now a protocol gate (FR5b, D15).** Revision 1 could note
that a model mismatch was detectable and leave it there. Transferring vectors
means two models' vectors could actually meet in one index — the precise
silence the data-layer spec's FR6 exists to prevent. So a push must not transmit
vectors from a mismatched model, and a receiver must refuse them.

The document still transfers. A publication arrives, clearly marked as not yet
indexed, rather than arriving broken or not arriving at all.

### What planning verification found

Three claims were executed rather than assumed. Two changed the spec.

**The completeness check was impossible as written (FR5a-bis).** Revision 2 first
said the receiver validates that "every chunk is present". It cannot: thirty
contiguous chunks are indistinguishable from a legitimately thirty-chunk
publication. A 50-chunk set truncated to 30 **passed** a count-and-contiguity
check in the spike. The fix is to carry the sender's declared chunk count
*outside* the chunk list and validate against that — and, importantly, to use it
only as a **check**, never as a repair. Refusing a payload that disagrees with
itself is safe; inferring what should exist and pruning toward it is not.

**The JSON payload estimate was wrong by 2.3× (FR5c).** Estimated at ~2.5 KB
per vector; measured at **5,319 characters against base64's 1,368**. Dart emits
doubles at full precision, so a float32 costs 15–20 characters as JSON against
4 bytes of base64. The requirement stands and the justification is now a
measurement — worth roughly 28 MB on a 10,000-chunk first push.

**Derived chunk ids and UUIDv7 both work as designed.** A deterministic
`c-<publicationUuid>-<chunkIndex>` is stable, unique per index and per
publication, and `@Unique` correctly refuses a duplicate with
`UniqueViolationException`. UUIDv7 generated from `Random.secure()` matches the
RFC layout, sorts by time, and produced no collisions across 50,000 draws — with
no new dependency.

### What it did not change

- **OR1 is unaffected.** Chunks were already separate entities — that is what
  the over rule demands, and it is why syncing them is a payload change rather
  than a schema violation.
- **The tombstone heuristic and `(counter, deviceId)` versioning are untouched.**
  They never concerned vectors.
- **OR1's motivating example is unchanged**, and a deck's cards sync exactly the
  way its title does.

### The cost, stated plainly

A first push to a fresh device carries the whole corpus: ~1 KB per chunk, so
~11 MB for 10,000 chunks. Every push after that is a delta (FR11) and excludes
what the peer already has. Per FR5c the vectors are base64 over raw float32
bytes, 1,368 characters per chunk — measured against 5,319 for the same vector
as JSON float literals, a 3.9× difference.

The frequent-sync habit makes the *delta* the common case, which is what makes
this trade reasonable. A peer that re-installs, or a third device joining the
pair, pays the full cost once.

Two consequences of replacement-at-whole-set keep that cost proportionate:

- **Chunk sets carry their own version, separate from the publication's**
  (FR5a). Retitling a publication transfers its metadata and no chunks; only a
  re-index advances the chunk-set version and sends the set. Without that split,
  every edit to a publication would drag its whole chunk set across.
- **Chunk sets change rarely.** The only write path that inserts chunks is
  `replaceChunks`, which runs on import, on a chunker change, and on a model
  change. In steady state a push carries metadata alone.

---

## Revision 3 Record — implementation findings

Four defects were found while implementing M4 and M5. **All four are in the
requirements, not in the implementation**, so per the escalation rule this
record is the fix and the downstream artifacts follow from it. Three of the four
were silent; none threw.

### 1. FR11's scalar watermark loses every re-index after the first push

**FR11 as written** — "everything whose version exceeds the watermark last pushed
to that peer" — combined with **FR10's per-record counters** is unsound.

A freshly imported publication ends at `versionCounter == 2`,
`chunkSetVersion == 1`. Push it; a scalar watermark becomes 2. Re-index it: the
set version moves 1 → 2, and `2 > 2` is false, so **the re-index is never selected
again**. That is not an exotic interleaving — it is what happens to every re-index
after the first push, on every publication.

**Correction.** The watermark is **per peer, per record, and per axis**
(`ObPeerWatermark`, keyed on `(peerDeviceId, recordUuid)`, holding one counter for
each of metadata, chunk set, and document text). FR11's rule is unchanged; what it
compares against is now a per-axis value rather than a maximum over unrelated
records.

Two repairs were considered and rejected:

| Repair | Why rejected |
|---|---|
| A device-level clock for version counters | Sound for the watermark, but it reintroduces exactly what FR10's per-record counters exist to prevent: a device that imports ten thousand publications once outranks a quiet device on every record forever, discarding the quiet device's genuinely later edits. |
| Comparing with `>=` | Sound for loss, fatal for the delta: in a corpus imported in one batch every record shares a counter, so the highest-versioned record is re-sent on every push forever. |

### 2. A metadata-only push silently erased the receiver's chunk set

FR5a says a retitle sends metadata and no chunks. Nothing in the payload then
distinguished three states, all of which look like `chunks: []` with
`declaredChunkCount: 0`:

| State | What the receiver concludes |
|---|---|
| the publication genuinely has no chunks | correct |
| no set was selected — the receiver already has them | **wrong: it applies an empty set** |
| the set shrank to nothing | correct, by luck |

The receiver acts on "the chunk-set version advanced", and the payload carries the
sender's *current* chunk-set version, which compares as newer than anything held.
So a rename on the sender replaced fifty chunks with none on the receiver,
reported `chunkCount == 0`, and threw nothing.

**Correction.** `PublicationDto` gains **`chunksIncluded`**: whether a set was
selected for transfer at all. `declaredChunkCount` keeps its single meaning —
*how many chunks are in this payload* — and this field says whether a set was
included. FR5a-bis's rule is unchanged; the validator additionally refuses a
payload that declares no set while carrying chunks.

### 3. Notebooks were referenced but never synced

`PublicationDto.notebookUuids` named notebooks, and nothing carried their titles.
The receiver therefore created a row per unknown uuid — an **untitled notebook**,
rendering in the sidebar as an empty label indistinguishable from a bug. AC11
("final state identical across both stores") could not be satisfied, and the
divergence was measurable.

**Correction.** `SyncPayload` gains **`notebooks`**: `NotebookDto { uuid, title,
version }`. `ObNotebook` gains `versionCounter`. Notebooks are DAG roots,
applied before anything that references them, rather than rows conjured into
existence by a reference.

### 4. Deletes had no version, so no delta could carry them

FR11 selects by version; FR12–FR13 require a delete to travel while keeping
tombstones local. `ObTombstone` was `(uuid, deletedAt)` only, so a delete was
stuck at counter zero and **a user deletion on this device would never reach a
peer**.

**Correction.** `ObTombstone` gains `versionCounter`, stamped by the local delete
path. **FR15's actual constraint is preserved and is not what this touches**: there
is still no entity-type column, and the reason FR15 gives — a globally-unique uuid
identifies what is dead on its own — is unaffected. A version counter serves delta
selection, not identification.

### Also found: two silent schema and platform traps

Not requirement changes — recorded because both were measured and both are the
kind of failure that produces no error.

- **`ObPublication.chunks` resolved to empty on the plain import path**, before
  sync existed. ObjectBox pairs a `ToMany` with the *other* side's `ToOne` **by
  name**, and `chunks` does not match `publication`. The collection was silently
  empty while `chunkCount` said 3. Fixed with `@Backlink('publication')`, which
  makes reference site 7 self-maintaining.
- **A transaction callback whose static return type is `Never` is never
  invoked.** `Store.runInTransaction` throws
  `UnsupportedError('Given transaction callback always fails.')` without calling
  it. An AC8 fault-injection test written that way passes **vacuously** — nothing
  ran, so "no partial state" holds trivially. Every ingest transaction body
  therefore ends in an explicit `return null`.
