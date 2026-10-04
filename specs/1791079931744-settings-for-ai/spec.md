# Feature: AI Settings — OpenAI-Compatible Endpoints

**Spec directory:** `1791079931744-settings-for-ai`
**Feature name:** `settings-for-ai`
**Builds on:** [`1790958509972-publication-data-layer`](../1790958509972-publication-data-layer/) (transactions, invariants), [`1790968315311-peer-sync`](../1790968315311-peer-sync/) (payload, DTOs, versions, tombstones, delta selection, ingest), and [`1791055194089-delete-notebooks`](../1791055194089-delete-notebooks/) (permanent delete, confirmation modal, tombstone-on-delete).
**Amends:** peer-sync by extending the payload with a new record type and a new syncable entity — see [Amendments to prior specs](#amendments-to-prior-specs). The sync surface grows here deliberately; peer-sync NFR6 (delete-notebooks) is scoped to that feature, not to this one.
**Status:** the Settings destination is currently a `PlaceholderBody` (`lib/pages/settings_page.dart`). This spec gives it its first real content.

## Context

The Settings page exists only as a placeholder. The product needs AI features
eventually, and every one of them needs a place to point: an OpenAI-compatible
`/chat/completions` and `/embeddings` endpoint, a token, and — because a person
owns several devices — a decision about whether that configuration should travel
to their other devices.

This spec builds **the settings surface and the storage/sync substrate for those
configurations**, not the AI features that consume them. It answers three
questions the rest of the app will depend on: where a secret lives, how a secret
is kept out of the widget layer, and how a configuration is shared without
leaking a secret to a peer that was not meant to receive it.

Three facts about the existing codebase shape the design:

1. **Secrets are the whole point of the storage layer.** An OpenAI-compatible
   token is a bearer credential: anyone holding it can spend the user's quota and
   read the user's data. The existing ObjectBox store is a plain file on disk,
   unencrypted; `shared_preferences` is plaintext. Neither may hold a token.

2. **Sync is a uuid-and-version, tombstone-based, last-write-wins protocol**
   (`lib/data/sync/`). A configuration that is "shared with another device" is a
   syncable record like any other: it needs a `@Unique()` uuid, a
   `versionCounter`, a place in the payload, and a tombstone when it dies. It is
   not a special channel.

3. **There is still no transport, no pairing, and no encryption** (peer-sync
   D11, docs/sync-conventions.md). Sharing a *token* — not merely a URL — changes
   what that omission costs, and this spec names the consequence rather than
   hiding it.

The decision that shapes everything: **the token is stored where the platform
keeps secrets, is never read back into a widget, and is never placed on the wire
unless the tuple is explicitly marked shareable — and even then only over a
channel this app does not yet have.**

## Goals

- Give Settings a working page that lists AI endpoint configurations.
- Let a user add, edit, and delete a configuration (label, endpoint, token,
  share flag).
- Store the token with the **best secret storage each platform offers** —
  Keychain, Keystore, Credential Manager, libsecret — and never in plaintext,
  ever, including as a fallback.
- Keep the token out of the domain model and out of the widget layer entirely;
  the UI can learn *that* a token is set, never what it is.
- Make a configuration a first-class syncable record so a flagged tuple reaches a
  peer's own other devices through the existing payload.
- Make deletion permanent and confirmed, with a tombstone so a stale push cannot
  resurrect it.
- Preserve every existing invariant: no sync vocabulary in `lib/models/`, no
  plaintext secret, transactional writes, in-process testability.

## Non-Goals

- **No AI features.** No chat, no completion, no embedding call, no model
  picker. This spec stores and manages configurations; it does not use them.
- **No transport, pairing, or encryption design.** Sharing a tuple is defined at
  the payload level and is fully testable in-process. The actual delivery of a
  token over a network is blocked on the transport peer-sync left undecided
  (D11); see FR15 and the Open Questions.
- **No web target.** Desktop and mobile only, as stated. Web has no OS keychain
  and no build target here.
- **No import/export, backup, or file round-trip of configurations.**
- **No soft delete, trash, or undo.** Deletion is permanent.
- **No per-configuration model selection, temperature, or any request
  parameter.** Endpoint, token, label, share flag. Nothing else.
- **No credential validation against the endpoint** (a "test connection"
  button). Whether to add one is an Open Question.
- **No encryption of the ObjectBox store.** The non-secret fields stay readable;
  only the token is secret. Encrypting the whole store is a different decision.
- **No multi-user or shared-vault model.** One install, one set of
  configurations.

## Definitions

- **Tuple** — one AI endpoint configuration: a label, an endpoint URL, a token,
  and a share flag. Addressed by a `@Unique()` uuid.
- **Secret** — the token. The only field in the tuple that must never be
  plaintext at rest or exposed to the widget layer.
- **Metadata** — everything in a tuple *except* the token: uuid, label,
  endpoint, share flag, version. Non-secret; lives in ObjectBox; travels in a
  payload.
- **Shared tuple** — a tuple whose share flag is on. It may travel to a peer.
- **Unshared tuple** — a tuple whose share flag is off. It never appears in a
  payload. Turning a tuple unshared must *remove* it from peers, not merely stop
  updating them (FR13).
- **Token store** — the `flutter_secure_storage`-backed component that holds
  tokens, keyed by tuple uuid. The only path to a secret.
- **Key** — the token store key for a tuple, `ai_config_token.<uuid>`. Derived
  from the uuid so the store needs no separate index.

---

## Requirements

### The tuple and its storage

- **FR1 — A configuration is an entity with a uuid and a version.** It is stored
  as `ObAiConfig` with a `@Unique() String uuid`, a `@Index() int versionCounter`,
  a `String label`, a `String endpoint`, a `bool shared`, and a
  `@Property(type: PropertyType.dateUtc) DateTime createdAt`. It mirrors
  `ObNotebook`: uuid is the application identity, the int id never leaves the
  data layer, and `versionCounter` is half of its last-write-wins version
  (peer-sync FR9, FR10).

- **FR2 — The token is not a column on the entity.** No `token`, `secret`,
  `apiKey`, or equivalent property exists on `ObAiConfig`, and the token is never
  written to ObjectBox, `shared_preferences`, a log, or any other plaintext
  store. A test asserts the entity type has no string property whose name or
  value could be a secret.

- **FR3 — The token lives in the platform secret store, keyed by uuid.** The
  token store wraps `flutter_secure_storage`, which resolves to the best
  available mechanism per target:

  | Platform | Mechanism |
  |---|---|
  | iOS | Keychain (`kSecClassGenericPassword`) |
  | Android | Keystore-backed `EncryptedSharedPreferences` |
  | macOS | Keychain |
  | Windows | Credential Manager / DPAPI |
  | Linux | libsecret (GNOME Keyring / KWallet) |

  No other storage location for the token is permitted, and there is **no
  plaintext fallback** (FR17).

- **FR4 — The token store exposes no read path to the UI.** Its API is
  `write(uuid, token)`, `delete(uuid)`, `exists(uuid)`, and an internal
  `read(uuid)` that only the data/sync layer may call. The domain model and every
  widget see `hasToken: bool` and nothing more.

- **FR5 — The domain model carries no secret.** `lib/models/` gains an immutable
  `AiEndpointConfig { uuid, label, endpoint, shared, hasToken }` with no token
  field and no Flutter imports. `hasToken` is a boolean derived at read time from
  the token store; it is not a stored column.

- **FR6 — The secret is never logged.** No `slog`-equivalent, `debugPrint`, error
  message, or exception string interpolates a token. A malformed token is
  reported by uuid and by "token is invalid", never by value. A test scans for a
  sentinel token appearing in captured output.

### CRUD

- **FR7 — Add.** The Settings page offers an add action opening a form with a
  required label, a required endpoint, an optional token, and a share toggle.
  Saving mints a uuid (`newUuidV7()`), writes the metadata row with
  `versionCounter: 1`, and writes the token (if any) to the token store under
  that uuid.

- **FR8 — Edit.** Opening an existing tuple populates the form with its label,
  endpoint, and share flag. The token field renders as a **masked placeholder**
  that reveals only whether a token is set; it is never populated with the
  secret. Leaving it untouched preserves the stored token (no write). Entering a
  new value **replaces** the token and bumps the version. Clearing it explicitly
  (a defined "remove token" affordance) deletes the secret and bumps the version.

- **FR9 — Delete is permanent, confirmed, and atomic-with-its-tombstone.**
  Deleting a tuple removes the `ObAiConfig` row and its token-store entry, and
  writes a tombstone for the uuid — all committed together. No soft-delete flag,
  no trash row, no undo record exists. A confirmation modal gates the action
  (FR18).

- **FR10 — Sharing is a property of the tuple, not a separate object.** The
  share flag is edited on the tuple itself. There is no "public profile" or
  second registry; toggling it changes how the existing tuple is selected into
  payloads.

### Sync

- **FR11 — A shared tuple travels as a new record type.** `SyncPayload` gains
  `aiConfigs: List<AiConfigDto>`. `AiConfigDto` carries
  `{ uuid, label, endpoint, shared, token?, version }`, where `token` is present
  **only when the record is shared** (FR13). The version uses the existing
  `VersionDto` and `(counter, deviceId)` scheme; no new versioning concept is
  introduced.

- **FR12 — Only shared tuples are selected into a delta.** `PushSender.selectDelta`
  includes an `ObAiConfig` only when `shared == true` and its `versionCounter`
  has moved past the peer's watermark on the metadata axis. An unshared tuple is
  invisible to the push path. The selection is testable in-process against two
  stores, exactly like a notebook or publication delta.

- **FR13 — Turning sharing off removes the tuple from peers; it does not update
  it.** A tuple whose `shared` flag is off is **never** upserted on a receiver.
  On receiving an `AiConfigDto` with `shared == false`, the receiver removes any
  local `ObAiConfig` row and token for that uuid and does **not** write the
  incoming record. This is the unshare path, and it is distinct from a delete:
  the sender's row is still alive and may be re-shared later. A re-share sends a
  record with a higher version and re-creates the receiver's copy.

  Why this rather than a tombstone: a tombstone means "dead forever until purge"
  (peer-sync FR14), but an unshared tuple is not dead — it is private. Writing a
  tombstone on unshare would make the uuid permanently unresurrectable and break
  re-sharing, which is a supported action.

- **FR14 — A deleted tuple travels as an ordinary delete record and is
  tombstoned.** Deleting a shared tuple writes an `ObTombstone` (peer-sync
  FR12–FR15) whose version is the death version, and the existing delta selects
  it as a `DeleteDto { uuid, version }`. The receiver resolves the uuid against
  the `ObAiConfig` box, removes the row and its token if present, and tombstones
  the uuid. A tuple that was never shared is tombstones locally too — an
  in-flight push must not resurrect it (peer-sync FR14 has to hold for records a
  peer never had).

- **FR15 — A payload carrying a token is not deliverable until the transport is
  encrypted, and this spec does not build the transport.** The peer-sync payload
  is plaintext JSON (peer-sync FR5c, docs/sync-conventions.md), and a token in it
  is a bearer credential. Selecting a shared tuple into `SyncPayload` and
  ingesting one are fully specified and tested in-process. Actually delivering a
  payload that contains a token is gated on an authenticated, encrypted transport
  that does not exist yet. Until it does, the app **must not** wire a shared
  tuple's token to any real network call. This is a hard dependency, not a
  nicety — see the Open Questions.

- **FR16 — Ingest of a config is one transaction per record.** Applying an
  `AiConfigDto` writes at most one `ObAiConfig` row (plus its token) or removes
  one; a failure rolls it back entirely. A tombstoned uuid refuses a later
  `AiConfigDto` with a strictly higher version, by the same `isDead` rule as any
  other record and with no version comparison in the dead branch (peer-sync
  FR14). An incoming shared record's token is written to the token store; an
  incoming unshared record has none and any held token is deleted (FR13).

### Security and failure

- **FR17 — No plaintext fallback, and no silent degradation.** If the platform
  secret store is unavailable (Linux without a running keyring, a macOS build
  missing its Keychain entitlement, a locked Keychain), saving a tuple that has a
  token **fails loudly** and writes no metadata row. The app must never write the
  token to ObjectBox, `shared_preferences`, a temp file, or memory that outlives
  the save. A configuration that cannot have its secret stored is not saved.

- **FR18 — Secret write and metadata write are reconciled at boot.** ObjectBox
  and the token store cannot be committed in one transaction. On boot, a
  reconciliation sweep removes token-store entries whose uuid has no
  `ObAiConfig` row (orphaned secrets), and marks a row whose `shared`/`hasToken`
  state disagrees with the token store so the UI can prompt for re-entry.
  A token is never reported present when it is absent.

- **FR19 — The confirmation modal is permanent-delete scoped.** Activating
  Delete opens a modal naming the tuple, stating the deletion is permanent, and
  warning that a shared tuple is also removed from the user's other devices.
  Confirm is visually destructive; Cancel is the default. Dismissing by Cancel,
  scrim, `Escape`, or the platform back affordance changes nothing.

### UI

- **FR20 — Settings lists the configurations.** The page renders `AiEndpointConfig`
  rows: label, endpoint, a "shared" indicator, and edit/delete affordances. An
  empty state explains there are none and offers Add. A per-row indicator
  distinguishes a tuple with a token from one without (`hasToken`), never the
  token itself.

- **FR21 — The form validates before it saves.** Label must be non-empty;
  endpoint must parse as an absolute `http`/`https` URL. Token is optional (some
  local, OpenAI-compatible servers require none). Invalid input is shown inline
  and blocks saving. Label and endpoint are not required to be unique — the uuid
  is the identity.

- **FR22 — Accessibility.** Add, edit, and delete controls are keyboard
  reachable with accessible labels; the form and the confirmation modal are
  keyboard-operable, focus a control on open, and do not trap focus.

### Non-Functional Requirements

- **NFR1 — The domain layer stays sync-free.** No type under `lib/models/`
  references a sync concept (`SyncDto`, tombstone, watermark, device id) —
  peer-sync NFR2. `AiEndpointConfig.shared` is a product concept ("share with my
  other devices"), and it is the *only* sharing vocabulary the domain learns;
  it is not a protocol type. Verified by the existing import/type test, extended
  to the new model.

- **NFR2 — The token never enters `lib/models/`, a widget, or the sync DTO
  constructor from the UI.** The UI produces a `save(label, endpoint, token?,
  shared)` intent; the data layer is what reads and writes the secret. No widget
  imports `flutter_secure_storage`.

- **NFR3 — Convergence is testable in-process.** Two in-memory ObjectBox stores
  plus an in-memory fake token store exercise add, share, edit, unshare, delete,
  and convergence with no network, emulator, or fixtures (peer-sync NFR4). The
  token store is an interface so tests inject a fake and never touch a real
  keychain.

- **NFR4 — Reads and writes are transactional where they touch ObjectBox.** The
  metadata write and the tombstone write on delete share one `runInTransaction`
  (peer-sync FR17, delete-notebooks FR5). The token write is outside the
  transaction and is reconciled per FR18; this is stated because it is the one
  non-atomic seam in the feature.

- **NFR5 — No secret in crash reports, assertions, or the sync codec's error
  strings.** `SyncPayloadException` names a field position, never a value
  (peer-sync FR5c already does this for vectors).

- **NFR6 — The tuple list is bounded and cheap.** Listing configurations never
  reads tokens — `exists()` only, or a cached boolean — so opening Settings does
  not unlock the keychain once per row. On platforms where each keychain read is
  a prompt, this is the difference between a usable page and a hostile one.

---

## Acceptance Criteria

- [ ] **AC1:** `ObAiConfig` has a `@Unique()` uuid and an indexed `versionCounter`; a deliberate duplicate `put` throws `UniqueViolationException`.
- [ ] **AC2:** `ObAiConfig` exposes no property holding a token; a schema/type test fails if a `token`/`secret`/`apiKey` property is added (FR2).
- [ ] **AC3:** Saving a tuple with a token writes the token to the injected token store and writes **no** token value anywhere in ObjectBox; dumping every ObjectBox property of the row does not contain the sentinel token.
- [ ] **AC4:** `AiEndpointConfig` (the domain type) has no token field; `hasToken` is true iff the token store holds a key for the uuid.
- [ ] **AC5:** Add, edit, and delete each round-trip through Settings: add appears in the list; edit changes label/endpoint/shared and preserves an untouched token; delete removes the row and the secret and writes a tombstone.
- [ ] **AC6:** Editing a token writes the new value; leaving the field untouched performs no token write and does not change the stored secret (asserted by reading the fake store).
- [ ] **AC7:** Deleting a tuple writes exactly one tombstone whose version is `nextVersion(previous, deviceId)` and removes the secret in the same operation (FR9, FR14).
- [ ] **AC8:** `selectDelta` includes a shared tuple with a moved version and **excludes** an unshared tuple with an arbitrary version. Re-pushing an unchanged shared tuple sends nothing (peer-sync AC5).
- [ ] **AC9:** A `SyncPayload` carrying a shared tuple encodes and decodes losslessly, token included, and the token is base64/opaque only in that a decode returns the same value — the DTO's `token` is null for an unshared record (FR11, FR13).
- [ ] **AC10:** Ingesting a shared tuple creates the row and the receiver's token; re-ingesting the same version leaves the stored state (row values and token) unchanged; a higher version replaces both. Idempotency is measured by unchanged state, not by an operation counter — the receiver stores counters only and reconstructs the `deviceId` half, so an equal counter can be re-applied with identical values (the same property peer-sync AC11 relies on).
- [ ] **AC11:** Ingesting an unshared `AiConfigDto` removes a receiver's existing row and token for that uuid and creates nothing; re-sharing with a higher version re-creates it (FR13).
- [ ] **AC12:** A delete record for a shared tuple removes the receiver's row and token and tombstones the uuid; a later `AiConfigDto` for the same uuid with a higher version is refused (FR14, FR16, peer-sync AC10).
- [ ] **AC13:** A delete for a tuple the receiver never had is a no-op that still writes the tombstone and applies without error (peer-sync AC9).
- [ ] **AC14:** On a token-store failure, saving a tuple with a token throws and writes **no** `ObAiConfig` row and no plaintext token anywhere (FR17).
- [ ] **AC15:** The boot reconciliation removes a token-store entry with no matching row and reports a row whose secret is missing rather than claiming `hasToken` (FR18).
- [ ] **AC16:** Opening Settings performs no per-row full token read; a fake token store counts `read` calls and asserts zero during a list (NFR6).
- [ ] **AC17:** The Settings page lists tuples with label, endpoint, and a shared indicator; the empty state renders when there are none; Add creates one (FR20).
- [ ] **AC18:** The form blocks an empty label and a non-URL endpoint; token is optional; a saved tuple with no token reports `hasToken == false` and one with a token reports `true` (FR21).
- [ ] **AC19:** The delete affordance opens a modal naming the tuple and stating permanence and peer removal; confirming deletes, and every dismissal path changes nothing (FR19).
- [ ] **AC20:** Add, edit, delete, the form, and the modal are keyboard operable with accessible labels; the modal does not trap focus and is dismissed by `Escape` (FR22).
- [ ] **AC21:** No `lib/models/` type references a sync concept (existing test extended); no widget imports `lib/data/sync/` or `flutter_secure_storage` (NFR1, NFR2).
- [ ] **AC22:** A sentinel token never appears in logs, exception strings, or debug output during add/edit/delete/share/ingest (FR6, NFR5).
- [ ] **AC23:** Every test runs against in-memory stores and a fake token store in a plain `flutter test` on the host; no keychain, network, emulator, or fixture file is used (NFR3).
- [ ] **AC24:** A shared tuple and an unshared tuple converge across two stores: after the share, both hold the row and token; after the unshare, the receiver holds neither while the sender still holds its row; after a delete, both hold neither and the uuid is tombstoned.

---

## Resolved Decisions

| # | Question | Resolution | Why |
|---|---|---|---|
| **D1** | Where does the token live? | **Platform secret store via `flutter_secure_storage`; never ObjectBox.** | A token is a bearer credential and ObjectBox is an unencrypted file. The OS keychain/keystore is the best security each target offers, and using it removes an entire class of bug (a secret in a backup, a dump, or a sync payload field). |
| **D2** | Entity column, or separate store keyed by uuid? | **Separate store; metadata in ObjectBox.** | Sync operates on ObjectBox rows, and the metadata must be queryable and versioned. The token must not be. Splitting them lets each live where it belongs, at the cost of one reconciliation rule (FR18) rather than a plaintext secret. |
| **D3** | Does the UI ever see the token? | **No — `hasToken` only; masked, write-only replacement.** | A widget tree is the least defensible place for a secret: it is rebuilt, logged, and inspectable. Write-only replacement is enough to change a token and removes any read path to the UI. |
| **D4** | Is the token required? | **Optional.** | OpenAI-compatible covers local servers (e.g. Ollama, LM Studio, llama.cpp) that accept no token. Requiring one would exclude them; the tuple is still meaningful without it. |
| **D5** | Is the tuple's identity its label, endpoint, or a uuid? | **A uuid; label required but not unique.** | Two tuples may legitimately point at the same endpoint with different tokens or labels; making the endpoint the key forbids that. The uuid also gives sync a stable identity, matching every other syncable record. |
| **D6** | Does sharing use the existing payload? | **Yes — a new `AiConfigDto` in `SyncPayload`.** | Everything the protocol needs already exists: uuid identity, `(counter, deviceId)` versions, per-record watermarks, tombstones, typeless deletes. A second channel would duplicate all of it and re-learn every trap in docs/sync-conventions.md. |
| **D7** | What happens when sharing is turned off? | **The receiver removes its copy; no tombstone is written.** | An unshared tuple is private, not dead. A tombstone would make the uuid permanently unresurrectable (peer-sync FR14) and break re-sharing, which is a supported action. Sending `shared: false` expresses "not for you" without claiming death. |
| **D8** | Does deleting an unshared tuple still tombstone? | **Yes.** | Without a tombstone an in-flight push could resurrect a tuple the user deleted. peer-sync FR14 must hold for records a peer never had; the local tombstone is what makes that true after a delete. |
| **D9** | Are untrusted peers a problem introduced here? | **Not resolved here; named.** | peer-sync D11 left transport security open under the assumption that only metadata crossed the wire. A shared tuple carries a *secret*, so the assumption is no longer sufficient, and FR15 gates delivery on an encrypted transport rather than pretending it exists. |
| **D10** | Does the domain learn "sync"? | **No — only `shared`.** | `shared` is a product concept the user sets on a tuple; tombstones, watermarks, and device ids stay in `lib/data/sync/` (peer-sync NFR2). The import test guards the line. |
| **D11** | Encrypt the ObjectBox store? | **No — out of scope.** | Only the token is secret and it is not in ObjectBox. Encrypting the store is a separate, store-wide decision with its own migration and key-management questions. |
| **D12** | Where is the delete confirmation? | **A modal on the Settings row.** | The operation is permanent and, for a shared tuple, affects other devices; the confirm dialog is where that consequence is made visible before committing (delete-notebooks D7). |

---

## Open Questions

- **Transport security and pairing (blocking FR15).** The feature's own goal —
  sharing a token with another device — cannot be satisfied over the plaintext
  payload peer-sync left undecided. Whether the transport is TLS with pinned
  identity, a shared secret, or something else is a peer-sync-level decision that
  this spec depends on and does not make. Until it lands, sharing is a stored
  preference with no safe delivery vehicle.
- **Token scope and rotation.** A single token per tuple assumes the endpoint's
  token is stable. Some providers issue short-lived tokens; whether the app
  should prompt, refresh, or store an expiry is undecided.
- **A "test connection" action.** Not in this spec. Whether the Settings page
  should validate a tuple against its endpoint before saving is a product
  decision, and it would require the AI-call path this spec excludes.
- **Which HTTP header/format the token uses.** OpenAI-compatible is a
  well-understood convention (`Authorization: Bearer …`), but the consuming
  feature is out of scope here; the token is stored opaquely. A future AI spec
  owns the request format.
- **Secret-store behaviour on Linux without a keyring.** The defined response is
  a loud failure (FR17). Whether the app should instead warn and offer a
  session-only (in-memory) mode is undecided.
- **Per-row `hasToken` cost on macOS.** Whether `exists()` itself triggers a
  Keychain prompt on some macOS configurations, and whether a cached, non-secret
  boolean should be persisted to avoid it, is an implementation question with a
  security trade-off (a "has a token" bit leaks a tiny fact at rest).

---

## Amendments to prior specs

This feature deliberately grows the peer-sync protocol. Per the root-cause rule
in `AGENTS.md`, the changes are stated here rather than absorbed silently.

### peer-sync payload and ingest

`SyncPayload` gains `aiConfigs`. A new `AiConfigDto` is a **sixth** entity type
crossing the wire, alongside notebooks, publications, documents, chunks, and
deletes. Ingest gains one transaction-per-config rule (FR16) and the
shared/unshared semantics of FR13, which have no precedent in the existing
protocol: every prior record type was either applied or refused, never
"applied as a removal because a flag is off."

### peer-sync "no clocks" and watermark

Unchanged in substance and extended in scope: an `ObAiConfig` uses the same
`versionCounter` and the same per-record, per-axis watermark, on the metadata
axis only. No new axis is introduced.

### Documentation to follow (implementation phase)

- `docs/sync-conventions.md` — the payload section and the "seven reference
  sites" framing assume the four synced entities; a shared tuple adds a fifth
  entity with **no** relation sites, and the deleted/refused/applied/unshared
  distinction needs recording.
- `docs/data-conventions.md` — if it enumerates entities, add `ObAiConfig` and
  state the token-store split.
- A new `docs/settings-conventions.md` (or a section) should record the
  token-store seam, the boot reconciliation rule, and the no-plaintext-fallback
  rule, since those are the traps a future change is most likely to reintroduce.
