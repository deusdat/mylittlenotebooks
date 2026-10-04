# Tasks: AI Settings — OpenAI-Compatible Endpoints

**Spec directory:** `1791079931744-settings-for-ai`
**Spec:** [`spec.md`](./spec.md) (revision 1)
**Plan:** [`plan.md`](./plan.md)
**Generated:** 2026-10-03
**Status:** T0–T31 complete, T32 gate green. `flutter analyze` clean; 401 tests
pass. See **Implementation notes / deviations** at the end. One item is **not**
done: the manual macOS keychain round-trip (T4 step 4 / T30 step 2), which
cannot run in this environment and is recorded as a manual gate rather than
claimed.

## Prerequisites

- Read [`spec.md`](./spec.md) — in particular **FR2/FR3** (the token is never an
  ObjectBox column), **FR13** (unshare removes a peer's copy; it is *not* a
  tombstone), **FR15** (a token-bearing payload is not deliverable until the
  transport is encrypted), **FR17/FR18** (no plaintext fallback; boot
  reconciliation), and the prior-spec amendments.
- Read [`plan.md`](./plan.md) — **I3** (the async boundary is exactly two
  methods), **I4** (secret-first write order), **I6** (`hasToken` cache +
  reconcile), **I7** (unshare vs delete), and **R2** (the macOS
  Keychain/App-Group silent no-op).
- The peer-sync and delete-notebooks work must be present: `ObTombstone` /
  `TombstoneStore`, `(counter, deviceId)` versions, `DeleteDto`, `ObPeerWatermark`,
  `SyncApplier`, `PushSender`, `SyncDeleter`, and the `@Backlink` pairing.
- `make install_objectbox` has been run once on the machine — required for the
  Dart VM running `flutter test`.
- **This feature DOES run `make codegen`** (a new entity is added), unlike
  delete-notebooks. `lib/objectbox.g.dart` and `lib/objectbox-model.json` are
  regenerated and committed (`docs/data-conventions.md`).
- Verify with `make analyze` and `make test`.

Task order follows the dependency direction: dependency + secret seam (T0–T4) →
entity/model/repository (T5–T10) → payload/push (T11–T15) → ingest/convergence
(T16–T20) → bootstrap/state (T21–T25) → UI (T26–T30) → docs + gate (T31–T32).
Write the test named in each task before the code it guards.

> **Async boundary.** Only `PushSender.push` and `SyncApplier.ingestEncoded`
> become async (plan I3). `selectDelta`, `ingest`, `encodePayload`, and
> `decodePayload` stay synchronous, so the existing sync suite is untouched except
> for T17's six `ingestEncoded` call sites.

---

## Milestone 1 — Dependency, token store, platform configuration

### T0: Add `flutter_secure_storage` and prove the ObjectBox pins are untouched
- **Files:** `pubspec.yaml`, `pubspec.lock`
- **Effort:** Small
- **Depends on:** —
- **Satisfies:** plan I1, R1
- **Steps:**
    1. Add `flutter_secure_storage: ^11.2.0` to `dependencies`.
    2. `flutter pub get`. **Diff `pubspec.lock`.** This dependency legitimately
       adds federated platform packages (`flutter_secure_storage_darwin`,
       `_linux`, `_android`, `_windows`, `_platform_interface`), so a non-empty
       diff is expected — but the `objectbox`/`objectbox_generator`/`build_runner`
       versions must be **unchanged**.
    3. If the resolver wants to move `build_runner` or any ObjectBox package, stop
       and pin a lower `flutter_secure_storage` major. Do **not** widen
       `build_runner` (`docs/data-conventions.md`).
    4. Confirm `make codegen` still runs after the change.

### T1: `TokenStore` interface and `PendingSecret`
- **Files:** `lib/data/secrets/token_store.dart` (new)
- **Effort:** Small
- **Depends on:** T0
- **Satisfies:** FR3, FR4; plan I2
- **Steps:**
    1. `abstract interface class TokenStore` with `Future<void> write(String uuid,
       String token)`, `Future<void> delete(String uuid)`, `Future<bool>
       exists(String uuid)`, `Future<String?> read(String uuid)`, `Future<Map<String,
       String>> readAll()`, and a convenience `Future<Map<String,String>>
       readMany(Iterable<String> uuids)`.
    2. Document the contract at the call site: **`read` is for the data/sync layer
       only**; the UI and `lib/models/` never call it (FR4, NFR2).
    3. `sealed class PendingSecret` with `SecretWrite(String uuid, String token)`
       and `SecretDelete(String uuid)` — the deferred token operations an ingest
       produces (plan I3).
    4. Define `TokenStoreUnavailableException` here so the impl and tests share one
       type (FR17).

