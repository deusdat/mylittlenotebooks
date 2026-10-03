# Tasks: Peer Device Sync

**Spec directory:** `1790968315311-peer-sync`
**Spec:** [`spec.md`](./spec.md) (revision 2 — chunks **and** embeddings are synced; see the Revision 2 Record and the verification findings in §B of the plan)
**Plan:** [`plan.md`](./plan.md)
**Generated:** 2026-10-02
**Status:** T0–T22 complete. 315 tests, `flutter analyze` clean. Four
requirement-level defects were found during M4/M5 and corrected in the **Revision
3 Record** of the spec; see **Deviations from this list** at the end. One item is
**not** done: T22 step 4, the manual two-device test, because there is no
transport (deferred, below).

## Prerequisites

- Read [`spec.md`](./spec.md) — in particular **OR1** (the over rule), **FR5a / FR5a-bis** (wholesale replacement and the declared count), **FR5b** (the `embeddingModelId` gate), and the **Corrections found during planning** section. Two of those requirements were written wrong and corrected; implementing the pre-correction version produces silent data loss.
- Read [`plan.md`](./plan.md) §A (why `uuid` and not hand-rolled), §B (what verification found), §H (the ingest sequence), §I (the model gate).
- Read the data-layer spec at [`../1790958509972-publication-data-layer/`](./../1790958509972-publication-data-layer/) — FR10 (`replaceChunks`), FR12 (cascade), AC9/AC10 (the post-conditions reused verbatim here).
- Read `docs/data-conventions.md` — `@TargetIdProperty`, `ToMany.removeWhere`, the transaction rule, and the three silent failure modes this feature inherits.
- **Toolchain:** Flutter 3.47.0 / Dart 3.13.0. `make install_objectbox` must have been run (tests fail at load without it).

**How to read this list**

- Strictly sequential unless `Depends on` says otherwise.
- `Satisfies` names the acceptance criteria a task owns. Not done until demonstrable, not merely written.
- Each milestone ends with a gate, and **every gate after M1 includes a falsification step** — a deliberately broken implementation that the tests must catch. Plan R1, R2, and R3 are all "a test that cannot be made to fail is not a test."
- **T1 is not feature code.** It is the migration that is already overdue regardless of sync.

---

## Milestone 1 — Identity

The uuid generator is a correctness bug *today* — `microsecondsSinceEpoch` plus a process-local counter collides across devices by construction, and the notebook id is already a route parameter. This milestone is worth doing whether or not sync is ever built.

### T0: Add `uuid` and prove it adds no transitive package
- **Files:** `pubspec.yaml`, `pubspec.lock`
- **Effort:** Small
- **Depends on:** —
- **Satisfies:** plan §A
- **Steps:**
    1. Add `uuid: ^4.6.0` to `dependencies`.
    2. `flutter pub get`, then diff `pubspec.lock` against the previous state. **Exactly one new package.** `crypto ^3.0.0` and `fixnum ^1.1.0` are the library's only dependencies and both are already resolved here — anything else appearing is a regression, not an upgrade.
    3. Do **not** widen `build_runner`'s bound. Plan R1: `objectbox_generator` caps `analyzer` below what `build_runner >=2.15.2` requires, and the ranges do not overlap. This feature must not ride on a dependency-resolution change.
    4. Do **not** bump any ObjectBox package. The three move in lockstep, and a skew fails at store-open time rather than compile time.

### T1: `lib/data/identity.dart` — the generation and validation seam
- **Files:** `lib/data/identity.dart` (new), `test/identity_test.dart` (new)
- **Effort:** Small
- **Depends on:** T0
- **Satisfies:** FR2b, FR2a; AC2, AC3a
- **Steps:**
    1. `String newUuidV7()` delegating to `const Uuid().v7()`. `String chunkUuidFor(String publicationUuid, int chunkIndex) => 'c-$publicationUuid-$chunkIndex'`. `bool isValidUuid(String value)` delegating to `Uuid.isValidUUIDFormat(fromString: value)`.
    2. **Keep the seam.** Three one-line functions, but they keep `package:uuid` out of the repositories, give one place to record why v7, and give tests an injection point.
    3. `identity_test.dart`: assert v7 matches the RFC 9562 layout regex across 1,000 draws; assert zero collisions across 100,000; assert **time-ordering via `V7Options(time, …)`** with a fixed timestamp — deterministic, not by generating and sorting. All verified working during planning.
    4. `chunkUuidFor` is stable for the same pair, distinct per index, distinct per publication, and short enough to index.
    5. **Test `isValidUuid` against the receive side specifically**: `''`, `'not-a-uuid'`, `'c-<valid-uuid>'`, and a dash-stripped uuid must all be refused. This is the validation that justified the dependency, and a hand-rolled version would have forced us to write it ourselves.
    6. Record in the file that v7 orders by time at **millisecond** granularity only — within a millisecond, order is by random bits. Nothing in this app orders by uuid; every ordering comes from an explicit timestamp or version column.

