import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/widgets/placeholder_body.dart';

/// The Settings destination.
///
/// Content is out of scope for this iteration; the destination exists to prove
/// it is reachable from both the list view and the notebook detail view, and
/// returns to whichever view it was opened from (spec AC15).
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const PlaceholderBody(
        title: 'Settings',
        message: 'Settings arrive in a later spec.',
      );
}