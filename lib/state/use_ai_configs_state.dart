import 'package:mylittlenotebooks/data/ai_config_repository.dart';
import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';
import 'package:mylittlenotebooks/state/ai_configs_state.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// Builds [AiConfigsState], seeded from the preloaded snapshot so the first
/// frame already knows each tuple's `hasToken` (Directive 6, plan I6).
///
/// The mutations are async because the secret store is asynchronous; each
/// refreshes the list from the repository afterwards.
AiConfigsState useAiConfigsState({
  required AiConfigRepository repo,
  required List<AiEndpointConfig> preloaded,
}) {
  final configs = useState(preloaded);

  Future<AiEndpointConfig> add({
    required String label,
    required String endpoint,
    required bool shared,
    String? token,
  }) async {
    final created = await repo.create(
      label: label,
      endpoint: endpoint,
      shared: shared,
      token: token,
    );
    configs.value = repo.list();
    return created;
  }

  Future<void> update(
    String uuid, {
    required String label,
    required String endpoint,
    required bool shared,
    String? newToken,
    bool clearToken = false,
  }) async {
    await repo.update(
      uuid,
      label: label,
      endpoint: endpoint,
      shared: shared,
      newToken: newToken,
      clearToken: clearToken,
    );
    configs.value = repo.list();
  }

  Future<void> delete(String uuid) async {
    await repo.delete(uuid);
    configs.value = repo.list();
  }

  return AiConfigsState(
    configs: configs.value,
    add: add,
    update: update,
    delete: delete,
  );
}