### T2: Migrate the existing generators off the collision-prone scheme
- **Files:** `lib/data/objectbox_notebook_repository.dart`, `lib/data/objectbox_library_repository.dart`
- **Effort:** Small
- **Depends on:** T1
- **Satisfies:** FR2b; plan §D
- **Steps:**
    1. Replace `'nb-${DateTime.now().microsecondsSinceEpoch}-${_seq++}'` and its `pub-` counterpart with `newUuidV7()`, and delete both `static int _seq` fields.
    2. **This is the actual bug.** A process-local counter is only unique within one process lifetime, so two devices minting in the same microsecond with the same starting counter produce the same identifier — the one failure sync cannot tolerate, and it is already load-bearing because the notebook id is a route parameter.
    3. Existing rows keep their old-format uuids. That is acceptable: uuids are opaque and never parsed. Do **not** write a migration.
    4. Confirm the collision check in `ObjectBoxNotebookRepository.create` still guards, though with 62 bits of randomness it should now be unreachable.

### T3: `@Unique()` uuids, chunk identity, chunk-set version, tombstone entity
- **Files:** `lib/data/objectbox/ob_notebook.dart`, `ob_publication.dart`, `ob_document.dart`, `ob_chunk.dart`, `ob_tombstone.dart` (new)
- **Effort:** Medium
- **Depends on:** T1, T2
- **Satisfies:** FR2, FR2a, FR12, FR15; AC1
- **Steps:**
    1. **`@Index()` → `@Unique()`** on the uuid of `ObNotebook`, `ObPublication`, `ObDocument`. A non-unique index permits duplicates and a lookup by a duplicated uuid returns an arbitrary one. ObjectBox's own guidance for a secondary ID offers `@Unique` "to prevent duplicates"; `@Unique()` implies the index.
    2. Add `@Unique() String uuid` to `ObChunk`, populated from `chunkUuidFor(publicationUuid, chunkIndex)` — **derived, never randomly generated** (FR2a). A derived identity makes re-applying a whole set idempotent, which matters because FR5a re-applies whole sets.
    3. Add `int chunkSetVersion` to `ObPublication`, independent of the publication's own version (FR5a). Without the split, retitling a publication drags its entire chunk set across.
    4. New `ObTombstone { @Id() int id; @Unique() String uuid; @Property(type: PropertyType.dateUtc) DateTime deletedAt; }` — **two fields only, no entity-type column** (FR15). A globally-unique uuid identifies what is dead; the type is needed only at delete time, and the local delete path already knows it.
    5. Write `chunkUuidFor` results in the same transaction as everything else about a chunk — `domain_mapping.dart` owns it, and a path that sets one and not the other is a layering leak.
    6. `make codegen`. Confirm no name collision — `ObChunk` already carries `@TargetIdProperty('publicationRef')` and `ObDocument` carries `'documentOwnerId'`; a new `uuid` field must not touch either.

### T4: Milestone 1 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T3
- **Satisfies:** AC1, AC2, AC3a
- **Steps:**
    1. `flutter analyze` clean; `make codegen` succeeds with zero errors.
    2. `flutter pub deps` confirms `uuid` adds **no** transitive package beyond itself.
    3. **The whole existing data-layer suite passes unchanged** — the uuid generator changed under 132 existing tests, so this is where a regression surfaces.
    4. AC1: a deliberate duplicate `put` on each of the four entities throws `UniqueViolationException`.
    5. AC2/AC3a: `identity_test.dart` green.
    6. Confirm `pubspec.lock` contains no new ObjectBox or `build_runner` version.

