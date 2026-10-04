import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Matches import directives only.
///
/// A naive substring search for `package:objectbox` false-positives on the
/// doc comments that *describe* the rule — these model files discuss the
/// restriction in prose, which is exactly where a reviewer will look for it.
final _importPattern = RegExp(
  r'''^\s*(?:import|export)\s+(['"])([^'"]+)\1''',
  multiLine: true,
);

Set<String> importedPackages(File file) => _importPattern
    .allMatches(file.readAsStringSync())
    .map((m) => m.group(2)!)
    .toSet();

/// The domain **values**. Spec NFR5 constrains these to be free of both
/// `package:flutter` and `package:objectbox`, so each is constructible in a
/// bare `test()` with no native library and no widget binding.
const dataModels = <String>{
  'notebook.dart',
  'publication.dart',
  'chunk.dart',
  'search_result.dart',
  'ai_endpoint_config.dart',
};

/// The rest of `lib/models/` holds presentation descriptors rather than domain
/// values — `notebook_section.dart` carries an `IconData`, for instance, and
/// that is by design. The ObjectBox ban still applies to them; the Flutter ban
/// does not.
void main() {
  group('domain model purity', () {
    late List<File> modelFiles;

    setUpAll(() {
      modelFiles = Directory('lib/models')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
    });

    test('lib/models contains the expected model files', () {
      final names = modelFiles.map((f) => f.uri.pathSegments.last).toList()
        ..sort();
      expect(names, containsAll(dataModels));
    });

    test('no domain model imports flutter or objectbox', () {
      expect(modelFiles, isNotEmpty, reason: 'lib/models should not be empty');

      for (final file in modelFiles) {
        final name = file.uri.pathSegments.last;
        final imports = importedPackages(file);

        expect(
          imports.where((i) => i.startsWith('package:objectbox')),
          isEmpty,
          reason: '$name must not import package:objectbox (spec NFR5, C3). '
              'The storage entity is the Ob* class in lib/data/objectbox/; '
              'convert with lib/domain_mapping.dart.',
        );
        expect(
          imports.where((i) => i.startsWith('dart:io')),
          isEmpty,
          reason: '$name must not import dart:io.',
        );

        if (!dataModels.contains(name)) continue;

        expect(
          imports.where((i) => i.startsWith('package:flutter/')),
          isEmpty,
          reason: '$name is a domain value and must not import '
              'package:flutter (spec NFR5).',
        );
      }
    });

    test('no domain model declares an @Entity annotation', () {
      for (final file in modelFiles) {
        expect(
          file.readAsStringSync().contains('@Entity'),
          isFalse,
          reason: '${file.uri.pathSegments.last} must not be an ObjectBox '
              'entity; annotated classes belong in lib/data/objectbox/.',
        );
      }
    });
  });

  group('storage layer locality', () {
    test('objectbox is imported only inside the data layer', () {
      // The generated bindings expose the entity classes, so the data layer —
      // repositories, the mapping layer, and the sync module — legitimately
      // reaches them. Nothing above `lib/data/` may.
      //
      // The rule is stated by *directory* rather than by an allowlist of files,
      // because an allowlist has to be edited every time a legitimate new data
      // layer file appears, and each edit is a chance to admit something that
      // should not be there.
      final offenders = <String>[];

      for (final file
          in Directory('lib').listSync(recursive: true).whereType<File>()) {
        final path = file.path.replaceAll(r'\', '/');
        if (!path.endsWith('.dart')) continue;
        if (path == 'lib/objectbox.g.dart') continue; // generated
        if (path.startsWith('lib/data/')) continue; // the data layer
        if (importedPackages(file)
            .any((i) => i.startsWith('package:objectbox'))) {
          offenders.add(path);
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'Only lib/data/ may import objectbox. Domain values reach '
            'storage through the repositories, never directly '
            '(spec NFR5, plan §E).',
      );
    });

    test('AC14: no type under lib/models/ carries a sync concept (peer-sync NFR2)', () {
      // The import check above is the cheap half. This is the expensive half that
      // catches the realistic leak: a *helper on a domain class* that knows about
      // pushes — `publication.needsPush(peer)`, `chunk.markSynced()`. Nothing about
      // that requires an import, so the import check stays green while NFR2 is
      // gone.
      //
      // Scans the domain sources for sync vocabulary on a declaration. Matching
      // *declarations* rather than prose is what keeps this from flagging a
      // comment that explains why a domain model must not know about sync.
      final syncWords = RegExp(
        r'(needsPush|markSynced|isSynced|syncState|lastSynced|peerDevice|'
        r'syncVersion|toDto|fromDto|asPayload|watermark|tombstone)',
        caseSensitive: false,
      );

      final offenders = <String, List<String>>{};
      for (final file in Directory('lib/models').listSync().whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final name = file.uri.pathSegments.last;

        final hits = <String>[];
        for (final line in file.readAsStringSync().split('\n')) {
          final trimmed = line.trim();
          // Declarations and members only. A doc comment (`///`, `//`) is prose
          // about the rule, and this file is full of exactly that.
          if (trimmed.startsWith('//')) continue;
          if (!syncWords.hasMatch(trimmed)) continue;
          hits.add(trimmed);
        }
        if (hits.isNotEmpty) offenders[name] = hits;
      }

      expect(
        offenders,
        isEmpty,
        reason: 'A domain model must have no way to express an opinion about '
            'synchronization (peer-sync NFR2). Transport and protocol vocabulary '
            'belongs in lib/data/sync/. Offenders: $offenders',
      );
    });

    test('lib/models imports nothing from the sync module (peer-sync NFR2)', () {
      // The cheapest way to lose NFR2 is a helper on a domain class that knows
      // about pushes. A domain model must have no way to express an opinion
      // about synchronization.
      //
      // This checks **imports**, not raw text. A substring search for "sync"
      // false-positives on ordinary English — `nav_level.dart` documents that a
      // flag must not "drift out of sync with the rendered page", which has
      // nothing to do with synchronization. Dart cannot name a type it has not
      // imported, so the import check is complete rather than a heuristic.
      final offenders = <String, List<String>>{};
      for (final file in Directory('lib/models').listSync().whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final syncImports = importedPackages(file)
            .where((i) => i.contains('/data/sync/'))
            .toList();
        if (syncImports.isNotEmpty) offenders[file.uri.pathSegments.last] = syncImports;
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Sync concepts leaked into a domain model. Transport and '
            'protocol vocabulary belongs in lib/data/sync/ (peer-sync NFR2). '
            'Offenders: $offenders',
      );
    });

    test('AC18: no UI file imports the sync module (delete-notebook NFR1)', () {
      // The UI reaches a notebook delete through the repository, never through
      // lib/data/sync/. A widget that imported `SyncDeleter` would be expressing
      // an opinion about synchronization, which the domain/UI boundary forbids.
      final syncImports = <String, List<String>>{};
      for (final dir in ['lib/shell', 'lib/pages']) {
        for (final file in Directory(dir).listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;
          final hits = importedPackages(file)
              .where((i) => i.contains('/data/sync/'))
              .toList();
          if (hits.isNotEmpty) syncImports[file.path] = hits;
        }
      }
      expect(
        syncImports,
        isEmpty,
        reason: 'UI must reach sync-aware operations through the repository, '
            'not by importing lib/data/sync/ (delete-notebook NFR1, AC18). '
            'Offenders: $syncImports',
      );
    });
  });
}
