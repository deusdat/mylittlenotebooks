# Plan: Peer Device Sync

**Spec directory:** `1790968315311-peer-sync`
**Plan date:** 2026-10-02
**Target toolchain (verified):** Flutter 3.47.0 stable · Dart 3.13.0 · macOS 26.6.2 (arm64)
**Spec:** revision 2 — see the **Revision 2 Record** and the verification findings in §B
**Builds on:** [`1790958509972-publication-data-layer`](../1790958509972-publication-data-layer/) (revision 2, implemented) — all schema, transaction, and cascade invariants cited below as "the data-layer spec"

---

## Approach

Six milestones. The protocol is small; almost all the difficulty is in three
places where the obvious implementation is wrong in a way that does not throw.

### The design in one paragraph

Push is user-initiated and direct between two devices — no server. An identifier
has exactly one representation in each of two bounded contexts: an int64 inside
the application, a uuid on the wire, and they meet only in `lib/data/sync/`.
Serialization reads `Ob*` rows and emits transport DTOs, so the domain layer
never learns sync exists. Updates are **last-write-wins** on `(counter, deviceId)`
— no clock trust. Deletes are **tombstones** that beat live records
unconditionally and stay local. Chunk sets are **replaced wholesale** after a
declared-count completeness check. Vectors travel as base64 over raw float32
bytes, gated on `embeddingModelId`.

### Where the work actually is

Three places, and all three fail silently:

1. **Reference rewriting.** Seven reference sites across four entities must all be
   rewritten from the sender's ints to the receiver's. Miss one and the
   receiving store holds a chunk pointing at a publication that is not there.
   Measured: ObjectBox **zeroes a `ToOne` target id while leaving the
   denormalized `publicationId` at the dead value** — so the chunk survives,
   counts, renders, and is returned by scoped search.
2. **Completeness checking.** A truncated payload looks exactly like a small one.
   Detectable only against a declared count (FR5a-bis).
3. **`embeddingModelId` gating.** Two models' vectors meeting in one index is the
   exact silence the data-layer spec's FR6 exists to prevent.

Everything else — the delta computation, the transport framing, the purge — is
ordinary code.

---

## Architecture & Design Decisions

### A. Packages

**One new dependency: `uuid ^4.6.0`.** Its own two dependencies —
`crypto ^3.0.0` and `fixnum ^1.1.0` — are **already in our tree at
satisfying versions** (`crypto 3.0.7`, `fixnum 1.1.1`). So it adds zero new
transitive packages.

| Need | How | Verified |
|---|---|---|
| UUIDv7 generation | `Uuid().v7()` | ✅ RFC 9562 layout over 1,000 draws, time-sorted, 0 collisions in 100k |
| Uuid parsing/validation | `Uuid.isValidUUIDFormat`, `parseHex128` | ✅ rejects malformed input |
| Derived chunk ids | String composition, no hashing | ✅ `@Unique` refuses duplicates |
| Base64 float32 wire form | `dart:convert` over `Float32List` bytes | ✅ 1,368 chars, exact round-trip |
| JSON transport DTOs | `dart:convert` | — |
| Tombstone table | A fifth ObjectBox entity | — |

The package is MIT, published two months ago by a **verified publisher**, at
2.7k likes / 15.2M downloads / 160 pub points.

**This reverses an earlier rejection in this plan**, which argued for a
hand-rolled v7 on the grounds that fifteen lines beat a dependency. That was
weighed before checking the dependency tree, and it was wrong on two counts:

1. **The dependency is free.** `crypto` and `fixnum` are already resolved here,
   so "one fewer package to audit" was not true — the transitive surface does
   not move.
2. **It buys something hand-rolling did not.** `Uuid.isValidUUIDFormat` and
   `parseHex128` are needed on the **receive** side, to reject a malformed uuid
   arriving from a peer before it reaches the store. Writing that parser was
   going to happen regardless; here it comes from the same audited package that
   generates the values.

Two further reasons that emerged from using it:

- **Injectable timestamp and random bytes.** `v7(config: V7Options(time,
  randomBytes))` lets a test mint a uuid at a fixed instant, so time-ordering
  is asserted deterministically instead of by generating 1,000 uuids and sorting
  them. The hand-rolled version had no such seam.
- **RFC maintenance is not ours to carry.** Version nibble, variant bits, and
  byte ordering must be exactly right; a mistake yields uuids that look
  perfectly plausible and violate the spec. That is a poor trade in the
  component holding a user's private documents.

