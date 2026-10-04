import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/bootstrap.dart';
import 'package:mylittlenotebooks/data/ai_config_repository.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/panel_state_store.dart';

/// Bootstrap exposes the AI configuration repository and a warmed snapshot
/// (settings-for-ai AC15, AC23).
///
/// The injected-repository path is used deliberately: it opens no ObjectBox
/// store and no keychain, which is the property the shell tests rely on.
void main() {
  test('bootstrap exposes the supplied repo and a hasToken-bearing snapshot',
      () async {
    final aiConfigs = InMemoryAiConfigRepository();
    final created = await aiConfigs.create(
      label: 'Shared',
      endpoint: 'https://api.example/v1',
      shared: true,
      token: 'secret',
    );
    await aiConfigs.create(
      label: 'No token',
      endpoint: 'http://localhost/v1',
      shared: false,
    );

    final result = await bootstrapDependencies(
      store: InMemoryPanelStateStore(),
      notebooks: InMemoryNotebookRepository(),
      aiConfigs: aiConfigs,
    );

    expect(identical(result.aiConfigs, aiConfigs), isTrue);
    expect(result.initialAiConfigs, hasLength(2));
    expect(
      result.initialAiConfigs.firstWhere((c) => c.uuid == created.uuid).hasToken,
      isTrue,
    );
    expect(
      result.initialAiConfigs
          .firstWhere((c) => c.label == 'No token')
          .hasToken,
      isFalse,
    );
  });
}
