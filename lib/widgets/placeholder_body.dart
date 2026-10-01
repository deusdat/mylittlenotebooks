import 'package:flutter/material.dart';

/// Shared empty-state body for centre-page destinations.
///
/// The centre page renders no notebook content yet — sources, notes, and
/// artifacts are explicit Non-Goals for this iteration (spec FR1).
class PlaceholderBody extends StatelessWidget {
  final String title;
  final String? message;

  const PlaceholderBody({super.key, required this.title, this.message});

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
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}