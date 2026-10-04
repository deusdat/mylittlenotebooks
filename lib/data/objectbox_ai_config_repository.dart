import 'package:mylittlenotebooks/data/ai_config_repository.dart';
import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_ai_config.dart';
import 'package:mylittlenotebooks/data/secrets/token_store.dart';
import 'package:mylittlenotebooks/data/sync/sync_deleter.dart';
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// Durable [AiConfigRepository] over ObjectBox + the platform secret store.
///
/// The two stores cannot share a transaction, so the ordering here is the
/// safety mechanism (plan I3, I4):
///
/// - **On save, the secret is written first.** A keychain failure therefore
///   throws before any row exists — never a tuple whose token silently failed to
///   store (FR17, AC14). The reverse leaves a row with a missing secret.
/// - **On delete, the row and its tombstone commit together**, then the secret
///   is removed. A crash between the two leaves an orphan secret, which the boot
///   [reconcile] sweep removes (FR18).
/// - **[list] never touches a token.** `hasToken` is served from [_tokenUuids],
///   warmed once at boot (FR5, NFR6, AC16).
class ObjectBoxAiConfigRepository implements AiConfigRepository {
  ObjectBoxAiConfigRepository(
    this._store,
    this._tokens, {
    SyncDeleter? deleter,
  })  : _box = _store.box<ObAiConfig>(),
        _deleter = deleter ?? SyncDeleter(store: _store);

  final Store _store;
  final TokenStore _tokens;
  final Box<ObAiConfig> _box;
  final SyncDeleter _deleter;

  /// Uuids known to hold a token. Warmed by [refreshTokenFlags]; maintained by
  /// the mutations below. A set, not a stored column (FR5).
  final Set<String> _tokenUuids = <String>{};

  @override
  List<AiEndpointConfig> list() {
    final query = _box.query().order(ObAiConfig_.createdAt).build();
    try {
      return query
          .find()
          .map((entity) =>
              entity.toDomain(hasToken: _tokenUuids.contains(entity.uuid)))
          .toList();
    } finally {
      query.close();
    }
  }

  @override
  Future<AiEndpointConfig> create({
    required String label,
    required String endpoint,
    required bool shared,
    String? token,
  }) async {
    final uuid = newUuidV7();
    final hasToken = token != null && token.isNotEmpty;

    // Secret first (plan I4): a throw here leaves no row at all.
    if (hasToken) {
      await _tokens.write(uuid, token);
    }

    final entity = ObAiConfig(
      uuid: uuid,
      label: label,
      endpoint: endpoint,
      shared: shared,
      createdAt: _nowUtc(),
      // A creation is a modification, so the record starts at 1.
      versionCounter: 1,
    );
    _store.runInTransaction(TxMode.write, () {
      _box.put(entity);
      return null;
    });

    if (hasToken) _tokenUuids.add(uuid);
    return entity.toDomain(hasToken: hasToken);
  }

  @override
  Future<void> update(
    String uuid, {
    required String label,
    required String endpoint,
    required bool shared,
    String? newToken,
    bool clearToken = false,
  }) async {
    final entity = _require(uuid);

    // Secret work first, so a keychain failure leaves the metadata unchanged.
    if (clearToken) {
      await _tokens.delete(uuid);
      _tokenUuids.remove(uuid);
    } else if (newToken != null && newToken.isNotEmpty) {
      await _tokens.write(uuid, newToken);
      _tokenUuids.add(uuid);
    }

    _store.runInTransaction(TxMode.write, () {
      entity.label = label;
      entity.endpoint = endpoint;
      entity.shared = shared;
      entity.versionCounter++;
      _box.put(entity);
      return null;
    });
  }

  @override
  Future<void> delete(String uuid) async {
    // Row + tombstone commit together (plan I5).
    _deleter.deleteAiConfigLocally(uuid);
    // Outside the transaction, because it cannot be inside one.
    await _tokens.delete(uuid);
    _tokenUuids.remove(uuid);
  }

  @override
  Future<void> refreshTokenFlags() async {
    _tokenUuids.clear();
    final query = _box.query().build();
    final List<String> uuids;
    try {
      uuids = query.find().map((e) => e.uuid).toList();
    } finally {
      query.close();
    }
    for (final uuid in uuids) {
      if (await _tokens.exists(uuid)) _tokenUuids.add(uuid);
    }
  }

  @override
  Future<void> reconcile() async {
    // Orphan secrets: a key with no row. `readAll` is the only enumeration the
    // platform offers; it is boot-time and bounded (plan I6).
    //
    // **Enumeration is not supported on every platform.** The macOS *legacy*
    // keychain (`usesDataProtectionKeychain: false`, which this app uses to
    // avoid an entitlement) rejects `kSecMatchLimitAll` with `errSecParam`
    // (-50). Orphan cleanup is housekeeping and must never stop the app booting,
    // so a failure here is swallowed; [refreshTokenFlags] still runs, so a stale
    // secret cannot make `hasToken` lie. The cost is a small, bounded secret
    // leak on those platforms only.
    try {
      final stored = await _tokens.readAll();
      for (final key in stored.keys) {
        if (!key.startsWith(aiConfigTokenKeyPrefix)) continue;
        final uuid = key.substring(aiConfigTokenKeyPrefix.length);
        if (_find(uuid) == null) await _tokens.delete(uuid);
      }
    } on TokenStoreUnavailableException {
      // Best-effort: skip the sweep, keep booting.
    }
    await refreshTokenFlags();
  }

  @override
  Future<String?> tokenFor(String uuid) => _tokens.read(uuid);

  ObAiConfig _require(String uuid) {
    final found = _find(uuid);
    if (found == null) throw StateError('no ai config with uuid $uuid');
    return found;
  }

  ObAiConfig? _find(String uuid) {
    final query = _box.query(ObAiConfig_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  static DateTime _nowUtc() {
    final now = DateTime.now().toUtc();
    return DateTime.fromMillisecondsSinceEpoch(
      now.millisecondsSinceEpoch,
      isUtc: true,
    );
  }
}