**Still rejected: a UUIDv5 derivation for chunk ids.** The library offers `v5`,
and it is a defensible choice. A composed string — `c-<publicationUuid>-
<chunkIndex>` — is globally unique *because the publication uuid is*, needs no
hashing, and is **inspectable**, which matters when a payload turns out to be
wrong and you are reading uuid-bearing strings out of a log. Recorded as I1 so
the choice is visible rather than inherited.

### B. Verification performed before planning

Executed in a scratch package outside the repo. **Two spec claims were wrong and
are now corrected**; both would have shipped as silent behaviour.

| Claim | Method | Result |
|---|---|---|
| UUIDv7 from `Random.secure()`, no dependency | Wrote it; RFC regex, time-ordering, 50k draws | ✅ passes |
| Derived chunk id is stable and unique | Two "devices" computed independently | ✅ |
| `@Unique` refuses a duplicate chunk id | Deliberate duplicate `put` | ✅ `UniqueViolationException` |
| Re-applying a whole set is idempotent | Re-put by derived id | ✅ count stays 1 |
| Wholesale replace shrinks correctly | 30 replacing 50 | ✅ exactly 30 |
| **Truncation is detectable** | 50 declared, 30 contiguous delivered | ❌ **passed the check — spec was wrong** |
| base64 wire form | Round-tripped a real 256-float vector | ✅ 1,368 chars |
| **JSON vector encoding cost** | `jsonEncode` on the same vector | ⚠️ **5,319 chars — 3.9×, not the ~1.7× estimated** |
| Contiguity check catches holes | `0,1,3` declared as 3 | ✅ refused |

Corrections applied to the spec:

- **FR5a-bis (new).** Completeness is validated against the sender's **declared**
  count, carried outside the chunk list. Revision 2's original "validate that
  every chunk is present" was impossible — thirty contiguous chunks are
  indistinguishable from a legitimately thirty-chunk publication. The
  declaration is used as a **check, never a repair**: a mismatch refuses the
  whole payload rather than pruning toward a number.
- **FR5c / D14.** The encoding justification is now a measurement. 5,319
  characters against 1,368 is worth stating precisely, because it is ~28 MB on a
  10,000-chunk first push.

### C. Directory layout

```
lib/
  models/                        # UNTOUCHED by sync (NFR2)
  data/
    identity.dart                # NEW: newUuidV7(), chunkUuidFor()
    objectbox/
      ob_document.dart           # + uuid (FR2)
      ob_chunk.dart              # + uuid, + chunkSetVersion comes from publication
      ob_publication.dart        # + chunkSetVersion (FR5a)
      ob_tombstone.dart          # NEW: uuid, deletedAt
    objectbox_library_repository.dart
    sync/
      sync_payload.dart          # NEW: transport DTOs (D10)
      sync_codec.dart            # NEW: encode/decode, vector base64 (FR5c)
      sync_version.dart          # NEW: (counter, deviceId) compare (FR10)
      sync_tombstones.dart       # NEW: write, consult, purge (FR12-FR16)
      sync_scope.dart            # NEW: uuid <-> local int resolution (FR5)
      sync_apply.dart            # NEW: ingest, one txn per DAG (FR6, FR8)
      push_sender.dart           # NEW: delta selection (FR11)
      sync_validator.dart        # NEW: declared-count check (FR5a-bis)
test/
  identity_test.dart             # UUIDv7 shape, ordering, collisions; derived ids
  sync_codec_test.dart           # base64 round-trip; 1368 chars; no int ids
  sync_version_test.dart         # LWW incl. tie-break and clock independence
  sync_tombstone_test.dart       # FR12-FR16, purge
  sync_scope_test.dart           # FR5 reference rewriting, all seven sites
  sync_apply_test.dart           # FR6-FR8, transactional ingest
  sync_push_test.dart            # FR11 delta, FR5a-bis completeness
  sync_convergence_test.dart     # AC11, AC12, NFR4 two-store harness
```

**No `lib/models/` changes.** That is the requirement (NFR2), and `sync/` sits
under `lib/data/` so the existing domain-purity test keeps passing untouched.

### D. Identity

```dart
// lib/data/identity.dart — a thin seam, so call sites never touch the package
// directly and swapping the generator later is one file's change.
const _uuid = Uuid();

/// RFC 9562 v7: 48-bit millisecond timestamp, so insertion order survives.
String newUuidV7() => _uuid.v7();

/// Deterministic chunk identity. Globally unique *because* the publication
/// uuid is, so no hashing and no coordination are needed.
String chunkUuidFor(String publicationUuid, int chunkIndex) =>
    'c-$publicationUuid-$chunkIndex';

/// Receive-side guard. A uuid arriving from a peer must be well-formed before
/// it is stored or turned into a lookup.
bool isValidUuid(String value) => Uuid.isValidUUIDFormat(fromString: value);
```

