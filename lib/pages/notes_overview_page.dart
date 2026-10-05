import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/data/note_environment.dart';
import 'package:mylittlenotebooks/state/use_notes_list.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The Notes section's centre page: the notebook's notes plus Add note
/// (spec FR26, FR30).
class NotesOverviewPage extends HookWidget {
  final NoteEnvironment env;
  final String notebookId;

  const NotesOverviewPage({
    super.key,
    required this.env,
    required this.notebookId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = useNotesList(notebookId: notebookId, repo: env.notes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text('Notes', style: theme.textTheme.headlineSmall),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add note'),
                // `push` so the editor stacks over the notes list and Back
                // returns here.
                onPressed: () => context.push('/notebook/$notebookId/note/new'),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: list.notes.isEmpty
              ? Center(
                  child: Text(
                    'No notes yet.',
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              : ListView.builder(
                  itemCount: list.notes.length,
                  itemBuilder: (context, index) {
                    final note = list.notes[index];
                    return ListTile(
                      leading: const Icon(Icons.sticky_note_2_outlined),
                      title: Text(
                        (note.title == null || note.title!.trim().isEmpty)
                            ? 'Untitled note'
                            : note.title!,
                      ),
                      subtitle: Text('${note.chunkCount} chunk(s)'),
                      onTap: () => context
                          .push('/notebook/$notebookId/note/${note.uuid}'),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
