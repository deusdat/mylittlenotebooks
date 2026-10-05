import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/data/chat_message_repository.dart';
import 'package:mylittlenotebooks/models/chat_message.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The right-hand chat panel (spec FR31, FR32, FR34).
///
/// **Display only** (spec FR33): it renders the note's stored messages and a
/// multi-line input, but the input does not send. The panel's collapse state is
/// transient per session (spec D26).
class ChatPanel extends HookWidget {
  final String noteUuid;
  final ChatMessageRepository chatMessages;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;

  const ChatPanel({
    super.key,
    required this.noteUuid,
    required this.chatMessages,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  /// Three rows tall by default (spec FR32).
  static const double defaultInputHeight = 72.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // **Hooks run unconditionally, before the collapsed early-return.** A hook
    // called only in the expanded branch adds a hook after the first build when
    // the user expands, which the framework rejects — the panel throws instead
    // of opening.
    final inputHeight = useState<double>(defaultInputHeight);
    final scrollController = useMemoized(() => ScrollController(), const []);
    final controller = useMemoized(() => TextEditingController(), const []);
    // Memoized by note so a rebuild on every keystroke does not re-query the
    // store. Nothing appends messages in this feature; when something does, key
    // this on the append instead.
    final messages =
        useMemoized(() => chatMessages.listForNote(noteUuid), [noteUuid]);

    // Keep the newest message in view (spec FR32): oldest at top, newest at the
    // bottom.
    useEffect(() {
      if (scrollController.hasClients) {
        scrollController.jumpTo(scrollController.position.maxScrollExtent);
      }
      return null;
    }, [messages.length]);

    if (collapsed) {
      return _ChatRail(onToggleCollapsed: onToggleCollapsed);
    }

    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Text('Chat', style: theme.textTheme.titleSmall),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Collapse chat',
                onPressed: onToggleCollapsed,
              ),
            ],
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          Expanded(
            child: messages.isEmpty
                ? _EmptyChat(theme: theme)
                : ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) =>
                        _MessageBubble(message: messages[index]),
                  ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          // A drag handle that grows/shrinks the input, not the window.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) {
              final next = (inputHeight.value - details.delta.dy)
                  .clamp(56.0, 240.0);
              inputHeight.value = next;
            },
            child: SizedBox(
              height: 12,
              child: Center(
                child: Container(
                  width: 36,
                  height: 3,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SizedBox(
              height: inputHeight.value,
              child: TextField(
                controller: controller,
                minLines: 3,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Ask about this note…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatRail extends StatelessWidget {
  final VoidCallback onToggleCollapsed;

  const _ChatRail({required this.onToggleCollapsed});

  @override
  Widget build(BuildContext context) => Center(
        child: IconButton(
          icon: const Icon(Icons.forum_outlined),
          tooltip: 'Expand chat',
          onPressed: onToggleCollapsed,
        ),
      );
}

class _EmptyChat extends StatelessWidget {
  final ThemeData theme;

  const _EmptyChat({required this.theme});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No messages yet.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == ChatMessageRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(message.text, style: theme.textTheme.bodyMedium),
      ),
    );
  }
}
