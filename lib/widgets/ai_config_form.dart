import 'package:flutter/material.dart';
import 'package:mylittlenotebooks/models/ai_endpoint_config.dart';
import 'package:utopia_hooks/utopia_hooks.dart';

/// The result of the add/edit form.
///
/// [token] is null when the field was left untouched (keep any stored token);
/// [clearToken] is a deliberate removal of an existing one. The form never
/// reads a token back — it is write-only (settings-for-ai FR8).
class AiConfigFormResult {
  final String label;
  final String endpoint;
  final String? token;
  final bool clearToken;
  final bool shared;

  const AiConfigFormResult({
    required this.label,
    required this.endpoint,
    required this.token,
    required this.clearToken,
    required this.shared,
  });
}

/// Validates an OpenAI-compatible base URL.
String? validateEndpoint(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return 'Enter an endpoint URL';
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return 'Enter an absolute http(s) URL';
  }
  return null;
}

/// The add/edit dialog body (settings-for-ai FR7, FR8, FR21).
///
/// A [HookWidget] so the text controllers are owned and disposed by hooks — no
/// `StatefulWidget` (AGENTS Flutter directive 1).
class AiConfigForm extends HookWidget {
  /// The tuple being edited, or null when adding.
  final AiEndpointConfig? initial;

  const AiConfigForm({super.key, this.initial});

  @override
  Widget build(BuildContext context) {
    final formKey = useMemoized(GlobalKey<FormState>.new);
    final labelController = useMemoized(
      () => TextEditingController(text: initial?.label ?? ''),
      const [],
      (controller) => controller.dispose(),
    );
    final endpointController = useMemoized(
      () => TextEditingController(text: initial?.endpoint ?? ''),
      const [],
      (controller) => controller.dispose(),
    );
    final tokenController = useMemoized(
      TextEditingController.new,
      const [],
      (controller) => controller.dispose(),
    );
    final shared = useState(initial?.shared ?? false);
    final removeToken = useState(false);

    final editing = initial != null;
    final hasToken = initial?.hasToken ?? false;

    return AlertDialog(
      title: Text(editing ? 'Edit endpoint' : 'Add endpoint'),
      content: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: labelController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Enter a name'
                    : null,
              ),
              TextFormField(
                controller: endpointController,
                decoration: const InputDecoration(
                  labelText: 'Endpoint',
                  hintText: 'https://api.example.com/v1',
                ),
                validator: validateEndpoint,
              ),
              TextFormField(
                controller: tokenController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Token',
                  helperText: hasToken
                      ? 'A token is stored. Leave blank to keep it.'
                      : 'Optional. Stored in the system keychain.',
                ),
              ),
              if (hasToken)
                CheckboxListTile(
                  value: removeToken.value,
                  onChanged: (value) => removeToken.value = value ?? false,
                  title: const Text('Remove stored token'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              SwitchListTile(
                value: shared.value,
                onChanged: (value) => shared.value = value,
                title: const Text('Share with my other devices'),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!(formKey.currentState?.validate() ?? false)) return;
            final token = tokenController.text;
            Navigator.of(context).pop(AiConfigFormResult(
              label: labelController.text.trim(),
              endpoint: endpointController.text.trim(),
              token: token.isEmpty ? null : token,
              // A newly typed token wins over the remove checkbox.
              clearToken: token.isEmpty && removeToken.value,
              shared: shared.value,
            ));
          },
          child: Text(editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