---

## Milestone 2 — Versioning and the tombstone store

### T5: `(counter, deviceId)` versioning
- **Files:** `lib/data/sync/sync_version.dart` (new), `test/sync_version_test.dart` (new)
- **Effort:** Small
- **Depends on:** T4
- **Satisfies:** FR9, FR10; AC4
- **Steps:**
    1. `typedef Version = ({int counter, String deviceId})` and `int compareVersions(Version a, Version b)` — counter first, then `deviceId` lexicographically. A total order, so both sides reach the same winner.
    2. **No wall clock anywhere.** A laptop whose clock is minutes fast would otherwise win every conflict permanently.
    3. `deviceId` is read once from a store-level metadata record; each entity carries only a `versionCounter` int. Storing the repeated string per row would be wasteful (plan I2).
    4. AC4 tests all three cases: greater counter wins, lesser loses, equal counters break on `deviceId`.
    5. **Add a clock-independence test**: advance the system clock (or inject two different "now"s) between two edits and assert the outcome is unchanged. That test is the only thing distinguishing this from LWW-on-timestamps, and it fails the moment someone reintroduces `DateTime.now()`.
    6. Assert `compareVersions` is a genuine total order — antisymmetric, transitive, and total over a sample.

### T6: Tombstone read, write, and purge
- **Files:** `lib/data/sync/sync_tombstones.dart` (new), `test/sync_tombstone_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T3, T5
- **Satisfies:** FR12, FR13, FR14, FR16; AC9, AC10, AC13
- **Steps:**
    1. `bool isDead(String uuid)` — consulted **before** any upsert is applied.
    2. `void markDead(String uuid)` — called on the local delete path and again on the receive path.
    3. **FR14 is the load-bearing rule: a tombstone beats any live record, unconditionally, regardless of version.** This is what removes the resurrection window; no sequence comparison can conclude an upsert is newer than a tombstone. AC10 must test a tombstoned uuid against an upsert carrying a *strictly higher* version.
    4. FR13: tombstones are **local-only**. Add a compile-time or reflection check that no transport DTO has a tombstone field — the simplest enforcement is that the DTO in T9 simply has no such member, and this task states why.
    5. FR16: `void purgeOlderThan(Duration age)`, called at boot. **Outside any transaction doing real work** — the purge is housekeeping and must never share a failure domain with a user's data.
    6. AC13: purge removes exactly the rows older than the threshold and leaves newer ones.
    7. Assert purging is **safe to interrupt** — a partially purged tombstone table must not change any outcome, since every tombstone remaining is still honoured.

### T7: Milestone 2 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T6
- **Satisfies:** AC4, AC9, AC10, AC13
- **Steps:**
    1. `flutter analyze` clean; `flutter test` green including the data-layer suite.
    2. **Falsification:** remove `deviceId` from `compareVersions` and confirm AC4's tie-break case fails. Remove the clock-independence test's clock injection and confirm it passes vacuously.
    3. **Falsification:** make `isDead` respect version ordering — "apply unless the incoming version is newer" — and confirm AC10 fails. This is the single most likely wrong implementation of the tombstone rule, and it re-opens exactly the resurrection hole FR14 exists to close.
    4. Confirm `ObTombstone` has no entity-type column (FR15).

---

## Milestone 3 — Transport DTOs and codec

### T8: Transport DTOs
- **Files:** `lib/data/sync/sync_payload.dart` (new), `test/sync_codec_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T5, T6
- **Satisfies:** FR4, FR1; AC3
- **Steps:**
    1. Hand-written transport classes, built from `Ob*` rows and mapped back on receipt (plan D10). **Not** `toJson()` on the entities: the wire format must be decoupled so a property rename cannot silently change the protocol.
    2. Every reference field is a **uuid** (FR5). No int storage id appears in any DTO.
    3. Include the **declared chunk count as a field distinct from the chunk list** (FR5a-bis, plan I7). `Publication.chunkCount` already exists and is tempting, but a dedicated field removes the temptation to treat it as a repair instruction and costs ~4 bytes per publication.
    4. Include `chunkSetVersion` **independently** of the publication's version (FR5a).
    5. **No tombstone field** (FR13) and **no `isDeleted` boolean** — deletes are a separate record type, not a flag on an upsert.
    6. AC3: encode a fully-populated payload, then assert no value equals any known local storage id. This is the guard for FR1's bounded-context split.

