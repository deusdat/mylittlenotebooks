import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';

/// One configuration row (settings-for-ai FR20).
///
/// Shows label, endpoint, a shared indicator, and whether a token is set — never
/// the token itself (FR4). Edit and delete are the row's actions.
class AiConfigTile extends StatelessWidget {
  final AiEndpointConfig config;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const AiConfigTile({
    super.key,
    required this.config,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(Icons.hub_outlined, color: theme.colorScheme.primary),
      title: Text(config.label),
      subtitle: Text(config.endpoint),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (config.shared)
            Tooltip(
              message: 'Shared with your other devices',
              child: Icon(
                Icons.devices_outlined,
                semanticLabel: 'Shared with your other devices',
                color: theme.colorScheme.secondary,
              ),
            ),
          const SizedBox(width: 8),
          Tooltip(
            message: config.hasToken ? 'Token set' : 'No token',
            child: Icon(
              config.hasToken ? Icons.key : Icons.key_off_outlined,
              semanticLabel: config.hasToken ? 'Token set' : 'No token',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit ${config.label}',
            onPressed: onEdit,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete ${config.label}',
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
