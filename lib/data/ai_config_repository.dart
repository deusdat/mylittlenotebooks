import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';

/// The settings-facing API for AI endpoint configurations (settings-for-ai FR7,
/// FR8, FR9).
///
/// The interface is deliberately **free of sync and secret vocabulary**: a uuid
/// and plain values in, plain values out. The ObjectBox implementation is what
/// reaches `SyncDeleter` and the token store, exactly as
/// `ObjectBoxNotebookRepository` does for notebook deletes.
///
/// Mutations are `Future`s because the platform secret store is asynchronous
/// (plan I3); reads are synchronous because the UI list renders from a warm
/// snapshot.
abstract interface class AiConfigRepository {
  /// Configurations in creation order. Never reads a token; `hasToken` comes
  /// from a cached flag set (FR5, NFR6).
  List<AiEndpointConfig> list();

  /// Creates a tuple, writing [token] to the secret store first so a keychain
  /// failure leaves no row (FR17, plan I4).
  Future<AiEndpointConfig> create({
    required String label,
    required String endpoint,
    required bool shared,
    String? token,
  });

  /// Edits a tuple. A token is written only when [newToken] is non-empty or
  /// [clearToken] is true; otherwise the stored secret is untouched (FR8).
  Future<void> update(
    String uuid, {
    required String label,
    required String endpoint,
    required bool shared,
    String? newToken,
    bool clearToken = false,
  });

  /// Permanently deletes a tuple: row and tombstone in one transaction, then
  /// the secret (FR9). There is no soft delete.
  Future<void> delete(String uuid);

  /// Reads whether each tuple has a token into the in-memory flag cache
  /// (plan I6). Called once at boot, before the first frame.
  Future<void> refreshTokenFlags();

  /// Removes secret-store entries with no matching row and refreshes flags
  /// (FR18).
  Future<void> reconcile();

  /// The token for [uuid], or null. **Data/sync layer only** (FR4).
  Future<String?> tokenFor(String uuid);
}

/// Seeded in-memory store for tests and shell harnesses.
///
/// Mirrors [InMemoryNotebookRepository]: it exists so the widget tests can build
/// `App` without opening an ObjectBox store or a real keychain. It is **not**
/// used in production.
class InMemoryAiConfigRepository implements AiConfigRepository {
  final List<AiEndpointConfig> _configs = <AiEndpointConfig>[];
  final Map<String, String> _tokens = <String, String>{};
  int _ordinal = 0;

  @override
  List<AiEndpointConfig> list() => List.unmodifiable(_configs);

  @override
  Future<AiEndpointConfig> create({
    required String label,
    required String endpoint,
    required bool shared,
    String? token,
  }) async {
    final uuid = 'ai-${_ordinal++}';
    if (token != null && token.isNotEmpty) _tokens[uuid] = token;
    final config = AiEndpointConfig(
      uuid: uuid,
      label: label,
      endpoint: endpoint,
      shared: shared,
      hasToken: _tokens.containsKey(uuid),
    );
    _configs.add(config);
    return config;
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
    final index = _configs.indexWhere((c) => c.uuid == uuid);
    if (index == -1) throw StateError('no ai config with uuid $uuid');
    if (clearToken) {
      _tokens.remove(uuid);
    } else if (newToken != null && newToken.isNotEmpty) {
      _tokens[uuid] = newToken;
    }
    _configs[index] = AiEndpointConfig(
      uuid: uuid,
      label: label,
      endpoint: endpoint,
      shared: shared,
      hasToken: _tokens.containsKey(uuid),
    );
  }

  @override
  Future<void> delete(String uuid) async {
    _configs.removeWhere((c) => c.uuid == uuid);
    _tokens.remove(uuid);
  }

  @override
  Future<void> refreshTokenFlags() async {}

  @override
  Future<void> reconcile() async {}

  @override
  Future<String?> tokenFor(String uuid) async => _tokens[uuid];
}