### T9: Codec, including the vector wire form
- **Files:** `lib/data/sync/sync_codec.dart` (new), `test/sync_codec_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T8
- **Satisfies:** FR5c; AC3b
- **Steps:**
    1. Vectors as base64 over the `Float32List`'s bytes — 1,368 characters for 256 float32 values, exactly as measured in planning.
    2. Round-trip a real 256-dimension vector and assert every component within float32 precision.
    3. **AC3b asserts JSON would be larger** — encode the same vector with `jsonEncode` and assert it exceeds 5,000 characters (measured: 5,319, i.e. 3.9×). Without that assertion, a regression to JSON numbering inflates every push silently rather than failing.
    4. Version encoding: `(counter, deviceId)` as two explicit fields, not a packed integer — the wire format must survive a device-id change.
    5. `isValidUuid` applied to **every** uuid on decode (T1 step 5). A malformed uuid from a peer is refused before it reaches the store, never after.
    6. Assert decode is total: any malformed field produces a typed rejection, never a partially-populated DTO.

### T10: Milestone 3 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T9
- **Satisfies:** AC3, AC3b, AC2
- **Steps:**
    1. `flutter analyze` clean; `flutter test` green.
    2. **Falsification:** switch the vector encoding to `jsonEncode` and confirm AC3b fails. If it passes, the size assertion is not load-bearing.
    3. **Falsification:** add an `int publicationId` field to a DTO and confirm AC3 fails. That is the exact mistake a future contributor makes, and it breaks the bounded-context split silently.
    4. Confirm the payload contains no tombstone field.

---

## Milestone 4 — Reference resolution and ingest

**This milestone carries the two failures that do not throw.**

### T11: Reference resolution — all seven sites, written out
- **Files:** `lib/data/sync/sync_scope.dart` (new), `test/sync_scope_test.dart` (new)
- **Effort:** Large
- **Depends on:** T9
- **Satisfies:** FR5; AC6
- **Steps:**
    1. `UuidScope` maps every uuid in an incoming payload to a local int, resolving and **creating** missing rows.
    2. **Enumerate all seven reference sites explicitly, one entry each.** Reflecting over the model would pass while a site was silently missed, which is the whole risk (plan R1):

       | Entity | Reference |
       |---|---|
       | `ObChunk` | `publicationId` (denormalized int) |
       | `ObChunk` | `publication` (ToOne) |
       | `ObDocument` | `publicationId` (denormalized int) |
       | `ObDocument` | `publication` (ToOne) |
       | `ObNotebook` | `publications` (ToMany) |
       | `ObPublication` | `document` (ToOne) |
       | `ObPublication` | `chunks` (ToMany) |

    3. ObjectBox stores `ToOne`/`ToMany` as relation rows **separate** from the denormalized column, so both are rewritten and must agree afterwards.
    4. Resolve eagerly at ingest start, so the transaction is a single pass (plan I6).
    5. **AC6: after ingest, every chunk satisfies `chunk.publicationId == chunk.publication.targetId`.** This is the data-layer spec's own AC9, reused verbatim, and it is what catches a missed site.
    6. **Record why:** deleting a publication row *without* its cascade leaves chunks behind and ObjectBox **zeroes the `ToOne` target id while leaving the denormalized `publicationId` at the dead int** — measured. The chunk still counts, still renders, and scoped search still returns it, because the filter reads `publicationId`.

### T12: The declared-count validator
- **Files:** `lib/data/sync/sync_validator.dart` (new), `test/sync_validator_test.dart` (new)
- **Effort:** Small
- **Depends on:** T9
- **Satisfies:** FR5a-bis; AC7d, AC7e
- **Steps:**
    1. Validate: received count equals the **declared** count; indices contiguous from `0`; every vector 256-dimension and finite (reuse `validateEmbedding`).
    2. **The declared count is what makes truncation detectable at all.** Verified in planning: a 50-chunk set truncated to 30 **passed** a count-and-contiguity check that did not compare against a declaration. Thirty contiguous chunks are indistinguishable from a legitimately thirty-chunk publication.
    3. **A mismatch refuses the whole payload. It never prunes toward the declared number** (FR5a-bis). Refusing a self-inconsistent payload is safe; inferring what *should* exist and acting on it is the boundary-marker approach this spec replaced.
    4. An empty chunk set is **legitimate**: a publication yielding no chunks, or one whose vectors the model gate refused (FR5b), declares `0` and arrives with nothing. AC7d asserts acceptance, not refusal.
    5. AC7d: declared 50 / delivered 30 refused; declared 3 / indices `0,1,3` refused; declared 0 / nothing **accepted**; receiver's existing set byte-for-byte unchanged.

### T13: Ingest — validate, then one transaction per DAG
- **Files:** `lib/data/sync/sync_apply.dart` (new), `test/sync_apply_test.dart` (new)
- **Effort:** Large
- **Depends on:** T11, T12
- **Satisfies:** FR5a, FR6, FR7, FR8, FR17; AC7, AC7a, AC8
- **Steps:**
    1. Order: decode → validate (T12) → **refuse whole on any failure, store untouched** → resolve references (T11) → one `runInTransaction(TxMode.write, …)`.
    2. Inside the transaction: `replaceChunks(localPublicationUuid, drafts)` — reused **verbatim** from the data layer, which is already remove-all-then-insert-all and atomic — then metadata, `chunkCount`, `chunkSetVersion`, and notebook association edges.
    3. **FR5a: a chunk set is replaced wholesale, never merged.** Confirmed during planning that this costs no capability — `replaceChunks` is the *only* write path that inserts chunks, so no per-chunk delta was ever available.
    4. FR7: payload order satisfies the DAG; a record never lands before its parent resolves.
    5. FR17: a receive-side delete runs the **full local cascade** — chunks, document, publication, in one transaction — mirroring `deletePublication`. ObjectBox will not do this for us (T11 step 6).
    6. **FR8 post-conditions, no new checks:** `chunk.publicationId == chunk.publication.targetId` and `chunkCount == actual count` — the data-layer spec's own AC9 and AC10, asserted after every ingest.
    7. AC8: force a throw mid-transaction and assert nothing partial is observable.

### T14: The `embeddingModelId` gate
- **Files:** `lib/data/sync/sync_apply.dart`, `test/sync_apply_test.dart`
- **Effort:** Small
- **Depends on:** T13
- **Satisfies:** FR5b; AC7b
- **Steps:**
    1. If `payload.embeddingModelId` differs from the local active model: apply **metadata and document**, transfer **no vectors**, leave the publication visibly unindexed.
    2. **The document is the user's data and transfers regardless.** The publication arrives marked not-indexed rather than not arriving at all.
    3. **This is the single most important correctness requirement in the protocol**, and it did not exist in revision 1 because vectors did not move. Two models' vectors meeting in one index is the precise silence the data-layer spec's FR6 exists to prevent, and nothing in the data would reveal it afterwards.
    4. AC7b asserts the receiving **chunk count is exactly 0** — not "less than". A weaker assertion passes while some vectors land.

### T15: Milestone 4 gate
- **Files:** —
- **Effort:** Medium
- **Depends on:** T14
- **Satisfies:** AC6, AC7, AC7a, AC7b, AC7d, AC7e, AC8
- **Steps:**
    1. `flutter analyze` clean; `flutter test` green including the data-layer suite.
    2. **Falsification (plan R1): delete one entry from the seven-site resolution list and confirm AC6 fails.** A resolution implemented reflectively would pass while a site was missed; this is the check that the list is real.
    3. **Falsification (plan R2): remove the declared count from the payload and confirm AC7e fails.** A completeness check that cannot be made to fail is not a check.
    4. **Falsification (plan R3): weaken the model gate to "warn and apply" and confirm AC7b fails.**
    5. **Falsification: replace the wholesale replace with upsert-and-prune and confirm AC7a fails** — 30 arriving against 50 held must leave 30, not 50.
    6. Every gate above restores the implementation afterwards. If any does not fail, the test is vacuous — fix the test, not the code.

---

## Milestone 5 — Push

### T16: Delta selection and the two-version split
- **Files:** `lib/data/sync/push_sender.dart` (new), `test/sync_push_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T13
- **Satisfies:** FR11, FR10; AC5, AC7c
- **Steps:**
    1. A push carries every record whose version exceeds the peer's watermark. The version makes dirty-tracking fall out of the data — no separate flag.
    2. Store the watermark **per peer**. A peer with no watermark means "everything", and that should be an explicit case rather than a default of zero records.
    3. **Select metadata and chunks by their independent versions** (FR5a): retitle bumps only the metadata version and transfers no chunks; a re-index bumps `chunkSetVersion` and transfers the set. AC7c pins this.
    4. AC5: pushing the same range twice changes nothing on the receiver.
    5. **The watermark advances only after the peer acknowledges.** An interrupted push that advanced the watermark would silently lose records forever — plan R7.
    6. Test the interrupted push explicitly: fail mid-transfer, assert the watermark did **not** advance, assert a re-push delivers the full range. Without this, "idempotent" is an unverified claim.

