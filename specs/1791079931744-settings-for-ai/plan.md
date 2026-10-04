# Plan: AI Settings — OpenAI-Compatible Endpoints

**Spec directory:** `1791079931744-settings-for-ai`
**Plan date:** 2026-10-03
**Target toolchain:** Flutter 3.47.0 stable · Dart 3.13.0 · macOS arm64 (repo's stated toolchain, `docs/data-conventions.md`)
**Spec:** revision 1
**Builds on:** [`1790968315311-peer-sync`](../1790968315311-peer-sync/) (payload, DTOs, versions, tombstones, delta, ingest), [`1791055194089-delete-notebooks`](../1791055194089-delete-notebooks/) (permanent delete, confirmation modal, tombstone-on-delete), [`1790958509972-publication-data-layer`](../1790958509972-publication-data-layer/) (transactions, layering).

---

## Approach

Seven milestones. Most of the code is ordinary; the difficulty is concentrated in
**one unavoidable architectural fact the spec only implies**: the platform secret
store is **asynchronous**, while every existing sync component is synchronous and
every ObjectBox write is a synchronous transaction.

### The design in one sentence

A tuple is an `ObAiConfig` row (uuid, label, endpoint, share flag, version) plus a
token held in `flutter_secure_storage` under `ai_config_token.<uuid>`; the domain
model carries `hasToken` and never the token; shared tuples travel as a new
`AiConfigDto` in `SyncPayload`, and unsharing removes a peer's copy rather than
tombstoning it.

### Where the work actually is

1. **The async/sync seam.** `flutter_secure_storage` returns `Future`s;
   `selectDelta` and `ingest` are synchronous by design and are called from ~40
   tests. The plan keeps the sync core synchronous and makes exactly two
   boundary methods async, rather than dragging `await` through the protocol
   (I3). This is the decision most likely to be got wrong, and it is the first
   thing this plan settles.
2. **The macOS Keychain/App Group trap.** The plugin's own README warns that if
   the app uses an App Group, tokens can appear to write successfully and
   **never actually be written** unless `keychain-access-groups` includes the
   group — and enabling that entitlement has signing consequences. This app
   *does* use `group.mln.lnb` for ObjectBox. A silent no-op is exactly the
   failure class this codebase documents against (R2).
3. **The unshared-vs-deleted distinction.** Every prior record type was applied
   or refused; a shared tuple can also mean "remove your copy" (spec FR13). This
   has no precedent in `SyncApplier` and needs a plan step of its own (I7).

Everything else — CRUD, the list, the form, the modal — is the same shape as the
notebook feature that already ships.

---

## Architecture & Design Decisions

### I1 — Token storage is split from the entity, and only the token crosses into secret storage

`ObAiConfig` holds metadata; `flutter_secure_storage` holds the token under
`ai_config_token.<uuid>`. The entity has **no** `token`/`secret` column (spec
FR2). Rationale is the spec's D2: sync needs a queryable, versioned metadata row,
and the token must not be in an unencrypted file.

Key derivation is `ai_config_token.<uuid>` so a tuple's secret is addressable
from its uuid with no separate index, and a re-created tuple never inherits a
stale secret because uuids are never reused.

### I2 — The token store is an interface with a fake for tests

`TokenStore` (`lib/data/secrets/token_store.dart`) is an interface:

```dart
abstract interface class TokenStore {
  Future<void> write(String uuid, String token);
  Future<void> delete(String uuid);
  Future<bool> exists(String uuid);
  Future<String?> read(String uuid);          // data layer only, never the UI
  Future<Map<String, String>> readAll();      // account-keyed; boot reconciliation
}
```

`FlutterSecureTokenStore` is the only implementation; a `FakeTokenStore` in
`test/` supports injected failure and call counting (AC14, AC16). No test ever
touches a real keychain (spec NFR3). `lib/models/` and every widget are kept
clear of this import by the purity test (spec NFR1, NFR2).

### I3 — The async boundary is exactly two methods; the sync core stays synchronous

This is the load-bearing decision.

- **Outbound.** `PushSender.selectDelta(peer, {Map<String,String> tokens = const {}})`
  stays synchronous. `PushSender.push()` — already `async` — resolves the shared
  configs' tokens first and passes them in:

  ```dart
  Future<void> push(String peer, Future<void> Function(String) deliver) async {
    final tokens = await _tokens.readMany(_sharedConfigUuidsMovedFor(peer));
    final payload = selectDelta(peer, tokens: tokens);
    await deliver(encodePayload(payload));
    acknowledge(peer, payload);
  }
  ```

- **Inbound.** `SyncApplier.ingest(SyncPayload)` stays synchronous and applies
  ObjectBox rows, collecting token operations into `IngestResult.pendingSecrets`
  as a `List<PendingSecret>` (`SecretWrite(uuid, token)` / `SecretDelete(uuid)`).
  The public receive entry point becomes `Future<IngestResult> ingestEncoded`,
  which decodes, ingests, then flushes the pending secrets.

Why not make the whole pipeline async: it would touch ~40 test call sites and the
sync/transaction core for no correctness gain, and ObjectBox transactions are
synchronous regardless. Why keep `ingest` (rows) and secret-flush separate rather
than atomic: ObjectBox and the keychain **cannot** share a transaction, so the
split is honest rather than papered over (spec NFR4). The hazard — a caller that
ingests rows and forgets the secrets — is closed by making the public entry point
`ingestEncoded` do both, and by AC11/AC12 tests. The low-level `ingest` remains
for structural tests that do not touch secrets.

> `ingestEncoded` changes from `IngestResult` to `Future<IngestResult>`. Six test
> call sites change from `expect(() => …, returnsNormally)` to
> `await expectLater(…, completes)`; this is the only churn the async boundary
> causes in the existing suite.

### I4 — Order of writes on save: secret first, metadata second (no plaintext, no orphan row)

The spec requires that a failed token write leaves **no** metadata row (FR17,
AC14). Two async systems cannot be atomic, so the order is chosen to make the
failure safe:

1. `await tokenStore.write(uuid, token)` — on failure, throw; nothing else has
   happened.
2. `store.runInTransaction { put the metadata row }`.

The reverse order would leave a row whose secret failed to write. The cost of
this order is a *possible orphan secret* if step 2 crashes; that is reconciled at
boot (I6). A config with no token simply skips step 1.

Update follows the same rule only when the token is being replaced: write the new
secret, then bump the version and write metadata. Leaving the token field
untouched performs neither (spec FR8, AC6).

### I5 — Delete is row + tombstone in one transaction, then secret deletion

`AiConfigRepository.delete(uuid)`:

```dart
final version = nextVersion(local.versionCounter, deviceId);
store.runInTransaction(TxMode.write, () {
  _configs.remove(local.id);
  _tombstones.markDead(uuid, versionCounter: version.counter);
  return null;                    // keep the callback off `Never` (sync trap)
});
await _tokens.delete(uuid);       // outside the txn; reconciled if it fails
```

The tombstone version is what lets the delete be selected into a delta
(peer-sync FR11, delete-notebook FR5). The secret delete is outside the
transaction because it cannot be inside one; the boot sweep (I6) removes an
orphan if this throws. This mirrors `SyncDeleter` and reuses `TombstoneStore`.

### I6 — `hasToken` is a cache warmed once, not a stored column and not a per-row read

The spec forbids a stored `hasToken` column (FR5) and forbids reading tokens per
row when rendering the list (NFR6, AC16). The repository therefore keeps an
in-memory `Set<String> _tokenUuids`:

- warmed once in `bootstrap` via `refreshTokenFlags()` (one `exists` call per
  config, no secret read),
- maintained on create/update/delete,
- used by `list()` to populate `AiEndpointConfig.hasToken`.

Boot reconciliation (`reconcile()`) handles both directions:

- **Orphan secrets** — `readAll()` yields the key set; any
  `ai_config_token.*` key with no matching row is deleted. *(Reads values, not
  just keys, because the plugin exposes no key-only enumeration. Bounded,
  boot-time, and recorded as an Open Question — a non-secret pending-delete
  ledger would avoid it.)*
- **Missing secrets** — a row whose token is gone simply reports
  `hasToken == false`; `hasToken` is derived every boot, so it can never claim a
  token that is not there (spec FR18, AC15).

### I7 — Unshare is a record, not a tombstone; deleted is a tombstone

`AiConfigDto { uuid, label, endpoint, shared, token?, version }` with

- `shared == true` → upsert the row and write the token;
- `shared == false` → **remove** any local row and token for the uuid; never
  write the record (spec FR13).

Selection mirrors this:

```dart
for (final config in configs) {
  final sent = sentTo(peer, config.uuid);
  if (config.shared) {
    if (_moved(sent?.metadata, config.versionCounter)) {
      payload.add(AiConfigDto(shared: true, token: tokens[config.uuid], …));
    }
  } else if (sent != null && _moved(sent.metadata, config.versionCounter)) {
    // previously shared with this peer, now unshared → tell it to remove
    payload.add(AiConfigDto(shared: false, token: null, …));
  }
}
```

The `sent != null` guard is deliberate: a tuple that was never shared must not be
sent at all, or every private config would appear in every first push as a
useless "remove this" record. A test asserts a never-shared unshared config is
absent from the delta (AC8), and removal of the guard makes it fail.

`acknowledge` records the metadata counter for configs exactly as it does for
notebooks, including an unshared record, so the unshare is not re-sent.

A **deleted** tuple is different: it is tombstoned (I5) and travels as an
ordinary `DeleteDto` (peer-sync FR12). `SyncApplier._applyDelete` gains a third
branch — resolve the uuid against the config box — removes the row, tombstones
the uuid, and schedules `SecretDelete(uuid)`.

### I8 — `SyncApplier` plans configs like any other record, and reuses `isDead`

Config planning follows the existing two-phase discipline (decide before
resolving, so no placeholder row survives):

```dart
_ConfigPlan? _planConfig(AiConfigDto dto) {
  if (_tombstones.isDead(dto.uuid)) return null;       // FR14, no version check
  final local = _findConfig(dto.uuid);
  if (!dto.shared) {
    // Unshare: only acts if it supersedes the local copy; never creates one.
    if (local == null) return null;
    if (!supersedes(dto.version.toDomain(), _versionOf(local))) return null;
    return _ConfigPlan.remove(dto);
  }
  if (!supersedes(dto.version.toDomain(),
                  local == null ? noVersion : _versionOf(local))) return null;
  return _ConfigPlan.upsert(dto, token: dto.token);
}
```

Applying an upsert writes the row inside `runInTransaction(TxMode.write, …)`
ending in `return null`; the token operation is appended to `pendingSecrets`.
Deletes are still applied before upserts, so a `DeleteDto` for a config and an
`AiConfigDto` for the same uuid in one payload resolve by the tombstone rule
without a special case.

### I9 — `ObAiConfig` mirrors `ObNotebook` exactly

```dart
@Entity()
class ObAiConfig {
  @Id() int id = 0;
  @Unique() String uuid;
  String label;
  String endpoint;
  bool shared;
  @Index() int versionCounter;
  @Property(type: PropertyType.dateUtc) DateTime createdAt;
}
```

`@Unique()` not `@Index()` (peer-sync FR2), `versionCounter` indexed so the delta
scan is cheap, `createdAt` for stable list ordering. No relation sites, so the
"seven reference sites" in `docs/sync-conventions.md` are unaffected; codegen is
required and the generated files are committed (`docs/data-conventions.md`).

### I10 — UI is the existing State → Hook → View → Coordinator shape

- `AiConfigsState` (immutable): `List<AiEndpointConfig> configs` plus async
  `add` / `update` / `delete` actions.
- `useAiConfigsState({repo, preloaded})` seeds `useState(preloaded)` and
  reassigns from `repo.list()` after each action.
- `SettingsPage` is the **Coordinator** (`HookWidget`, `useProvided`), binding a
  new **View** `SettingsView` (StatelessWidget) that renders the list, empty
  state, and Add button.
- Add/Edit share one form widget; Delete uses an `AlertDialog` in the
  destructive-defaults shape the notebook delete already uses (delete-notebook
  D7, I9).

Token fields are **write-only**: the form shows a masked placeholder reflecting
`hasToken` and never reads the secret (spec FR8). No widget imports the token
store (spec NFR2).

### Changed / new files

| File | Change |
|---|---|---|
| `pubspec.yaml` | `flutter_secure_storage: ^11.2.0` (verify against the ObjectBox/build_runner pins). |
| `macos/Runner/{DebugProfile,Release}.entitlements` | Keychain access or the data-protection-keychain workaround (R2). |
| `ios/Runner/*.entitlements` | New file if the iOS target needs Keychain sharing. |
| `lib/models/ai_endpoint_config.dart` | **new** — `AiEndpointConfig { uuid, label, endpoint, shared, hasToken }`, no Flutter/sync imports. |
| `lib/data/secrets/token_store.dart` | **new** — `TokenStore` interface + `PendingSecret` types. |
| `lib/data/secrets/flutter_secure_token_store.dart` | **new** — the only `flutter_secure_storage` user. |
| `lib/data/objectbox/ob_ai_config.dart` | **new** — entity (I9). |
| `lib/data/ai_config_repository.dart` | **new** — interface (sync-free): `list`, `create`, `update`, `delete`, `refreshTokenFlags`, `reconcile`. |
| `lib/data/objectbox_ai_config_repository.dart` | **new** — impl over `Store` + `TokenStore` + `SyncDeleter`. |
| `lib/data/sync/sync_payload.dart` | `AiConfigDto`; `SyncPayload.aiConfigs`. |
| `lib/data/sync/sync_codec.dart` | Validate config uuids; emit/parse `aiConfigs`. |
| `lib/data/sync/push_sender.dart` | Config selection + `tokens` param; acknowledge configs; async `push` token preload. |
| `lib/data/sync/sync_apply.dart` | `_planConfig`/`_applyConfig`; third delete branch; `pendingSecrets`; async `ingestEncoded`. |
| `lib/data/sync/sync_deleter.dart` | `deleteAiConfigLocally(uuid)`. |
| `lib/domain_mapping.dart` | `ObAiConfig → AiEndpointConfig(hasToken:)`. |
| `lib/bootstrap.dart` | Build token store + config repo; warm flags; reconcile; expose in `BootstrapResult`. |
| `lib/app.dart`, `lib/main.dart` | Pass repo/snapshot; register `AiConfigsState` provider. |
| `lib/state/ai_configs_state.dart`, `lib/state/use_ai_configs_state.dart` | **new**. |
| `lib/pages/settings_page.dart` | Coordinator rewrite. |
| `lib/widgets/settings_view.dart`, `ai_config_form.dart`, `ai_config_tile.dart` | **new** shared components. |
| `lib/objectbox.g.dart`, `lib/objectbox-model.json` | Regenerate (`make codegen`) and commit. |
| `test/…` | See milestones. |
| `docs/settings-conventions.md` (new), `docs/sync-conventions.md` | Document the seam, traps, payload growth. |

---

## Milestones

### M1 — Dependency, token store seam, platform configuration

**Delivers:** `flutter_secure_storage` resolves without disturbing the ObjectBox
pins; `TokenStore` interface + `FlutterSecureTokenStore`; a `FakeTokenStore` for
tests; macOS keychain access configured and verified. **Effort:** Medium.

1. Add `flutter_secure_storage: ^11.2.0`; run `flutter pub get`. **Gate:** it
   adds **no** change to the `objectbox` / `build_runner` resolution — inspect
   `pubspec.lock` and confirm the existing pins are untouched (R1).
2. `lib/data/secrets/token_store.dart`: the interface (I2) and `PendingSecret`.
3. `lib/data/secrets/flutter_secure_token_store.dart`: wraps
   `FlutterSecureStorage`, key `ai_config_token.<uuid>`. Handles the
   `PlatformException` from a locked/unavailable keyring by throwing a typed
   `TokenStoreUnavailableException` (never swallowing it) — this is the FR17
   loud-failure path.
4. macOS: configure keychain. Try the least-privilege option first —
   `MacOsOptions(usesDataProtectionKeychain: false)` — which the plugin documents
   as avoiding `keychain-access-groups` and its provisioning requirement. Add
   the entitlement only if the App Group forces it. Add the same for iOS if the
   target has entitlements.
5. `test/token_store_test.dart` via `FakeTokenStore`: write/read/delete/exists,
   injected failure surfaces, `readAll` round-trip. Also `test/secure_config_purity_test.dart`
   starts here: assert no `lib/models/` or `lib/widgets/`/`lib/pages/` file
   imports `flutter_secure_storage`.

**Gate:** `flutter analyze` clean; `flutter pub get` leaves the ObjectBox pins
intact; the fake-store tests pass; **manual gate** — `flutter run -d macos`, run
a tiny debug probe that writes and reads back a token, and confirm it round-trips.
This is the only way to catch the plugin's silent App-Group no-op (R2); the
automated suite never touches a real keychain.

### M2 — Entity, domain model, repository (CRUD + delete)

**Delivers:** `ObAiConfig`, `AiEndpointConfig`, and a repository that adds,
edits, deletes, tombstones, stores tokens, and lists with a warm `hasToken`.
**Effort:** Medium.

1. `lib/data/objectbox/ob_ai_config.dart` (I9). Run `make codegen`; commit the
   generated files.
2. `lib/models/ai_endpoint_config.dart`: immutable, `const`-friendly, no imports
   beyond `dart:core`. `hasToken` is a plain bool supplied by the repository.
3. `lib/data/ai_config_repository.dart`: interface with
   `List<AiEndpointConfig> list()`, `Future<AiEndpointConfig> create(...)`,
   `Future<void> update(...)`, `Future<void> delete(String uuid)`,
   `Future<void> refreshTokenFlags()`, `Future<void> reconcile()`, and a
   `tokenFor(uuid)` used only by the sync push path.
4. `lib/data/objectbox_ai_config_repository.dart`: the impl. Secret-first ordering
   on write (I4); delete with tombstone in one transaction (I5); maintain
   `_tokenUuids` (I6). Delegate the tombstone/version write to
   `SyncDeleter.deleteAiConfigLocally`.
5. `SyncDeleter.deleteAiConfigLocally` (I5): query the config box, compute
   `nextVersion`, remove + `markDead` in one transaction.
6. `lib/domain_mapping.dart`: `ObAiConfig → AiEndpointConfig(hasToken:)`.
7. Tests (`test/ai_config_repository_test.dart`): create/list/edit/delete
   round-trip; edit with untouched token performs **no** token write (AC6);
   delete writes exactly one tombstone at the next version and removes the secret
   (AC7); a throwing fake token store leaves **no** row and no plaintext (AC14);
   `hasToken` is derived, not stored (AC4); listing performs zero token `read`
   calls (AC16).

**Gate:** AC1–AC7, AC14, AC16 pass.

### M3 — Payload, codec, delta selection, push

**Delivers:** a shared tuple travels in `SyncPayload`; an unshared tuple is
either omitted or sent as a removal; the delta excludes a never-shared tuple.
**Effort:** Medium.

1. `AiConfigDto` + `SyncPayload.aiConfigs` (I7). `fromJson` defaults a missing
   `aiConfigs` to `[]` for forward compatibility; `toJson` always emits it.
2. `sync_codec.dart`: `encodePayload`/`decodePayload` validate config uuids via
   the existing `isValidIdentifier` guard, and never interpolate a token into an
   error string.
3. `push_sender.dart`: config selection + the `sent != null` guard for the
   unshared branch (I7); `selectDelta(peer, {tokens})`; `acknowledge` records the
   metadata counter for configs; `push` preloads tokens (I3).
4. Tests (`test/sync_ai_config_push_test.dart`): shared config with a moved
   version is selected and carries its token; unshared with no prior watermark is
   **absent** (the guard's falsification — removing it fails the test, AC8);
   unshared **after** being shared is present with `shared:false, token:null`;
   re-pushing sends nothing (AC8); encode→decode preserves the token (AC9).

**Gate:** AC8, AC9 pass, including the `sent != null` falsification.

### M4 — Ingest, receive-delete, and convergence

**Delivers:** a receiving device upserts a shared tuple and stores its token;
removes the tuple and token on unshare; removes and tombstones on delete; and two
stores converge. **Effort:** Large.

1. `sync_apply.dart`: `_planConfig`/`_applyConfig` (I8); append `PendingSecret`s
   to `IngestResult`; the third branch in `_applyDelete` (resolve config uuid,
   remove row, `markDead`, schedule `SecretDelete`); make `ingestEncoded` async
   and flush pending secrets via `TokenStore` (I3).
2. Update the six existing `ingestEncoded` call sites in
   `test/sync_apply_test.dart` / `test/sync_push_test.dart` to await.
3. Tests (`test/sync_ai_config_apply_test.dart`): shared upsert creates row +
   token; idempotent at the same version; higher version replaces both; unshare
   removes a receiver's row + token and creates nothing (AC11); re-share at a
   higher version re-creates it; a `DeleteDto` for a config removes + tombstones
   and a later higher-version `AiConfigDto` is refused (AC12, reusing the
   `isDead` falsification convention); delete for an unknown config uuid is a
   no-op + tombstone (AC13).
4. `test/sync_ai_config_convergence_test.dart`: extend the two-store harness —
   share, converge (row + token); unshare, converge (receiver clear, sender
   still holds its row); delete, converge (both clear, uuid tombstoned) (AC24).

**Gate:** AC10–AC13, AC24 pass.

### M5 — Bootstrap, global state, dependency plumbing

**Delivers:** the token store, config repo, and initial snapshot are built before
`runApp`; `AiConfigsState` is globally provided. **Effort:** Medium.

1. `bootstrap.dart`: construct `FlutterSecureTokenStore` and
   `ObjectBoxAiConfigRepository` over the already-opened store; `await
   refreshTokenFlags()`; `await reconcile()`; add `aiConfigs` and
   `initialAiConfigs` to `BootstrapResult`. Do this before `runApp` so the first
   frame has `hasToken` without an async hook (Directive 6 / spec bootstrap
   pattern).
2. `app.dart`: accept the repo/snapshot; register `AiConfigsState` in
   `HookProviderContainerWidget`.
3. `main.dart`: pass the new fields through.
4. `state/ai_configs_state.dart` + `use_ai_configs_state.dart` (I10).
5. Tests (`test/bootstrap_seed_test.dart` extension or new
   `test/ai_config_bootstrap_test.dart`): the injected-fake path builds a repo
   with warmed flags and does not open a real keychain; the reconcile step is
   idempotent and removes an orphan secret (AC15).

**Gate:** AC15 passes; app starts with `AiConfigsState` provided.

### M6 — Settings UI

**Delivers:** the list, add/edit form, permanent-delete confirmation, empty
state, and accessibility. **Effort:** Medium.

1. `lib/widgets/settings_view.dart` (StatelessWidget): renders configs (label,
   endpoint, shared indicator, `hasToken` indicator), the empty state, and Add.
2. `lib/widgets/ai_config_form.dart`: one form for add/edit; validates a
   non-empty label and an absolute `http`/`https` endpoint (FR21); token field is
   write-only and masked (FR8); share toggle.
3. `lib/widgets/ai_config_tile.dart`: row + edit/delete affordances.
4. `lib/pages/settings_page.dart`: Coordinator (`HookWidget`,
   `useProvided<AiConfigsState>()`); handles navigation, async errors via
   `SnackBar`, and the delete `AlertDialog` naming the tuple and stating
   permanence + peer removal (FR19).
5. Tests (`test/settings_page_test.dart`): list + empty state + Add (AC17);
   validation blocks empty label / non-URL endpoint, token optional (AC18);
   delete modal content and that every dismissal path writes nothing (AC19);
   keyboard operation and `Escape` (AC20); the extended purity test confirms no
   UI file imports the token store or `lib/data/sync/` (AC21).

**Gate:** AC17–AC21 pass.

### M7 — Conventions docs

**Delivers:** the prose matches the code. **Effort:** Small.

1. `docs/settings-conventions.md` (new): the token-store seam, the secret-first
   write order and why, the `hasToken` cache, boot reconciliation, and the
   no-plaintext-fallback rule.
2. `docs/sync-conventions.md`: the payload now carries a fifth entity type with
   no relation sites; record the **applied / refused / unshared / deleted** four-way
   distinction, and that a config delete is an ordinary `DeleteDto`.
3. Note the macOS Keychain/App-Group trap in `docs/desktop-build.md` or the new
   doc, so the next secret-backed feature does not re-discover it.

**Gate:** no doc still says the payload carries only notebooks, publications,
documents, chunks, and deletes.

---

## Dependencies

- **New external dependency:** `flutter_secure_storage: ^11.2.0` (federated
  platform packages included). Must be verified not to disturb the load-bearing
  ObjectBox / `build_runner` pins (`docs/data-conventions.md`). Unlike `uuid`,
  this one **does** add transitive packages; that is unavoidable for a keychain
  abstraction and is the whole point of the feature.
- **Platform host deps:** macOS/iOS Keychain (no package install); Linux needs
  `libsecret-1-dev` to build and `libsecret-1-0` + a keyring to run (CI/headless
  would need `gnome-keyring-daemon`). Tests never need any of it — they use the
  fake.
- **Internal:** M1 → M2 → M3 → M4 → M5 → M6 → M7. M2 needs M1's `TokenStore`;
  M3/M4 need M2's entity; M5 needs M4; M6 needs M5. M3 and M4 both edit
  `sync_payload`/`sync_apply`, so they are sequential, not parallel.
- **Not blocked on the transport.** Everything except actually delivering a
  token over a network is in scope and testable in-process. The spec's FR15 gate
  is respected: no transport is built, and the shared-token path is exercised
  only through `encodePayload`/`ingestEncoded` in tests.

## Risks & Mitigations

| # | Risk | Mitigation |
|---|---|---|
| **R1** | `flutter_secure_storage` pulls an `analyzer`/`build_runner` constraint that breaks the ObjectBox codegen pin. | M1 gate: `flutter pub get` + `make codegen` + `flutter analyze` all green, and diff `pubspec.lock` to confirm the ObjectBox packages are unchanged. If it conflicts, pin a lower major and re-verify; do **not** widen `build_runner`. |
| **R2** | **macOS token writes silently no-op** because the app uses an App Group but `keychain-access-groups` omits it. The plugin's README calls this out explicitly: values "appear to be written successfully but never actually being written at all". | M1 tries `usesDataProtectionKeychain: false` first (avoids the entitlement and its provisioning cost); otherwise add `$(AppIdentifierPrefix)group.mln.lnb` to `keychain-access-groups`. **Manual gate on a real macOS run** is mandatory — the automated suite cannot catch it. A structural test asserts the chosen option is actually configured. |
| **R3** | A token leaks into a log, an exception string, or ObjectBox. | FR2/FR6 tests: a sentinel token is dumped out of every `ObAiConfig` property and asserted absent; codec error strings are asserted not to contain it; the only type allowed to import `flutter_secure_storage` is the token-store impl (purity test). |
| **R4** | The async split (I3) lets a caller ingest rows and drop the secrets. | The public receive entry point is `ingestEncoded`, which flushes; the low-level `ingest` is documented as rows-only. AC11/AC12 assert a token lands and an unshared token is removed, so a dropped flush fails. |
| **R5** | The unshare branch is wrong — either never sent (peer keeps a private tuple) or always sent (every private tuple travels). | The `sent != null` guard (I7) plus a falsification test: removing the guard makes the never-shared-tuple test fail (AC8). The reverse (guard too strict) is covered by the shared-then-unshared test (AC11). |
| **R6** | `hasToken` reads blow the keychain budget or prompt on every list rebuild. | The cache is warmed once at boot and updated on writes; `list()` touches no token API (AC16). The macOS prompt question is an Open Question, not silently assumed away. |
| **R7** | The config entity is added to a payload whose tests assume exactly four entity types. | `fromJson` defaults missing `aiConfigs` to `[]`, so old payload literals still parse; M3/M4 extend `sync_test_fixtures.dart` `storeSnapshot` with a config section so convergence compares it. |
| **R8** | Boot reconciliation decrypts every secret (`readAll`) and is slow or prompts. | It is boot-time and bounded; the design and its cost are recorded, and avoiding it via a non-secret pending-delete ledger is an explicit Open Question. |
| **R9** | The delete `NextVersion`/tombstone path diverges from the proven notebook path. | Reuse `TombstoneStore.markDead` and `nextVersion` verbatim, and put the write in `SyncDeleter` beside the existing deletes so there is one shape. |

## Verification

- `make analyze` and `make test` after every milestone. `make codegen` is run in
  M2 and its output committed.
- **Falsification tests, run with the guard removed to confirm they fail:** the
  never-shared-selection guard (R5/AC8); the `isDead`-without-version rule for
  config tombstones (AC12, same convention as peer-sync AC10).
- **Manual gates the suite cannot cover:** (a) a real macOS run writing and
  reading a token (R2); (b) confirming a token survives an app restart and that
  the Settings list shows it as present without reading it (FR18). Recorded in
  `test/secure_config_purity_test.dart`'s "manual gate" group, mirroring
  `test/production_store_config_test.dart`.
- Acceptance gate: the spec's AC1–AC24.

## Open Questions carried forward

From the spec, none of which this plan can settle:

- **Transport security (blocking the actual sharing of tokens).** Unchanged from
  the spec: the payload is plaintext and no transport exists, so FR15's gate
  stands. This plan implements and tests the payload path only.
- **Keychain prompting on macOS.** Whether `exists()`/`readAll()` prompt for this
  app's own items, and whether a non-secret "has a token" hint is worth its small
  information leak to avoid a prompt, is unresolved.
- **Token scope/rotation.** A tuple holds one opaque token; refresh/expiry is
  left to the future AI feature.
- **Orphan-secret cleanup without `readAll`.** A non-secret pending-delete ledger
  in ObjectBox would avoid decrypting all secrets at boot; richer than this
  feature needs today.
