import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';
import 'package:mylittlenotebooks/widgets/ai_config_tile.dart';

/// The Settings page body (settings-for-ai FR20).
///
/// A pure view over [AiEndpointConfig] values and callbacks — it holds no state
/// and never reaches storage.
class SettingsView extends StatelessWidget {
  final List<AiEndpointConfig> configs;
  final VoidCallback onAdd;
  final void Function(AiEndpointConfig config) onEdit;
  final void Function(AiEndpointConfig config) onDelete;

  const SettingsView({
    super.key,
    required this.configs,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'AI endpoints',
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('Add endpoint'),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: configs.isEmpty
              ? const _SettingsEmptyState()
              : ListView.separated(
                  key: const ValueKey('ai-config-list'),
                  itemCount: configs.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) {
                    final config = configs[index];
                    return AiConfigTile(
                      key: ValueKey('ai-config-${config.uuid}'),
                      config: config,
                      onEdit: () => onEdit(config),
                      onDelete: () => onDelete(config),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SettingsEmptyState extends StatelessWidget {
  const _SettingsEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.settings_outlined,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                'No AI endpoints yet',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Add an OpenAI-compatible endpoint to use for chat and search. '
                'Tokens are kept in your system keychain, never in the app '
                'database.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
