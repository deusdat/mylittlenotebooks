import 'package:flutter/material.dart';

/// A section of a notebook's detail navigation.
///
/// Detail navigation is generated from a registry of these so that adding a
/// section is a change to the registry, never a change to the panel's widget
/// structure (spec FR10).
@immutable
class NotebookSection {
  final String id;
  final String label;
  final IconData icon;

  /// Whether the section is implemented. Unimplemented sections render disabled
  /// with a "not yet available" tooltip rather than being hidden, so the
  /// registry's shape is visible.
  final bool enabled;

  const NotebookSection({
    required this.id,
    required this.label,
    required this.icon,
    this.enabled = false,
  });
}

/// The sections a notebook's detail navigation offers.
///
/// One is enabled today; the rest are declared but disabled. Sources, notes,
/// chat and studio are explicit Non-Goals for this iteration.
const notebookSections = <NotebookSection>[
  NotebookSection(
    id: 'overview',
    label: 'Overview',
    icon: Icons.dashboard_outlined,
    enabled: true,
  ),
  NotebookSection(
    id: 'sources',
    label: 'Sources',
    icon: Icons.description_outlined,
  ),
  NotebookSection(
    id: 'notes',
    label: 'Notes',
    icon: Icons.sticky_note_2_outlined,
    enabled: true,
  ),
  NotebookSection(
    id: 'chat',
    label: 'Chat',
    icon: Icons.forum_outlined,
  ),
  NotebookSection(
    id: 'studio',
    label: 'Studio',
    icon: Icons.auto_awesome_outlined,
  ),
];