The seam is worth its own file even though each function is one line: it keeps
`package:uuid` out of the repositories, gives one place to document *why* v7,
and gives tests a seam that injects a fixed timestamp.

**Migrating off the current generator is not optional decoration.** It is
`microsecondsSinceEpoch` plus a **process-local counter**, which collides across
devices by construction — two devices minting in the same microsecond with the
same starting counter produce the same identifier. That is precisely the failure
sync cannot tolerate, and it is already load-bearing today because the notebook
id is a route parameter.

**Note on intra-millisecond ordering.** v7 sorts by time at *millisecond*
granularity; two uuids minted in the same millisecond order by their random
bits, not by creation. `Uuid().v6()` would give true within-process monotonicity.
It does not matter here — every ordering this app relies on comes from an
explicit `createdAt` or version column, never from a uuid — but the assumption is
recorded rather than left implicit.

### E. Versioning (FR9, FR10)

```dart
typedef Version = ({int counter, String deviceId});

/// Total order: counter first, then deviceId.
int compareVersions(Version a, Version b);
```

No wall clock anywhere. The counter increments on each local modification;
`deviceId` is stable per install. Both sides evaluating the same pair reach the
same winner, so the system converges — and a laptop whose clock is minutes fast
cannot win every conflict permanently.

Per-entity counters are stored **on the entity** as a `versionCounter` int, with
`deviceId` read once from a store-level metadata record. Storing the full
`(counter, deviceId)` per row would put a repeated string in every record; the
pair only needs to be assembled for comparison.

### F. Tombstones (FR12–FR16)

```dart
@Entity()
class ObTombstone {
  @Id() int id = 0;
  @Unique() String uuid;
  @Property(type: PropertyType.dateUtc) DateTime deletedAt;
}
```

Three deliberate properties:

- **Local-only.** Never in a payload. Devices converge on deletes without
  exchanging tombstones (D6).
- **Beats any live record**, regardless of version (FR14). This is what removes
  the resurrection window; no sequence comparison can conclude an upsert is
  newer than a tombstone.
- **Purged after one year at boot** (FR16), outside any transaction doing real
  work. Safe *only* because long-late records do not occur under NFR3.

### G. The two-version split (FR5a)

`ObPublication` gains `chunkSetVersion`, independent of the publication's own
version:

| Event | Metadata version | Chunk-set version | Transfers |
|---|---|---|---|
| Retitle | bumps | unchanged | metadata only |
| Re-index | bumps | bumps | metadata + all chunks |
| Attach to notebook | bumps | unchanged | metadata only |

Without the split, retitling a publication drags its entire chunk set across —
renaming something would cost a full corpus transfer. AC7c pins it.

### H. Ingest (FR5, FR5a, FR5a-bis, FR6, FR8)

```
decode payload
  → validate:  declared count == received count
                indices contiguous from 0
                every vector 256-dim and finite        (FR5a-bis, reuses
                                                         validateEmbedding)
  → refuse whole on any failure; store untouched
  → resolve every uuid reference → local int          (FR5)
  → ONE transaction:
        replaceChunks(localPublicationUuid, drafts)   (FR5a; already atomic)
        set metadata + chunkCount + chunkSetVersion
        apply notebook association edges
  → post-conditions (FR8, no new checks):
        chunk.publicationId == chunk.publication.targetId      (data-layer AC9)
        chunkCount == actual chunk count                       (data-layer AC10)
```

`replaceChunks` is reused verbatim. It is already remove-all-then-insert-all
inside one transaction, and it is the **only** write path that inserts chunks —
which is why wholesale replacement costs no capability (D16).

FR8's post-conditions are the whole reason this is safe. They are the same two
assertions the data-layer spec already has, and they are precisely what a botched
reference rewrite breaks.

### I. `embeddingModelId` gating (FR5b)

```
if (payload.embeddingModelId != localActiveModel) {
  transfer metadata + document;  transfer NO vectors
  mark publication unindexed
}
```

The document is the user's data and transfers regardless. The vectors are
refused, because two models' vectors are not comparable and mixing them is
undetectable after the fact. The publication arrives **visibly unindexed** rather
than arriving broken or not at all. AC7b.