### T17: Milestone 5 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T16
- **Satisfies:** AC5, AC7c
- **Steps:**
    1. `flutter analyze` clean; `flutter test` green.
    2. **Falsification:** advance the watermark before the acknowledgement and confirm the interrupted-push test fails.
    3. **Falsification:** select chunks using the publication's metadata version and confirm AC7c fails — that is the bug where renaming a publication ships its whole chunk set.
    4. Measure the delta on a seeded corpus and record the figure, so the ~11 MB first-push cost in the Revision 2 Record is a measurement rather than an estimate.

---

## Milestone 6 — Convergence, the over rule, and docs

### T18: Two-store convergence harness
- **Files:** `test/sync_convergence_test.dart` (new)
- **Effort:** Large
- **Depends on:** T15, T16
- **Satisfies:** NFR4, NFR1; AC11, AC15
- **Steps:**
    1. Two `openTestStore()` instances, pushes exchanged in both directions. **No network, no emulator, no fixture files** (NFR4, AC15).
    2. Seed a corpus with distinct versions, push A→B, mutate, push B→A, and assert both converge — **including their chunk vectors**, which revision 1 could not claim and which is the practical benefit of syncing them.
    3. Exercise the interesting interleavings: a tombstone racing an in-flight upsert; a chunk set replaced while a metadata edit is in flight; a peer with a mismatched `embeddingModelId`.
    4. Assert convergence is **order-independent** — run the same exchange with records shuffled and assert the same final state.
    5. AC11: final state identical across both stores.

