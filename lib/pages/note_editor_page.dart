import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/data/note_environment.dart';
import 'package:mylittlenotebooks/models/chat_panel_geometry.dart';
import 'package:mylittlenotebooks/shell/chat_panel.dart';
import 'package:mylittlenotebooks/state/note_editor_state.dart';
import 'package:mylittlenotebooks/state/use_note_editor.dart';
import 'package:mylittlenotebooks/widgets/placeholder_body.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The note editor route (spec FR27–FR29, FR36).
///
/// A [HookWidget] Coordinator: binds [useNoteEditor] to the view and performs
/// navigation. Reading and editing are one surface — Save/Cancel appear only
/// when the note is dirty (spec D12).
class NoteEditorPage extends HookWidget {
  final NoteEnvironment env;
  final String notebookId;

  /// Null in new-note mode (spec FR30).
  final String? noteId;

  const NoteEditorPage({
    super.key,
    required this.env,
    required this.notebookId,
    required this.noteId,
  });

  @override
  Widget build(BuildContext context) {
    // Rebuild when background embedding completes, so the "not searchable"
    // banner clears without the user navigating (spec FR11a).
    useValueListenable(env.embedding.revision);

    final note = noteId == null ? null : env.notes.byUuid(noteId!);

    if (noteId != null && note == null) {
      return const PlaceholderBody(
        title: 'Note not found',
        message: 'This note is no longer available.',
      );
    }

    final state = useNoteEditor(
      note: note,
      notebookId: notebookId,
      repo: env.notes,
      embedding: env.embedding,
      activeModelId: env.activeModelId,
      onSaved: (uuid) {
        // After creating a new note, move to its canonical route **without
        // dropping the notes section beneath**, so Back still returns to it.
        if (noteId == null) {
          context.pushReplacement('/notebook/$notebookId/note/$uuid');
        }
      },
    );

    final chatCollapsed = useState(true);
    final windowWidth = MediaQuery.sizeOf(context).width;
    final chatWidth = ChatPanelGeometry.widthFor(
      windowWidth: windowWidth,
      collapsedByUser: chatCollapsed.value,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _EditorView(
            state: state,
            onBack: () {
              // Deterministic: the note stacks over the notes section, so pop
              // returns to it; a deep-linked note falls back to the section.
              final router = GoRouter.of(context);
              if (router.canPop()) {
                router.pop();
              } else {
                router.go('/notebook/$notebookId/notes');
              }
            },
          ),
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        SizedBox(
          width: chatWidth,
          child: ChatPanel(
            noteUuid: note?.uuid ?? '',
            chatMessages: env.chatMessages,
            collapsed: chatCollapsed.value,
            onToggleCollapsed: () => chatCollapsed.value = !chatCollapsed.value,
          ),
        ),
      ],
    );
  }
}

class _EditorView extends HookWidget {
  final NoteEditorState state;
  final VoidCallback onBack;

  const _EditorView({required this.state, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleController =
        useMemoized(() => TextEditingController(text: state.title), const []);
    final bodyController =
        useMemoized(() => TextEditingController(text: state.body), const []);

    useEffect(() {
      if (titleController.text != state.title) titleController.text = state.title;
      return null;
    }, [state.title]);
    useEffect(() {
      if (bodyController.text != state.body) bodyController.text = state.body;
      return null;
    }, [state.body]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back to notes',
                onPressed: onBack,
              ),
              Expanded(
                child: TextField(
                  controller: titleController,
                  onChanged: state.setTitle,
                  decoration: const InputDecoration(
                    hintText: 'Untitled note',
                    border: InputBorder.none,
                  ),
                  style: theme.textTheme.titleLarge,
                ),
              ),
              if (state.dirty) ...[
                TextButton(
                  onPressed: state.saving ? null : state.cancel,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: state.saving ? null : state.save,
                  child: const Text('Save'),
                ),
              ],
            ],
          ),
        ),
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        if (state.isUnindexed)
          Container(
            width: double.infinity,
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'This note is not currently searchable.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        if (state.error != null)
          Container(
            width: double.infinity,
            color: theme.colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              state.error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: bodyController,
              onChanged: state.setBody,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: 'Write your note in Markdown…',
                border: InputBorder.none,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