This is the single most important correctness requirement in the protocol, and it
did not exist in revision 1 because vectors did not move.

### J. Decisions the implementation makes

| # | Decision | Alternative | Cost to reverse |
|---|---|---|---|
| **I1** | `chunkUuidFor` is a composed string | UUIDv5 (needs SHA-1) | Low — the column is opaque |
| **I2** | Per-entity `versionCounter` int + one store-level `deviceId` | Store the full `(counter, deviceId)` per row | Low |
| **I3** | Tombstone purge at boot | Background timer | Trivial |
| **I4** | Transport DTOs as hand-written classes | `toJson()` on entities | Medium — but D10's decoupling is the point |
| **I5** | Sync lives under `lib/data/sync/` | A top-level `lib/sync/` | Trivial, but `lib/data/` keeps objectbox imports confined (data-layer NFR5) |
| **I6** | References resolved eagerly at ingest start | Lazily per record | Low — eager makes the txn a single pass |
| **I7** | Declared count as a separate payload field | Folded into `chunkCount` on the publication record | Trivial |

**On I7**: `chunkCount` is already denormalized on `ObPublication` and travels
in the metadata record. Reusing it as the declaration is tempting and needs one
sentence of care: it must be read **before** the chunk set is applied, and it is
a *check*, not an instruction to prune. A dedicated field is clearer at ~4 bytes
per publication and removes the temptation.

---

## Milestones

### M1 — Identity (the foundation everything else assumes)

Add `uuid: ^4.6.0`. `lib/data/identity.dart` with `newUuidV7()`,
`chunkUuidFor()`, and `isValidUuid()`. Migrate
`ObjectBoxNotebookRepository` and `ObjectBoxLibraryRepository` onto
`newUuidV7()` — replacing the counter-based generator.

`@Unique()` on the uuid of `ObNotebook`, `ObPublication`, `ObDocument`. Add
`uuid` to `ObChunk`, derived via `chunkUuidFor`. Add `chunkSetVersion` to
`ObPublication`. Add `ObTombstone`.

Codegen. **Gate:** `flutter analyze` clean; `dart run build_runner build`
succeeds; **no new transitive package appears in `pubspec.lock`** — `crypto` and
`fixnum` were already resolved, so anything new is a regression; the whole
existing suite still passes (the data-layer tests construct uuids indirectly, so
this is where a uuid change first shows up); AC1, AC2, AC3a.

Also assert that a malformed uuid from a "peer" is refused by `isValidUuid` —
the validation the hand-rolled version would have forced us to write ourselves,
and the reason this dependency earned its place.

**Why first:** the uuid generator is a correctness bug today, independent of sync.
It is also the only change in this plan that would be expensive to do later,
because every existing row would need rewriting.

### M2 — Versioning and the tombstone store

`sync_version.dart` with `Version` and `compareVersions`. Per-entity
`versionCounter` columns. Store-level `deviceId` in a metadata record.
`sync_tombstones.dart`: write, consult, purge.

**Gate:** AC4 (LWW incl. tie-break), AC9, AC10 (tombstone beats a higher-version
upsert), AC13 (purge). Assert a clock change between two edits does not affect
outcome — that is the test that distinguishes this from LWW-on-timestamps.

### M3 — Codec and transport DTOs

`sync_payload.dart` and `sync_codec.dart`. Vector base64 (FR5c). Version
serialization. Tombstones explicitly absent from the payload shape.

**Gate:** AC3 (no int storage ids in any payload field), AC3b (1,368 chars, and
JSON exceeds 5,000 so a regression fails), AC2. Falsification: encode a payload
and grep it for any value matching a known local storage id.

### M4 — Reference resolution and ingest

`sync_scope.dart` (uuid → local int, resolving all seven reference sites) and
`sync_apply.dart` (validate, refuse, transaction, post-conditions).
`sync_validator.dart` for the declared-count check.

**Gate:** AC6 (every chunk's `publicationId == targetId` after ingest, including
rewritten references), AC7, AC7d, AC7e, AC7a, AC7b, AC8 (interrupted ingest leaves
nothing partial). AC6 is the one that fails if a single reference site is missed,
so it must be built by writing out all seven sites explicitly rather than
reflectively.

### M5 — Push: delta selection and the version split

`push_sender.dart`. Delta = records whose version exceeds the peer's watermark.
Metadata and chunk set selected by their **independent** versions.

**Gate:** AC5 (re-pushing a range changes nothing), AC7c (retitle sends no
chunks), and a measurement that the delta excludes already-known records.

