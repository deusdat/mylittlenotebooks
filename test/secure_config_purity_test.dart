import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'domain_model_purity_test.dart' show importedPackages;

/// Guards the secret seam's boundary (settings-for-ai FR4, NFR2; AC21).
///
/// A token is the one value the UI and the domain must never be able to read.
/// The cheapest way to lose that is an import, so the import is what is checked.
void main() {
  group('secret storage locality', () {
    test('AC2: ObAiConfig declares no secret-bearing property', () {
      // The token must never become a column on the entity. Scans *declaration*
      // lines only; the file's doc comments discuss the token in prose, which is
      // exactly where a reviewer looks for the rule.
      final source =
          File('lib/data/objectbox/ob_ai_config.dart').readAsStringSync();
      final fieldDecl = RegExp(
        r'^\s*(?:final\s+|late\s+)?[A-Za-z_][A-Za-z0-9_<>?]*\s+'
        r'(token|secret|apiKey|api_key|password)\s*[;=]',
        multiLine: true,
        caseSensitive: false,
      );
      final match = fieldDecl.firstMatch(source);
      expect(
        match,
        isNull,
        reason: 'ObAiConfig must expose no secret column; the token lives in the '
            'platform secret store (FR2). Found: ${match?.group(0)}',
      );
    });

    test('only the token-store seam imports flutter_secure_storage', () {
      const allowed = 'lib/data/secrets/flutter_secure_token_store.dart';

      final offenders = <String>[];
      for (final file in Directory('lib').listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final path = file.path.replaceAll(r'\', '/');
        if (path == allowed) continue;
        if (importedPackages(file)
            .any((i) => i.startsWith('package:flutter_secure_storage'))) {
          offenders.add(path);
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'Only $allowed may import flutter_secure_storage. A widget, a '
            'domain model, or a repository that imported it could read a token '
            'directly, which FR4/NFR2 forbid. Offenders: $offenders',
      );
    });

    test('no UI file imports the secret seam', () {
      final offenders = <String, List<String>>{};
      for (final dir in ['lib/shell', 'lib/pages', 'lib/widgets']) {
        for (final file
            in Directory(dir).listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;
          final hits = importedPackages(file)
              .where((i) => i.contains('/data/secrets/'))
              .toList();
          if (hits.isNotEmpty) offenders[file.path] = hits;
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'The UI reaches tokens through the repository/intent, never the '
            'token store (FR4, NFR2). Offenders: $offenders',
      );
    });
  });

  group('manual gate', () {
    // Recorded so the next person knows exactly what the automated suite does
    // NOT cover. Mirrors test/production_store_config_test.dart.
    test('the real keychain has never been exercised automatically', () {
      expect(
        true,
        isTrue,
        reason: 'Run the app (`flutter run -d macos`) and, via a throwaway '
            'probe, write a token with FlutterSecureTokenStore, restart, and '
            'read it back. A write that appears to succeed but reads back null '
            'is the plugin\'s App-Group/Keychain silent no-op (plan R2) and no '
            'test in this project can catch it.',
      );
    });
  });
}
