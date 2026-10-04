import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';
import 'package:mylittlenotebooks/state/ai_configs_state.dart';
import 'package:mylittlenotebooks/widgets/ai_config_form.dart';
import 'package:mylittlenotebooks/widgets/settings_view.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The routed Settings destination (settings-for-ai FR7–FR9, FR19, FR20).
///
/// A [HookWidget] Coordinator: it reads the global [AiConfigsState], binds
/// [SettingsView], and owns the add/edit dialogs, the delete confirmation, and
/// error surfacing. The view itself holds no state.
class SettingsPage extends HookWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = useProvided<AiConfigsState>();
    return SettingsView(
      configs: state.configs,
      onAdd: () => _add(context, state),
      onEdit: (config) => _edit(context, state, config),
      onDelete: (config) => _confirmAndDelete(context, state, config),
    );
  }

  Future<void> _add(BuildContext context, AiConfigsState state) async {
    final result = await showDialog<AiConfigFormResult>(
      context: context,
      builder: (_) => const AiConfigForm(),
    );
    if (result == null) return;
    if (!context.mounted) return;
    await _guard(context, () => state.add(
          label: result.label,
          endpoint: result.endpoint,
          shared: result.shared,
          token: result.token,
        ));
  }

  Future<void> _edit(
    BuildContext context,
    AiConfigsState state,
    AiEndpointConfig config,
  ) async {
    final result = await showDialog<AiConfigFormResult>(
      context: context,
      builder: (_) => AiConfigForm(initial: config),
    );
    if (result == null) return;
    if (!context.mounted) return;
    await _guard(context, () => state.update(
          config.uuid,
          label: result.label,
          endpoint: result.endpoint,
          shared: result.shared,
          newToken: result.token,
          clearToken: result.clearToken,
        ));
  }

  /// Confirmation is required because the deletion is permanent and, for a
  /// shared tuple, removes it from the user's other devices too (FR19).
  Future<void> _confirmAndDelete(
    BuildContext context,
    AiConfigsState state,
    AiEndpointConfig config,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete endpoint?'),
        content: Text(
          'This permanently deletes "${config.label}". '
          '${config.shared ? 'Because it is shared, it is also removed from your '
              'other devices. ' : ''}'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;
    await _guard(context, () => state.delete(config.uuid));
  }

  /// Runs an async action and reports a failure (a locked keychain, say) rather
  /// than swallowing it (FR17).
  Future<void> _guard(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $error')),
      );
    }
  }
}