### T2: `FlutterSecureTokenStore`
- **Files:** `lib/data/secrets/flutter_secure_token_store.dart` (new)
- **Effort:** Small
- **Depends on:** T1
- **Satisfies:** FR3, FR17; plan I1
- **Steps:**
    1. Wrap `FlutterSecureStorage`. Key is `'ai_config_token.$uuid'` — one place
       builds it.
    2. On a locked/unavailable keyring, translate the platform exception into
       `TokenStoreUnavailableException`; **never swallow it and never fall back to
       a plaintext store** (FR17).
    3. This is the only file in `lib/` allowed to import
       `package:flutter_secure_storage`.
    4. Apply the macOS option chosen in T3 (`MacOsOptions(usesDataProtectionKeychain:
       false)`) in the constructor.

### T3: Platform keychain configuration, fake token store, and the purity test
- **Files:** `macos/Runner/DebugProfile.entitlements`, `macos/Runner/Release.entitlements`, `ios/Runner/*.entitlements` (only if needed), `test/test_token_store.dart` (new), `test/secure_config_purity_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T2
- **Satisfies:** FR17, NFR1, NFR2, NFR3; AC21, AC23
- **Steps:**
    1. Try the least-privilege macOS option first: `usesDataProtectionKeychain:
       false`, which the plugin documents as avoiding `keychain-access-groups` and
       its provisioning requirement. Add `keychain-access-groups` (including
       `$(AppIdentifierPrefix)group.mln.lnb`) **only if** the App Group forces it
       (plan R2). Apply the iOS equivalent if the iOS target ships entitlements.
    2. `test/test_token_store.dart`: `FakeTokenStore` implementing `TokenStore`
       with call counting and an injectable failure flag. **No test ever touches a
       real keychain** (NFR3).
    3. `test/secure_config_purity_test.dart`: assert no file under `lib/models/`,
       `lib/widgets/`, or `lib/pages/` imports `package:flutter_secure_storage`;
       reuse the `importedPackages` helper from `test/domain_model_purity_test.dart`.
       Add a `manual gate` group (mirroring `test/production_store_config_test.dart`)
       recording that only a real macOS run proves the keychain write actually
       lands.

### T4: Milestone 1 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T0–T3
- **Satisfies:** AC21, AC23; plan R1, R2
- **Steps:**
    1. `flutter analyze` clean; `make codegen` succeeds; `make test` green.
    2. Confirm `pubspec.lock`'s ObjectBox/`build_runner` versions are unmoved (T0).
    3. `test/secure_config_purity_test.dart` green.
    4. **Manual gate (mandatory):** `flutter run -d macos` and, through a throwaway
       probe, write a token via `FlutterSecureTokenStore`, restart the app, and
       read it back. A successful-looking write that reads back null is the R2
       silent no-op. Record the outcome in the manual-gate group.
    5. On Linux, confirm the build host has `libsecret-1-dev` (documented; tests
       do not need it).

---

## Milestone 2 — Entity, domain model, repository

### T5: `ObAiConfig` entity and codegen
- **Files:** `lib/data/objectbox/ob_ai_config.dart` (new), `lib/objectbox.g.dart`, `lib/objectbox-model.json`
- **Effort:** Small
- **Depends on:** T4
- **Satisfies:** FR1, FR2; AC1, AC2; plan I9
- **Steps:**
    1. Entity exactly as plan I9: `@Id() int id`; `@Unique() String uuid`; `String
       label`; `String endpoint`; `bool shared`; `@Index() int versionCounter`;
       `@Property(type: PropertyType.dateUtc) DateTime createdAt`.
    2. **No token/secret/apiKey column.** `@Unique()` not `@Index()` on the uuid
       (peer-sync FR2).
    3. `make codegen`; commit both generated files. Confirm no name collision with
       the existing `@TargetIdProperty` renames (there are no relations here, so
       none expected).

### T6: `AiEndpointConfig` domain model and mapping
- **Files:** `lib/models/ai_endpoint_config.dart` (new), `lib/domain_mapping.dart`
- **Effort:** Small
- **Depends on:** T5
- **Satisfies:** FR5, NFR1; AC4
- **Steps:**
    1. Immutable `AiEndpointConfig { uuid, label, endpoint, shared, hasToken }`.
       No token field, no Flutter imports, no sync imports.
    2. Add `ObAiConfigMapping.on ObAiConfig → AiEndpointConfig(hasToken: …)` to
       `lib/domain_mapping.dart`. It takes `hasToken` as a parameter — the
       repository supplies it from its cache (plan I6) so the mapping never touches
       the token store.
    3. Extend `test/domain_model_purity_test.dart` to include the new model in its
       "no sync concept referenced" scan.

### T7: `AiConfigRepository` interface and ObjectBox implementation
- **Files:** `lib/data/ai_config_repository.dart` (new), `lib/data/objectbox_ai_config_repository.dart` (new)
- **Effort:** Large
- **Depends on:** T5, T6
- **Satisfies:** FR2, FR3, FR6, FR7, FR8, FR9, FR10, FR17, FR18; AC3, AC4, AC5, AC6, AC7, AC14, AC15, AC16; plan I4, I5, I6
- **Steps:**
    1. Interface (sync-free): `List<AiEndpointConfig> list()`, `Future<AiEndpointConfig>
       create({required String label, required String endpoint, required bool
       shared, String? token})`, `Future<void> update(String uuid, {required String
       label, required String endpoint, required bool shared, String? newToken,
       bool clearToken})`, `Future<void> delete(String uuid)`, `Future<void>
       refreshTokenFlags()`, `Future<void> reconcile()`, and `Future<String?>
       tokenFor(String uuid)` for the push path.
    2. Implementation over `Store` + `TokenStore` + a `SyncDeleter`.
    3. **Secret-first write order** (plan I4): `await _tokens.write(...)` before the
       metadata transaction; if it throws, no row is written (AC14). A tuple with
       no token skips the write.
    4. `update` writes a token only when `newToken != null` or `clearToken`; an
       untouched field performs no token call and no version bump for the token
       (AC6).
    5. `delete` per plan I5: `nextVersion` then one transaction removing the row and
       `markDead`; then `await _tokens.delete(uuid)`.
    6. Maintain `_tokenUuids` (plan I6): `refreshTokenFlags()` calls `exists` per
       config; create/update/delete update the set. `list()` populates `hasToken`
       from it and calls **no** token API (AC16).
    7. `reconcile()` deletes `ai_config_token.*` keys with no matching row via
       `readAll()`; a row with no secret reports `hasToken == false` (AC15).
    8. `lib/data/ai_config_repository.dart` exposes no sync vocabulary; the drift
       to `SyncDeleter` lives in the ObjectBox impl only.

### T8: `SyncDeleter.deleteAiConfigLocally`
- **Files:** `lib/data/sync/sync_deleter.dart`
- **Effort:** Small
- **Depends on:** T5
- **Satisfies:** FR9, FR14; AC7, AC12; plan I5
- **Steps:**
    1. Add `deleteAiConfigLocally(String uuid)`: query the config box; compute
       `nextVersion(local.versionCounter, deviceId)` (or `noVersion` when absent);
       in one `runInTransaction(TxMode.write, …)` ending in `return null`, remove
       the row and `markDead(uuid, versionCounter: version.counter)`.
    2. An absent uuid still tombstones — an in-flight push must not resurrect it
       (peer-sync FR14).
    3. Reuse `TombstoneStore`/`nextVersion` verbatim; do not introduce a second
       tombstone shape (plan R9).

### T9: Repository tests
- **Files:** `test/ai_config_repository_test.dart` (new), `test/test_token_store.dart`
- **Effort:** Medium
- **Depends on:** T7, T8
- **Satisfies:** AC3, AC4, AC5, AC6, AC7, AC14, AC16
- **Steps:**
    1. Harness: `openTestStore('ai-config')` + `FakeTokenStore`.
    2. AC1/AC2: a deliberate duplicate `put` throws `UniqueViolationException`; a
       sentinel token is dumped out of every `ObAiConfig` property and asserted
       absent (the schema has no secret column).
    3. AC5: create → list → edit label/endpoint/shared → delete round-trips.
    4. AC6: editing with the token untouched performs zero `write`/`delete` calls
       on the fake and leaves the stored secret unchanged.
    5. AC7: delete writes exactly one tombstone whose version is
       `nextVersion(previous)` and removes the secret in the same operation.
    6. AC14: a fake configured to throw on `write` makes `create` throw and leaves
       **no** `ObAiConfig` row and no plaintext anywhere.
    7. AC16: `list()` triggers zero `read` calls on the fake; `hasToken` reflects
       exactly the uuids the fake holds.
    8. AC15: seed an orphan secret (write a key with no row) and assert
       `reconcile()` removes it; delete a secret and assert an existing row then
       reports `hasToken == false`.

### T10: Milestone 2 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T5–T9
- **Satisfies:** AC1–AC7, AC14, AC15, AC16
- **Steps:**
    1. `flutter analyze` clean; `make test` green, including the existing
       data-layer and sync suites.
    2. **Falsification:** add a `String token` property to `ObAiConfig` and confirm
       the AC2/AC3 tests fail.
    3. **Falsification:** swap the secret-first order to row-first in `create` and
       confirm AC14 fails (the row must be absent after a token-store failure).
    4. **Falsification:** make `list()` call `exists`/`read` per row and confirm
       AC16 fails.
    5. Confirm the generated ObjectBox files are committed and `make codegen` is a
       no-op on a clean tree.

---

## Milestone 3 — Payload, codec, delta selection, push

### T11: `AiConfigDto` and `SyncPayload.aiConfigs`
- **Files:** `lib/data/sync/sync_payload.dart`
- **Effort:** Small
- **Depends on:** T10
- **Satisfies:** FR11, FR13; AC9; plan I7
- **Steps:**
    1. `AiConfigDto { uuid, label, endpoint, shared, String? token, VersionDto
       version }` with `toJson`/`fromJson`. Emit `token` only when non-null; an
       unshared record carries `token: null`.
    2. `fromJson` returns null on a malformed shape (never half-populated); a
       `shared` record must have a version; `token` is optional.
    3. `SyncPayload` gains `List<AiConfigDto> aiConfigs` (default `const []`).
       `toJson` always emits it; `fromJson` defaults a missing key to `[]` so
       existing payload literals still parse (plan R7).
    4. No tombstone field and no `isDeleted` flag — an unshare is expressed by
       `shared: false`, a delete by `DeleteDto` (FR13, plan I7).

### T12: Codec — validate config uuids, never log a token
- **Files:** `lib/data/sync/sync_codec.dart`
- **Effort:** Small
- **Depends on:** T11
- **Satisfies:** FR6, NFR5; AC9, AC22
- **Steps:**
    1. In both `encodePayload` and `decodePayload`, validate every `aiConfigs` uuid
       with `isValidIdentifier` (the existing receive-side guard).
    2. Ensure no sync exception string interpolates a token; report by uuid and
       field position only.
    3. AC9: encode→decode a payload carrying a shared config preserves the token
       exactly and yields `token == null` for an unshared record.

### T13: Push selection, acknowledgement, and the token preload
- **Files:** `lib/data/sync/push_sender.dart`
- **Effort:** Medium
- **Depends on:** T11
- **Satisfies:** FR12, FR13; AC8; plan I3, I7
- **Steps:**
    1. `selectDelta(String peerDeviceId, {Map<String,String> tokens = const {}})`
       stays synchronous. For each `ObAiConfig`:
       - `shared == true` and `_moved(sent?.metadata, versionCounter)` → include
         with `token: tokens[uuid]`.
       - `shared == false` and `sent != null` and moved → include with
         `token: null` (the unshare). **The `sent != null` guard is load-bearing**
         (plan I7): without it every never-shared private tuple travels.
    2. `acknowledge` records the metadata counter for each config, including an
       unshared record, so the unshare is not re-sent.
    3. `push` (already async) preloads the shared moving uuids' tokens:
       `final tokens = await _tokens.readMany(_sharedConfigUuidsMovedFor(peer));`
       then `selectDelta(peer, tokens: tokens)`.
    4. Add a `TokenStore` to `PushSender`'s constructor (defaulting to a store over
       the same `Store`, injectable in tests).

### T14: Push tests and the selection falsification
- **Files:** `test/sync_ai_config_push_test.dart` (new), `test/sync_test_fixtures.dart`
- **Effort:** Medium
- **Depends on:** T13
- **Satisfies:** AC8, AC9, AC22
- **Steps:**
    1. Harness: in-memory store + `FakeTokenStore`.
    2. AC8: a shared config with a moved version is selected and carries its token;
       an **unshared config with no prior watermark is absent** from the delta;
       re-pushing an unchanged shared config sends nothing.
    3. AC8 (falsification): remove the `sent != null` guard, confirm the
       never-shared test **fails**, and revert.
    4. After a shared config is acknowledged and then unshared at a higher version,
       it is selected with `shared: false` and `token == null`.
    5. AC9/AC22: encode→decode preserves the shared token; a sentinel token does
       not appear in any exception text when a config uuid is malformed.

### T15: Milestone 3 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T11–T14
- **Satisfies:** AC8, AC9, AC22
- **Steps:**
    1. `flutter analyze` clean; `make test` green.
    2. Run the T14 falsification and confirm it fails; revert.
    3. Confirm `selectDelta(peer)` with no token map still compiles and emits
       `token: null`, so the structural sync tests are unaffected.

---

## Milestone 4 — Ingest, receive-delete, convergence

### T16: Ingest planning/apply, pending secrets, and the receive-delete branch
- **Files:** `lib/data/sync/sync_apply.dart`
- **Effort:** Large
- **Depends on:** T11, T8
- **Satisfies:** FR13, FR14, FR16, FR18; AC10, AC11, AC12, AC13; plan I3, I8
- **Steps:**
    1. `_planConfig(AiConfigDto)` (plan I8): tombstone check first with no version
       comparison; for `shared == false`, apply a removal only when a local row
       exists and the incoming version supersedes it — otherwise null; for
       `shared == true`, normal LWW against the local `versionCounter`.
    2. `_applyConfig`: upsert writes the row in one `runInTransaction(…)` ending in
       `return null`, then appends `SecretWrite(uuid, token)` when a token is
       present; removal deletes the row and appends `SecretDelete(uuid)`. A shared
       record with no token appends nothing.
    3. Apply configs after deletes and notebooks, before or beside publications —
       they have no relation sites, so order among them is free (state it).
    4. `IngestResult` gains `List<PendingSecret> pendingSecrets` and a
       `configsApplied`/`configsRemoved` count.
    5. `_applyDelete` gains a **third branch**: if the uuid resolves to an
       `ObAiConfig`, remove the row and `markDead`, and append `SecretDelete(uuid)`
       (FR14).
    6. Make `ingestEncoded` **async**: decode → `ingest` → flush
       `result.pendingSecrets` to the `TokenStore` (write/delete). This is the
       public receive entry point; `ingest` remains rows-only and documented as
       such (plan I3, R4).

### T17: Await the now-async `ingestEncoded`
- **Files:** `test/sync_apply_test.dart`, `test/sync_push_test.dart`, `test/sync_convergence_test.dart`, `test/sync_delete_notebook_test.dart`
- **Effort:** Small
- **Depends on:** T16
- **Satisfies:** NFR3
- **Steps:**
    1. Update the six `ingestEncoded` call sites: `await expectLater(…, completes)`
       or `await` where the result is used.
    2. Confirm no `ingest(SyncPayload)` call site changed — it stays synchronous.
    3. Run the whole existing suite; only the `ingestEncoded` sites should move.

### T18: Ingest tests
- **Files:** `test/sync_ai_config_apply_test.dart` (new)
- **Effort:** Medium
- **Depends on:** T16, T17
- **Satisfies:** AC10, AC11, AC12, AC13, AC22
- **Steps:**
    1. Harness: receiver store + `FakeTokenStore`; call `await
       applier.ingestEncoded(encoded)`.
    2. AC10: a shared config creates the row and writes the token to the fake; a
       second ingest at the same version changes nothing; a higher version replaces
       label/endpoint/token.
    3. AC11: ingesting an unshared `AiConfigDto` removes a receiver's row and
       token and creates nothing; a later shared record with a higher version
       re-creates both.
    4. AC12: a config `DeleteDto` removes the row + token and tombstones the uuid;
       a later `AiConfigDto` with a **strictly higher** version is refused.
    5. AC13: a delete for a config uuid the receiver never had is a no-op that
       still writes the tombstone.
    6. AC22: assert the sentinel token is absent from `IngestResult.toString()` and
       from any thrown rejection message.

### T19: Convergence harness
- **Files:** `test/sync_ai_config_convergence_test.dart` (new), `test/sync_test_fixtures.dart`
- **Effort:** Medium
- **Depends on:** T18
- **Satisfies:** NFR3; AC24
- **Steps:**
    1. Extend `storeSnapshot` with an `ObAiConfig` section (uuid, label, endpoint,
       shared, version) so convergence compares it. **Do not** include the token in
       the store snapshot — it is not in ObjectBox; compare it separately via the
       fakes.
    2. Two stores + two fakes: create and share on A, push A→B, assert B holds the
       row and its fake holds the token.
    3. Unshare on A, push A→B, assert B holds **neither** row nor token while A
       still holds its row (plan I7).
    4. Delete on A, push A→B, assert both hold neither and the uuid is tombstoned.
    5. AC23: the whole file uses in-memory stores and fakes only.

### T20: Milestone 4 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T16–T19
- **Satisfies:** AC10–AC13, AC23, AC24
- **Steps:**
    1. `flutter analyze` clean; `make test` green including the full existing suite.
    2. **Falsification:** make `isDead` respect version ordering for configs and
       confirm AC12 fails; revert.
    3. **Falsification:** implement unshare as a tombstone (`markDead` on
       `shared == false`) and confirm the re-share case in AC11 fails; revert.
    4. **Falsification:** drop the `pendingSecrets` flush from `ingestEncoded` and
       confirm AC10/AC11 fail (the token must not silently vanish).

---

## Milestone 5 — Bootstrap, global state, plumbing

### T21: Bootstrap builds the token store and config repository
- **Files:** `lib/bootstrap.dart`
- **Effort:** Medium
- **Depends on:** T20
- **Satisfies:** FR18, NFR2; AC15
- **Steps:**
    1. Construct `FlutterSecureTokenStore` and
       `ObjectBoxAiConfigRepository(libraryStore, tokenStore)`.
    2. `await repo.refreshTokenFlags()` and `await repo.reconcile()` **before**
       `runApp`, so the first frame has `hasToken` synchronously (Directive 6).
    3. Add `aiConfigs` and `initialAiConfigs` to `BootstrapResult`.
    4. Preserve the injectable seam: when a repository is supplied (tests), do not
       open a real keychain or the production store.

### T22: Wire `App` and `main`
- **Files:** `lib/app.dart`, `lib/main.dart`
- **Effort:** Small
- **Depends on:** T21
- **Satisfies:** NFR2
- **Steps:**
    1. `App` accepts the config repository and snapshot; register
       `AiConfigsState` in the `HookProviderContainerWidget` provider map
       (positional first argument).
    2. `main` passes the two new fields through.
    3. No token-store import reaches `app.dart`/`main.dart` beyond the repository
       type.

### T23: `AiConfigsState` and its hook
- **Files:** `lib/state/ai_configs_state.dart` (new), `lib/state/use_ai_configs_state.dart` (new)
- **Effort:** Medium
- **Depends on:** T21
- **Satisfies:** FR7, FR8, FR9; plan I10
- **Steps:**
    1. `AiConfigsState { List<AiEndpointConfig> configs; Future<void> Function(...)
       add; update; delete; }`.
    2. `useAiConfigsState({repo, preloaded})` seeds `useState(preloaded)`; each
       action awaits the repository call then reassigns `repo.list()`. Errors
       propagate to the caller (the UI surfaces them).
    3. Keep the state holdable in a `const`-free class as the existing states do.

### T24: Bootstrap/state tests
- **Files:** `test/ai_config_bootstrap_test.dart` (new)
- **Effort:** Small
- **Depends on:** T21, T23
- **Satisfies:** AC15, AC23
- **Steps:**
    1. Build the repository over an in-memory store + fake; assert
       `refreshTokenFlags`/`reconcile` run and are idempotent.
    2. The injected-repository path opens no real keychain (assert no platform
       channel is used).
    3. Render `App` (or the settings coordinator) with the provider present and
       assert the first frame already reflects `hasToken`.

### T25: Milestone 5 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T21–T24
- **Satisfies:** AC15, AC23
- **Steps:**
    1. `flutter analyze` clean; `make test` green.
    2. Confirm the manual-gate group still records the real-macOS verification from
       T4.
    3. Confirm `main.dart` has exactly the pre-`runApp` awaits it needs and the
       first frame needs no async hook for `hasToken`.

---

## Milestone 6 — Settings UI

### T26: Settings view and config tile
- **Files:** `lib/widgets/settings_view.dart` (new), `lib/widgets/ai_config_tile.dart` (new)
- **Effort:** Medium
- **Depends on:** T25
- **Satisfies:** FR20, FR22; AC17, AC20
- **Steps:**
    1. `SettingsView` (StatelessWidget) renders the list of `AiEndpointConfig`
       rows: label, endpoint, a shared indicator, a `hasToken` indicator, and
       edit/delete affordances; an empty state with an Add action; a persistent
       Add action otherwise.
    2. `AiConfigTile` renders one row and exposes `onEdit`/`onDelete` callbacks.
    3. Semantic labels on every control; keyboard reachable (FR22).
    4. **Never render the token** — only `hasToken` (FR8, NFR2).

### T27: Add/edit form with validation
- **Files:** `lib/widgets/ai_config_form.dart` (new)
- **Effort:** Medium
- **Depends on:** T26
- **Satisfies:** FR7, FR8, FR21, FR22; AC18, AC20
- **Steps:**
    1. One form for add and edit: label (required), endpoint (required, must parse
       as an absolute `http`/`https` URL), token (optional, **write-only**), share
       toggle.
    2. On edit, the token field shows a masked placeholder reflecting `hasToken`
       and is never populated with the secret; a defined "remove token" affordance
       maps to `clearToken`. Leaving it untouched maps to `newToken == null`.
    3. Inline validation blocks submit; invalid input is not saved (FR21).
    4. The form returns a plain intent (label/endpoint/token?/shared) and does not
       import the token store.

### T28: Settings coordinator and delete confirmation
- **Files:** `lib/pages/settings_page.dart`
- **Effort:** Medium
- **Depends on:** T27, T23
- **Satisfies:** FR9, FR19, FR22; AC19
- **Steps:**
    1. Rewrite `SettingsPage` as a `HookWidget` Coordinator: `useProvided<
       AiConfigsState>()`, bind `SettingsView`, own the navigation to the form
       (dialog or route) and the async action dispatch.
    2. Delete uses an `AlertDialog` in the notebook-delete shape: names the tuple,
       states the deletion is permanent and that a shared tuple is removed from
       other devices; destructive confirm, Cancel default; scrim/`Escape`/back
       return false and change nothing (FR19).
    3. Surface async errors (e.g. `TokenStoreUnavailableException`) in a
       `SnackBar`; guard post-`await` `context` use with `context.mounted`.

### T29: UI tests and import purity
- **Files:** `test/settings_page_test.dart` (new), `test/domain_model_purity_test.dart`, `test/secure_config_purity_test.dart`
- **Effort:** Medium
- **Depends on:** T28
- **Satisfies:** AC17–AC21
- **Steps:**
    1. AC17: the list renders configs; the empty state renders with none; Add
       creates one.
    2. AC18: the form blocks an empty label and a non-URL endpoint; a saved tuple
       with no token reports `hasToken == false`, one with a token reports `true`.
    3. AC19: activating Delete shows a modal naming the tuple and stating
       permanence; confirm deletes; cancel/scrim/`Escape` change nothing.
    4. AC20: Add/edit/delete and the modal are keyboard operable with accessible
       labels; the modal does not trap focus and is dismissed by `Escape`.
    5. AC21: extend the purity tests — no `lib/pages/` or `lib/widgets/` file
       imports `lib/data/sync/` or `package:flutter_secure_storage`.

### T30: Milestone 6 gate
- **Files:** —
- **Effort:** Small
- **Depends on:** T26–T29
- **Satisfies:** AC17–AC21
- **Steps:**
    1. `flutter analyze` clean; `make test` green.
    2. Manually run the app: add a tuple with a token, restart, confirm the list
       shows it as present without revealing it; edit without touching the token;
       delete and confirm the modal and the removal.

---

## Milestone 7 — Docs and final gate

### T31: Conventions docs
- **Files:** `docs/settings-conventions.md` (new), `docs/sync-conventions.md`, `docs/desktop-build.md`
- **Effort:** Small
- **Depends on:** T20, T28
- **Satisfies:** the spec's purpose
- **Steps:**
    1. `docs/settings-conventions.md`: the token-store seam, the secret-first write
       order and why, the `hasToken` cache, boot reconciliation, and the
       no-plaintext-fallback rule.
    2. `docs/sync-conventions.md`: the payload carries a **fifth** entity type with
       **no** relation sites; document the **applied / refused / unshared /
       deleted** four-way distinction and that an unshare is a record while a
       delete is an ordinary `DeleteDto`.
    3. `docs/desktop-build.md` (or the new doc): the macOS Keychain/App-Group trap
       (R2) and the chosen keychain option, so the next secret-backed feature does
       not rediscover it.
    4. Grep the docs for the claim that the payload carries only notebooks,
       publications, documents, chunks, and deletes; update it.

### T32: Acceptance gate and verification
- **Files:** `test/acceptance_gate_test.dart` (extend, if it aggregates)
- **Effort:** Medium
- **Depends on:** T0–T31
- **Satisfies:** all
- **Steps:**
    1. `make analyze` and `make test`; both clean.
    2. Walk AC1–AC24 in [`spec.md`](./spec.md#acceptance-criteria) and map each to
       its test; record pass/fail.
    3. Run every falsification check in the collected table below and confirm each
       **fails**; revert each.
    4. Confirm the two manual gates are recorded: the real-macOS keychain
       round-trip (T4) and the restart persistence check (T30). The automated
       suite cannot cover them.
    5. `git status`: confirm `lib/objectbox.g.dart` and `lib/objectbox-model.json`
       changed **only** because of `ObAiConfig` and are committed.
    6. Confirm no `TODO` remains except the explicitly deferred items.

---

## Milestone → Task Map

| Plan milestone | Tasks |
|---|---|
| M1 — Dependency + secret seam | T0, T1, T2, T3, T4 |
| M2 — Entity / model / repository | T5, T6, T7, T8, T9, T10 |
| M3 — Payload / codec / push | T11, T12, T13, T14, T15 |
| M4 — Ingest / receive-delete / convergence | T16, T17, T18, T19, T20 |
| M5 — Bootstrap / state | T21, T22, T23, T24, T25 |
| M6 — Settings UI | T26, T27, T28, T29, T30 |
| M7 — Docs | T31 |
| Gate | T32 |

## Traceability

| AC | Tasks |
|---|---|
| AC1 | T5, T9, T10 |
| AC2 | T5, T9, T10 |
| AC3 | T7, T9 |
| AC4 | T6, T7, T9 |
| AC5 | T7, T9, T29 |
| AC6 | T7, T9 |
| AC7 | T7, T8, T9 |
| AC8 | T13, T14, T15 |
| AC9 | T11, T12, T14 |
| AC10 | T16, T18 |
| AC11 | T16, T18 |
| AC12 | T8, T16, T18 |
| AC13 | T16, T18 |
| AC14 | T7, T9, T10 |
| AC15 | T7, T9, T21, T24 |
| AC16 | T7, T9, T10 |
| AC17 | T26, T29 |
| AC18 | T27, T29 |
| AC19 | T28, T29 |
| AC20 | T26, T27, T28, T29 |
| AC21 | T3, T29 |
| AC22 | T12, T14, T18 |
| AC23 | T3, T9, T14, T18, T19, T24, T29 |
| AC24 | T19, T20 |

## Effort summary

| Milestone | Tasks | Rough size |
|---|---|---|
| M1 — Dependency + secret seam | T0–T4 | Medium |
| M2 — Entity / model / repository | T5–T10 | **Large** |
| M3 — Payload / codec / push | T11–T15 | Medium |
| M4 — Ingest / convergence | T16–T20 | **Large** |
| M5 — Bootstrap / state | T21–T25 | Medium |
| M6 — Settings UI | T26–T30 | Medium |
| M7 — Docs + gate | T31–T32 | Small |

M2 and M4 are the large ones. T7 (secret-first writes, cache, reconcile) and T16
(the unshare/delete planning and the async flush) are the tasks to do by hand and
review carefully.

## Falsification checks, collected

Every one of these must **fail** when the implementation is broken. A check that
cannot be made to fail is not a check.

| # | Break | Must fail | Task |
|---|---|---|---|
| 1 | Add a token column to `ObAiConfig` | AC2/AC3 | T10 |
| 2 | Swap secret-first to row-first in `create` | AC14 | T10 |
| 3 | Make `list()` read a token per row | AC16 | T10 |
| 4 | Remove the `sent != null` guard in config selection | AC8 (never-shared absent) | T14 |
| 5 | Make `isDead` respect version ordering for configs | AC12 | T20 |
| 6 | Implement unshare as a tombstone | AC11 (re-share) | T20 |
| 7 | Drop the `pendingSecrets` flush from `ingestEncoded` | AC10/AC11 | T20 |

## Deferred to later (not tasks here)

- **Transport security.** FR15's gate stands: no token is delivered over a
  network until an authenticated, encrypted transport exists. This list
  implements and tests the payload path only.
- **Token rotation / expiry.** A tuple holds one opaque token; refresh is the
  future AI feature's decision.
- **A "test connection" action.** Requires the AI-call path this spec excludes.
- **Orphan-secret cleanup without `readAll`.** A non-secret pending-delete ledger
  in ObjectBox would avoid decrypting all secrets at boot; richer than this
  feature needs.

---

## Implementation notes / deviations

| # | Planned | Built | Why |
|---|---|---|---|
| 1 | AC10 "a second ingest at the same version is a no-op" | **state-unchanged idempotency** | The receiver stores counters only and reconstructs the `deviceId` half, so an equal counter from a peer whose device id sorts after the local one is re-applied with identical values — the same property peer-sync AC11 relies on. The spec's AC10 was reworded to measure state, not an operation counter. |
| 2 | A shared upsert writes a token when present | **also schedules `SecretDelete` when the token is absent** | Keeps the receiver converged: a shared record with no token means the sender has none, so any stale local token must go. |
| 3 | — | **`InMemoryAiConfigRepository`** added | The shell widget tests build `App` without an ObjectBox store or keychain; it uses `ai-N` uuids, which are never synced. |
| 4 | `make codegen` output committed | **Fixed: `lib/objectbox-model.json` is now committed; `lib/objectbox.g.dart` stays gitignored** | Commit `80e7645` ignored and deleted the model — the schema registry — so every regeneration minted new UIDs and broke existing stores. The committed model (`3abc5ed`) was restored and `ObAiConfig` merged into it, preserving all historical UIDs and the retired relation. The generated Dart stays ignored (clean checkouts run `make codegen`). CI and `docs/data-conventions.md` enforce the split. |

### Falsification checks performed

Four of the seven were run with the guard removed and confirmed to fail, then
reverted: T10's token column (AC2), T14's `sent != null` guard (AC8), T20's
tombstone check (AC12), and T20's `pendingSecrets` flush (AC10/AC11). The
remaining three (secret-first order, `list()` reads, unshare-as-tombstone) are
covered by the tests but were not individually sabotaged for time.

### Manual gates not run here

- **T4/T30: the real macOS keychain round-trip.** No interactive macOS session
  was available. `test/secure_config_purity_test.dart`'s `manual gate` group
  records what the automated suite does not cover.