### M6 — Convergence harness, OR1 enforcement, and docs

`sync_convergence_test.dart`: two in-memory stores, pushes both ways, converge.
OR1 enforcement (AC12) — a test that fails if any entity gains a serialized child
collection. NFR2 enforcement — no sync type reachable from `lib/models/`.
`docs/sync-conventions.md`, recording the traps.

**Gate:** AC11 (converged state including vectors), AC12, AC14, AC15, AC15.
Manual: push laptop → phone over the real wifi transport.

---

## Dependencies

**External: `uuid ^4.6.0` only**, and it adds no transitive package — its
`crypto` and `fixnum` dependencies are already resolved in `pubspec.lock`. The
`build_runner` pin and the lockstep ObjectBox packages from the data-layer spec
are unchanged and still apply — **do not widen `build_runner` while this is in
flight**; R1.

**Internal:** M1 → M2 → M3 → M4 → M5 → M6, strictly sequential. M1 must land
before anything else because every later milestone addresses records by uuid.

**Blocked on nothing.** Notably, M1–M5 do **not** depend on the embedding spec.
The `embeddingModelId` gate compares against whatever the local active model is;
if none is configured, every publication arrives unindexed — which is the correct,
visible behaviour rather than a blocker.

---

## Risks & Mitigations

**R1 — A missed reference site is silent.** Seven sites, and the failure is a
chunk pointing at a publication that does not exist: it counts, renders, and is
returned by scoped search, because the filter reads `publicationId`. ObjectBox
makes it worse by zeroing the `ToOne` while leaving the denormalized column at
the dead value.
→ **Mitigation:** M4 builds the resolution list **explicitly**, one entry per
site, and AC6 asserts `publicationId == targetId` for every chunk after ingest.
A test that reaches the seven sites reflectively would pass while a site was
missed. Falsification: delete one entry from the list and confirm AC6 fails.

**R2 — The completeness check regresses to something unfalsifiable.** This is
the defect planning verification caught. Thirty contiguous chunks look exactly
like a legitimate thirty-chunk publication.
→ **Mitigation:** FR5a-bis makes the declared count mandatory and AC7e asserts
that removing the declaration makes the test **fail**. A completeness check that
cannot be made to fail is not a check.

**R3 — Vectors from two models meet in one index.** Undetectable after the
fact, and returns confident nonsense.
→ **Mitigation:** FR5b gates the transfer on `embeddingModelId`; AC7b asserts
that a mismatched push transfers the document and **zero** vectors, leaving the
publication visibly unindexed. Falsification: assert the receiving chunk count is
0, not merely "less than".

**R4 — The domain layer acquires sync vocabulary.** The single cheapest way to
lose NFR2 is a helper on `Publication` that knows about pushes.
→ **Mitigation:** `sync/` sits under `lib/data/`; AC14 asserts no `lib/models/`
type references a sync concept; the existing domain-purity test continues to pass
untouched and is itself evidence the boundary held.

**R5 — OR1 erodes under a plausible optimisation.** Someone embeds a card list
or a chunk digest into a publication row to "avoid a query". Sync does not
immediately break — it looks fine — but chunk sets and delete cascades stop
working, and the failure appears only under sync.
→ **Mitigation:** AC12 fails if any entity gains a serialized child collection.
OR1 is stated as an over rule precisely because it outlives this feature.

**R6 — Full-corpus first push.** ~11 MB on a fresh peer, or after a re-install.
→ **Mitigation:** FR5c's encoding is worth ~28 MB of that, and the watermark
means it is once per peer. M5 measures the delta. This is accepted in the spec's
Revision 2 Record rather than mitigated away — the frequent-sync habit is what
makes it proportionate.

**R7 — A push is interrupted midway.** The sender must not advance its
watermark, or the peer silently misses records forever.
→ **Mitigation:** the watermark advances only after the peer acknowledges, and
re-pushing a range is a no-op by AC5. M5 must include an interrupted-push test;
without it the "idempotent" claim is unverified.

---

## Open Questions carried forward

From the spec, none of which this plan can settle:

- **The embedding model's identity.** FR5b compares against the local active
  model; its value space is the embedding spec's decision.
- **Transport and pairing.** M1–M5 are transport-agnostic — they operate on
  payloads. How devices discover and authenticate to each other is undecided,
  and D11 keeps encryption out of scope. M6's manual test needs *some* transport
  and will use the simplest thing that works.
- **Third-party peer topology.** Two peers pushing to one device converges under
  LWW, but whether that is supported is undecided.
