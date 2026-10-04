import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';

/// Creates a tuple (settings-for-ai FR7).
typedef AddAiConfig = Future<AiEndpointConfig> Function({
  required String label,
  required String endpoint,
  required bool shared,
  String? token,
});

/// Edits a tuple (settings-for-ai FR8). A token is written only when [newToken]
/// is non-empty or [clearToken] is true.
typedef UpdateAiConfig = Future<void> Function(
  String uuid, {
  required String label,
  required String endpoint,
  required bool shared,
  String? newToken,
  bool clearToken,
});

/// The AI endpoint configuration list (settings-for-ai FR7–FR9).
///
/// Holds no token, only the tuples' `hasToken` flags — the state layer has no
/// way to read a secret (FR4, NFR2).
class AiConfigsState {
  final List<AiEndpointConfig> configs;
  final AddAiConfig add;
  final UpdateAiConfig update;
  final Future<void> Function(String uuid) delete;

  const AiConfigsState({
    required this.configs,
    required this.add,
    required this.update,
    required this.delete,
  });
}
