# Settings conventions — AI endpoints and the secret seam

How AI endpoint configurations are stored, how the token is kept out of the app
database, and where the arrangements are fragile. This governs
`lib/data/secrets/`, `lib/data/ai_config_repository.dart`, and the Settings page.

Read [`sync-conventions.md`](./sync-conventions.md) too: a shared configuration
is a sync record like any other.

## The split: metadata in ObjectBox, the token in the keychain

A tuple is two things in two stores:

| Part | Where | Why |
|---|---|---|
| uuid, label, endpoint, share flag, version | `ObAiConfig` (ObjectBox) | queryable, versioned, and synced like any record |
| the token | `flutter_secure_storage` under `ai_config_token.<uuid>` | ObjectBox is an unencrypted file on disk |

`ObAiConfig` has **no token column**, and a test asserts none exists
(`test/secure_config_purity_test.dart`). The domain model and every widget see
`hasToken: bool` and never the secret. `flutter_secure_storage` is imported by
exactly one file, `lib/data/secrets/flutter_secure_token_store.dart`; a test
fails if any other file imports it.

## Ordering, because two stores cannot share a transaction

ObjectBox transactions are synchronous; the keychain is asynchronous. They will
never be atomic, so the order is the safety mechanism:

- **Create / edit:** write the secret **first**, then the row. A keychain
  failure throws before any row exists, so there is never a tuple whose token
  silently failed to store. The reverse order leaves a row with a missing
  secret.
- **Delete:** the row and its tombstone commit together in one transaction, then
  the secret is removed. A crash between the two leaves an **orphan secret**,
  which boot reconciliation removes.
- **Boot:** `reconcile()` lists the token keys and deletes any with no matching
  row, then `refreshTokenFlags()` rebuilds the in-memory `hasToken` set.

`reconcile()` uses `readAll()`, which decrypts values, because the platform
exposes no key-only enumeration. It runs once at boot and is bounded.

**Enumeration is not available on every platform.** The macOS **legacy** keychain
(what this app uses, via `usesDataProtectionKeychain: false`) rejects
`kSecMatchLimitAll` with `errSecParam` (`-50`) — a well-known limitation of the
non-data-protection keychain. Orphan cleanup is therefore **best-effort**: a
failure to enumerate is swallowed, the boot continues, and `refreshTokenFlags`
still runs (single-item `exists` queries work fine). The cost is a small, bounded
orphan-secret leak on macOS only, and `hasToken` can never lie because it is
re-read from the store every boot. A non-secret pending-delete ledger would
avoid the need to enumerate at all.

## `hasToken` is a cache, not a column

The Settings list must show whether a token is set without reading it, and
reading a secret per row would touch the keychain on every rebuild. So the
repository keeps a `Set<String> _tokenUuids`:

- warmed once at boot by `refreshTokenFlags()` (one `exists` per tuple, no read),
- updated on create/edit/delete,
- consulted by `list()`.

`list()` performs **zero** token reads or `exists` calls; a test asserts that. A
row whose secret has vanished reports `hasToken == false`, because the flag is
derived from the store every boot rather than persisted.

## No plaintext fallback

If the platform secret store is unavailable — a locked keyring, a missing macOS
Keychain entitlement, libsecret not running — `FlutterSecureTokenStore` throws
`TokenStoreUnavailableException`. The save path then **fails loudly** and writes
no row. There is no fallback to ObjectBox, `shared_preferences`, or a file,
ever.

## macOS: the App-Group Keychain trap

**The plugin's documented failure mode is silent.** If an app uses an App Group
and the data-protection keychain is enabled without listing that group in
`keychain-access-groups`, writes *appear to succeed and never land* — the value
reads back null later.

This app carries `group.mln.lnb` for ObjectBox, so the default data-protection
keychain is a hazard here. The production wrapper disables it:

```dart
const FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);
```

The legacy keychain needs no `keychain-access-groups` entitlement and so avoids
the provisioning-profile constraint that entitlement carries. **The only proof
this works is a real macOS run**: write a token, restart the app, read it back.
`test/secure_config_purity_test.dart`'s manual-gate group records that the
automated suite does not and cannot cover it.

On Linux the build host needs `libsecret-1-dev` and the runtime needs a keyring
(`gnome-keyring`, `kwallet`, or `secret-service`). Tests use a fake and need
neither.

## Validation

The UI requires a non-empty label and an absolute `http`/`https` URL. A label is
required but **not unique**; the uuid is the identity. The token is optional:
openai-compatible local servers (Ollama, LM Studio, llama.cpp) often need none.

## Tests

The whole suite uses `FakeTokenStore` (`test/test_token_store.dart`) or the
plugin's in-memory platform. **No test touches a real keychain.** The
`FlutterSecureTokenStore` wrapper is driven through
`TestFlutterSecureStoragePlatform` to cover key derivation, `readAll` filtering,
and failure translation.