### T19: OR1 enforcement
- **Files:** `test/sync_convergence_test.dart` (new)
- **Effort:** Small
- **Depends on:** T18
- **Satisfies:** OR1; AC12
- **Steps:**
    1. A test that scans every entity's model properties for a **serialized child collection** — a JSON, blob, or delimited-string column holding other entities — and fails if one appears.
    2. OR1 is an over rule: it governs the schema unconditionally, in every context, whether or not sync exists. This test is what makes it enforceable rather than folklore.
    3. **The motivating failure is silent.** Embedding a card list in a deck row turns "add three cards" into an edit to the deck, so LWW must choose between dropping the cards and dropping the title. No error, no failing test, no user signal.
    4. Extend the existing `notebook_flow` coverage with the OR1 scenario: a deck whose title is edited on one side while three cards are added on the other must end with **both** the local title and all three cards. That is the whole reason the rule exists.

### T20: Domain-purity and concurrency re-checks
- **Files:** `test/domain_model_purity_test.dart` (existing), `test/sync_convergence_test.dart` (new)
- **Effort:** Small
- **Depends on:** T18
- **Satisfies:** NFR2; AC14
- **Steps:**
    1. Assert no type under `lib/models/` references a sync concept. The cheapest way to lose NFR2 is a helper on `Publication` that knows about pushes.
    2. The existing domain-purity test must pass **untouched** — `sync/` lives under `lib/data/`, so no allowlist change is needed. If that test needs editing, the boundary moved.
    3. NFR6: assert a push does not block the UI isolate and that the local store stays readable and writable throughout. Light-touch — an isolate-safety smoke test, not a benchmark.

