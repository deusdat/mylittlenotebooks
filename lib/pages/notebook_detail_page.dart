import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/state/notebooks_state.dart';
import 'package:mylittlenotebooks/widgets/placeholder_body.dart';
import 'package:utopia_hooks/utopia_hooks.dart';
import 'package:go_router/go_router.dart';

/// The routed destination for one notebook.
///
/// A [HookWidget] Coordinator: reads the notebook from the global
/// [NotebooksState] and hands it to a view. Renders a placeholder body — no
/// sources, notes, or artifacts yet (spec Non-Goals).
///
/// The page header carries the app's **only** delete affordance — a trash-can
/// beside the title (delete-notebook FR13, D8). It is not in the navigation
/// panel or the rail, so the panel keeps its existing shape and keyboard order.
class NotebookDetailPage extends HookWidget {
  final String notebookId;

  const NotebookDetailPage({super.key, required this.notebookId});

  @override
  Widget build(BuildContext context) {
    final notebooks = useProvided<NotebooksState>();
    final notebook = notebooks.byId(notebookId);

    // The redirect guard makes this unreachable in practice, but the widget
    // must not assume it (spec FR13).
    if (notebook == null) {
      return const PlaceholderBody(
        title: 'Notebook not found',
        message: 'This notebook is no longer available.',
      );
    }

    return _NotebookDetailView(
      title: notebook.title,
      notebookId: notebookId,
      onDelete: () => _confirmAndDelete(context, notebooks, notebookId),
    );
  }

  /// Shows the confirmation modal and, only on confirm, deletes and leaves.
  ///
  /// Dismissing the modal by any route — Cancel, the scrim, `Escape`, or the
  /// platform back — returns `false`/`null`, and then nothing is written
  /// (delete-notebook FR14).
  Future<void> _confirmAndDelete(
    BuildContext context,
    NotebooksState notebooks,
    String notebookId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete notebook?'),
        content: const Text(
          'This permanently deletes the notebook and every source used only by '
          'it. Sources also attached to another notebook are kept. This cannot '
          'be undone.',
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

    if (confirmed != true) return;
    if (!context.mounted) return;

    notebooks.delete(notebookId);
    // The route now names a deleted notebook; leave it rather than render the
    // "not found" placeholder for a frame.
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }
}

class _NotebookDetailView extends StatelessWidget {
  final String title;
  final String notebookId;
  final VoidCallback onDelete;

  const _NotebookDetailView({
    required this.title,
    required this.notebookId,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(title, style: theme.textTheme.headlineSmall),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete notebook',
                onPressed: onDelete,
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        // Keyed by notebook so each one keeps its own retained state.
        Expanded(
          child: PlaceholderBody(
            key: ValueKey('notebook-body-$notebookId'),
            title: 'Nothing here yet',
            message: 'Sources, notes, and chat arrive in later specs.',
          ),
        ),
      ],
    );
  }
}
