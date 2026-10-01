import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/state/notebooks_state.dart';
import 'package:mylittlenotebooks/widgets/placeholder_body.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The routed destination for one notebook.
///
/// A [HookWidget] Coordinator: reads the notebook from the global
/// [NotebooksState] and hands it to a view. Renders a placeholder body — no
/// sources, notes, or artifacts yet (spec Non-Goals).
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

    return _NotebookDetailView(title: notebook.title, notebookId: notebookId);
  }
}

class _NotebookDetailView extends StatelessWidget {
  final String title;
  final String notebookId;

  const _NotebookDetailView({
    required this.title,
    required this.notebookId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Text(title, style: theme.textTheme.headlineSmall),
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