### T21: `docs/sync-conventions.md`
- **Files:** `docs/sync-conventions.md` (new)
- **Effort:** Medium
- **Depends on:** T19, T20
- **Satisfies:** the spec's purpose
- **Steps:**
    1. **The seven reference sites, as a table** (T11 step 2) — the first thing a contributor needs and the easiest thing to miss.
    2. **The declared-count rule** (FR5a-bis), including the measured proof that truncation is otherwise undetectable. Emphasise: a check that cannot be made to fail is not a check.
    3. **The `embeddingModelId` gate**, and that it arrived in revision 2 because vectors started moving.
    4. **`ToMany.removeWhere` on the id** — `remove` compares by identity and silently fails. Inherited from the data layer and equally load-bearing here.
    5. **No clocks.** `(counter, deviceId)` and nothing else; a fast clock would win every conflict permanently.
    6. **OR1**, restated as an over rule with its silent failure mode.
    7. Record the topology premise (NFR3) plainly, so a future reader knows this design is correct for short coordinated direct transfers and **not** for long-offline divergence — that it must be superseded, not extended.

### T22: Final gate
- **Files:** —
- **Effort:** Medium
- **Depends on:** T17, T21
- **Satisfies:** all
- **Steps:**
    1. `flutter analyze` reports zero issues. `flutter test` green, including the data-layer suite.
    2. Walk every acceptance criterion AC1–AC15 and record pass/fail.
    3. Confirm `pubspec.lock` shows `uuid` as the **only** new package, and that `build_runner` and the ObjectBox packages are unmoved.
    4. Manual: push laptop → phone over the real transport. Create on one side, observe on the other, edit on both, verify LWW, delete on one side, verify it stays deleted, then restore a year-old tombstone case if practical.
    5. Confirm no `TODO` remains except explicitly deferred items.
    6. **Do not claim what was not verified.** NFR3's topology is still the bounded one; there is no multi-peer support and no server. Report that plainly.

---

## Traceability

| AC | Tasks |
|---|---|
| AC1 | T3, T4 |
| AC2 | T1, T4, T10 |
| AC3 | T8, T10 |
| AC3a | T1, T4 |
| AC3b | T9, T10 |
| AC4 | T5, T7 |
| AC5 | T16, T17 |
| AC6 | T11, T15 |
| AC7 | T13, T15 |
| AC7a | T13, T15 |
| AC7b | T14, T15 |
| AC7c | T3, T16, T17 |
| AC7d | T12, T15 |
| AC7e | T12, T15 |
| AC8 | T13, T15 |
| AC9 | T6, T7 |
| AC10 | T6, T7 |
| AC11 | T18 |
| AC12 | T19 |
| AC13 | T6, T7 |
| AC14 | T20 |
| AC15 | T18 |
| OR1 | T19 |
| NFR1 | T18 |
| NFR2 | T20 |
| NFR4 | T18 |
| NFR6 | T20 |

## Effort summary

| Milestone | Tasks | Rough size |
|---|---|---|
| M1 — Identity | T0–T4 | Medium |
| M2 — Versioning and tombstones | T5–T7 | Medium |
| M3 — Codec and transport | T8–T10 | Medium |
| M4 — Resolution and ingest | T11–T15 | **Large** |
| M5 — Push | T16–T17 | Medium |
| M6 — Convergence, over rule, docs | T18–T22 | Medium |

M4 is the large one, and T11 is the task that most needs doing by hand.

## Falsification checks, collected

Every one of these must **fail** when the implementation is broken. A check that
cannot be made to fail is not a check.

| # | Break | Must fail | Task |
|---|---|---|---|
| 1 | Delete one entry from the seven-site resolution list | AC6 | T15 |
| 2 | Remove the declared chunk count from the payload | AC7e | T15 |
| 3 | Weaken the model gate to warn-and-apply | AC7b | T15 |
| 4 | Replace wholesale-replace with upsert-and-prune | AC7a | T15 |
| 5 | Revert the vector encoding to `jsonEncode` | AC3b | T10 |
| 6 | Add an int storage id to a DTO | AC3 | T10 |
| 7 | Make `isDead` respect version ordering | AC10 | T7 |
| 8 | Remove `deviceId` from `compareVersions` | AC4 | T7 |
| 9 | Advance the watermark before acknowledgement | interrupted-push test | T17 |
| 10 | Select chunks by the metadata version | AC7c | T17 |
| 11 | Embed a serialized child collection in an entity | AC12 | T19 |

