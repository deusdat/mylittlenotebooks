import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mylittlenotebooks/widgets/placeholder_body.dart';

/// Shown for an unknown route and as the router's `errorBuilder` target.
class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Expanded(
          child: PlaceholderBody(
            title: 'Page not found',
            message: 'That destination does not exist.',
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.tonal(
            onPressed: () => context.go('/'),
            child: const Text('Back to notebooks'),
          ),
        ),
      ],
    );
  }
}