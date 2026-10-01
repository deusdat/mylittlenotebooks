import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/widgets/placeholder_body.dart';

class NotebooksHomePage extends StatelessWidget {
  const NotebooksHomePage({super.key});

  @override
  Widget build(BuildContext context) =>
      const PlaceholderBody(
        title: 'Notebooks',
        message: 'Pick a notebook from the panel to start working.',
      );
}