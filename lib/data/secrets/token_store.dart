/// The seam over the platform secret store (settings-for-ai FR3, FR4).
///
/// A tuple's **token** is the only value in this app that must never be
/// plaintext at rest and must never be visible to the widget layer. It is held
/// by the platform's own secret mechanism — Keychain on Apple platforms,
/// Keystore-backed storage on Android, Credential Manager on Windows, libsecret
/// on Linux — behind this interface.
///
/// Two rules govern every caller:
///
/// 1. **`read` is for the data/sync layer only.** The domain model and the UI
///    learn `hasToken` (a bool) and nothing more (FR4, NFR2).
/// 2. **There is no plaintext fallback.** An unavailable keyring throws
///    [TokenStoreUnavailableException]; the caller must fail loudly rather than
///    write the token somewhere readable (FR17).
///
/// See `docs/settings-conventions.md` for the write ordering and reconciliation
/// rules that compensate for the keychain and ObjectBox being unable to share a
/// transaction.
library;

/// The key prefix under which every tuple token is stored.
const String aiConfigTokenKeyPrefix = 'ai_config_token.';

/// The secret-store key for the tuple with [uuid].
///
/// Derived from the uuid so a tuple's secret is addressable without a separate
/// index, and a re-created tuple can never inherit a stale secret (uuids are
/// never reused).
String aiConfigTokenKey(String uuid) => '$aiConfigTokenKeyPrefix$uuid';

/// Storage for tuple tokens, keyed by tuple uuid.
abstract interface class TokenStore {
  /// Writes (or replaces) the token for [uuid].
  Future<void> write(String uuid, String token);

  /// Removes the token for [uuid]. Deleting an absent key is not an error.
  Future<void> delete(String uuid);

  /// Whether a token is held for [uuid].
  ///
  /// This is the only token query the list path may make: it does **not** return
  /// the secret (spec NFR6).
  Future<bool> exists(String uuid);

  /// Returns the token for [uuid], or null when none is held.
  ///
  /// **Data/sync layer only** (FR4).
  Future<String?> read(String uuid);

  /// Every stored key/value pair.
  ///
  /// Used only by boot reconciliation to find orphaned secrets. It decrypts
  /// values because the platform exposes no key-only enumeration; the cost is
  /// bounded and boot-time, and is recorded in the plan.
  Future<Map<String, String>> readAll();
}

/// A batch read, expressed in terms of [TokenStore.read].
///
/// Selection batches the reads for the records it is about to push so the
/// keychain is touched once per record rather than once per call site.
extension TokenStoreBatch on TokenStore {
  Future<Map<String, String>> readMany(Iterable<String> uuids) async {
    final found = <String, String>{};
    for (final uuid in uuids) {
      final value = await read(uuid);
      if (value != null) found[uuid] = value;
    }
    return found;
  }
}

/// Thrown when the platform secret store cannot be reached — a locked keyring, a
/// missing macOS Keychain entitlement, or libsecret not running.
///
/// It exists so the write path can **refuse to save** rather than fall back to
/// plaintext (FR17, AC14).
class TokenStoreUnavailableException implements Exception {
  final String reason;

  const TokenStoreUnavailableException(this.reason);

  @override
  String toString() => 'TokenStoreUnavailableException: $reason';
}

/// A token operation a receive produced but could not yet perform, because the
/// keychain is asynchronous and ObjectBox transactions are not (plan I3).
///
/// `SyncApplier.ingest` collects these; the async `ingestEncoded` flushes them.
sealed class PendingSecret {
  const PendingSecret();
}

/// Write [token] for [uuid].
class SecretWrite extends PendingSecret {
  final String uuid;
  final String token;

  const SecretWrite(this.uuid, this.token);
}

/// Remove the token for [uuid].
class SecretDelete extends PendingSecret {
  final String uuid;

  const SecretDelete(this.uuid);
}