## Deferred to later (not tasks here)

- **Transport and pairing.** M1–M5 operate on payloads and are transport-agnostic.
  D11 keeps encryption out of scope. T22's manual test uses whatever transport is
  simplest; making that a supported feature is a separate spec.
- **Third-party peer topology.** Two peers pushing to one device converges under
  LWW, but whether that is supported is undecided.
- **The embedding model itself.** FR5b compares against the local active model;
  its value space belongs to the embedding spec.
- **Rebuilding on model change.** The data-layer spec's FR6 makes a mismatch
  detectable. What the app *does* about it — re-index, prompt, refuse — is the
  embedding spec's decision. FR5b keeps the two vector spaces from ever meeting;
  it does not migrate them.
- **Multi-peer conflict visibility (NFR5).** Surfacing "your edit was discarded"
  needs a UI vocabulary that does not exist yet.


---

## Deviations from this list

Four changes were not in the plan. Each is a **requirement-level** correction
recorded in the Revision 3 Record of the spec, not an implementation choice, and
each was found by a test rather than by inspection.

| # | Planned | Built | Why | Found by |
|---|---|---|---|---|
| 1 | One watermark per peer (T16 step 2) | **Per peer, per record, per axis** (`ObPeerWatermark`) | A scalar watermark silently loses **every re-index after the first push**: set version 1 → 2 against a watermark of 2. Two alternatives (device clock, `>=`) each break a stated requirement — see the record | `AC7c: a re-index then transfers the full replacement set` |
| 2 | `declaredChunkCount` alone (T8 step 3) | **+ `chunksIncluded`** | A metadata-only push replaced the receiver's whole chunk set with nothing, because the payload carried the sender's *current* set version and the receiver acted on "advanced". Silent; `chunkCount` reported 0 | `the receiving end honours chunksIncluded and keeps its own set` |
| 3 | Notebooks referenced by uuid (T8 step 2) | **`NotebookDto` records with titles and versions** | A referenced-but-unsynced notebook arrives **untitled**, in the sidebar. AC11 was unsatisfiable, and the divergence was measurable | `AC11: a corpus created on one device reaches the other intact` |
| 4 | `ObTombstone` is `(uuid, deletedAt)` only (T3 step 4) | **+ `versionCounter`** | A delete with no version cannot be selected into any delta, so a **user deletion never reached a peer**. FR15's actual constraint — no entity-type column — is untouched | `a local delete appears in the next delta` |

Two further findings were traps rather than requirement changes, and both are now
documented at the call site and in `docs/sync-conventions.md`:

- **`ObPublication.chunks` resolved to empty on the plain import path** — no
  `@Backlink`, and ObjectBox pairs a `ToMany` with the other side's `ToOne` *by
  name*. Reference site 7 was unresolvable and nothing threw. This was a
  pre-existing data-layer defect, not a sync one.
- **A transaction callback typed `Never` is never invoked** by
  `Store.runInTransaction`, which made an AC8 fault-injection test pass
  **vacuously**. Every ingest transaction body now ends in an explicit
  `return null`.

### One falsification check did not work the first time

Check 2 ("remove the declared chunk count from the payload → AC7e fails") **passed
with the sabotage applied.** The validator tests build DTOs in memory, so deleting
the field from the wire format never reached them. AC7e now asserts end to end —
`encodePayload` → `decodePayload` → `ingestEncoded` — which is what a
criterion-and-gate list is for.

### Measured figures (T17 step 4)

| Corpus | Delta |
|---|---|
| 10 publications × 300 chunks, first push | **4,575,811 bytes** |
| the same corpus, one retitle | **269 bytes** (0.06%) |
| 20 publications × 100 chunks, selected + encoded | 3,071,906 bytes in **51 ms** |

A 256-dimension vector is 1,368 base64 characters; the same vector as `jsonEncode`
output is 5,319 (3.9×). A first push of 10,000 chunks measures **≈15 MB**, so the
Revision 2 Record's "~11 MB" is low.
