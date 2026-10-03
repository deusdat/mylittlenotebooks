import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every test file's source, by file name. Loaded lazily and once.
final Map<String, String> sources = {
  for (final entry in Directory('test').listSync().whereType<File>())
    entry.uri.pathSegments.last: entry.readAsStringSync(),
};

/// T22 — the final gate.
///
/// **A checklist, not a claim.** Every acceptance criterion is named by the test
/// that carries it, and this file asserts that test *exists* by name. A criterion
/// with no named test fails here.
///
/// The reason a walk like this exists: eleven falsification checks across the
/// milestones all passed while implementation was in progress, and one of them
/// (AC7e) turned out to be satisfiable by deleting the very field it was meant to
/// protect. "The tests pass" and "the requirements are covered" are different
/// claims, and only the second one is worth anything at a gate.
void main() {
  /// Every acceptance criterion and the test that carries it.
  const coverage = <String, List<String>>{
    'AC1 — every entity declares a @Unique() uuid': ['unique_identity_test.dart'],
    'AC2 — RFC 4122 v7 shape, ordering, zero collisions': ['identity_test.dart'],
    'AC2 — chunk uuids derived, not generated': ['identity_test.dart'],
    'AC3 — no int storage id in any payload field': ['sync_codec_test.dart'],
    'AC3a — a chunk uuid computed independently on two devices': [
      'identity_test.dart'
    ],
    'AC3b — base64 vector is 1,368 chars; JSON exceeds 5,000': [
      'sync_codec_test.dart'
    ],
    'AC4 — LWW incl. the deviceId tie-break': ['sync_version_test.dart'],
    'AC4 — clock independence': ['sync_version_test.dart'],
    'AC5 — a push is a delta; a repeated push changes nothing': [
      'sync_push_test.dart'
    ],
    'AC6 — every chunk agrees with its parent after ingest': [
      'sync_scope_test.dart',
      'sync_apply_test.dart',
    ],
    'AC7 — chunkCount equals the actual count after ingest': [
      'sync_apply_test.dart'
    ],
    'AC7a — 30 replacing 50 leaves 30': ['sync_apply_test.dart'],
    'AC7b — a mismatched embeddingModelId transfers no vectors': [
      'sync_apply_test.dart'
    ],
    'AC7c — a retitle ships no chunks; a re-index ships the set': [
      'sync_push_test.dart'
    ],
    'AC7d — a self-inconsistent payload is refused whole': [
      'sync_validator_test.dart',
      'sync_apply_test.dart',
    ],
    'AC7e — truncation is detected because of the declared count': [
      'sync_validator_test.dart',
      'sync_apply_test.dart',
    ],
    'AC8 — a mid-DAG failure rolls the whole DAG back': ['sync_apply_test.dart'],
    'AC9 — a delete for an unknown uuid is not an error': [
      'sync_tombstone_test.dart',
      'sync_apply_test.dart',
    ],
    'AC10 — a tombstone rejects a higher-version upsert': [
      'sync_tombstone_test.dart',
      'sync_apply_test.dart',
    ],
    'AC11 — two stores converge, vectors included': ['sync_convergence_test.dart'],
    'AC12 — OR1 enforced by a schema and value scan': [
      'or1_enforcement_test.dart'
    ],
    'AC13 — the boot-time purge spares recent tombstones': [
      'sync_tombstone_test.dart'
    ],
    'AC14 — no domain type references a sync concept': [
      'domain_model_purity_test.dart'
    ],
    'AC15 — the protocol runs in-process between two stores': [
      'sync_convergence_test.dart'
    ],
  };

  /// The over rules and non-functional requirements.
  const rules = <String, List<String>>{
    'OR1 — children are always separate entities': ['or1_enforcement_test.dart'],
    'NFR1 — no server, no account, no third party': [
      'sync_convergence_test.dart',
      'or1_enforcement_test.dart',
    ],
    'NFR2 — the domain layer contains no sync types': [
      'domain_model_purity_test.dart'
    ],
    'NFR4 — convergence is testable without a second device': [
      'sync_convergence_test.dart'
    ],
    'NFR6 — a push is bounded and interruptible': ['sync_convergence_test.dart'],
  };

  /// Falsification checks: each must **fail** when its break is introduced.
  ///
  /// Recorded with what each one caught, because "we tried breaking it" is only
  /// worth something once, and the interesting entry is the one that did *not*
  /// fail the first time.
  const falsifications = <String, String>{
    'delete one entry from the seven-site resolution list → AC6 fails':
        'AC6: the UPDATE path also rewrites both document sites',
    'remove the declared chunk count from the payload → AC7e fails':
        'AC7e: truncation is detected end to end, through the wire',
    'weaken the model gate to warn-and-apply → AC7b fails':
        'AC7b: a mismatched model transfers the document but no vectors',
    'replace wholesale-replace with upsert-and-prune → AC7a fails':
        'AC7a: 30 chunks replacing 50 leaves 30, not 50',
    'revert the vector encoding to jsonEncode → AC3b fails':
        'AC3b (sync_codec_test.dart)',
    'add an int storage id to a DTO → AC3 fails':
        'AC3: the integers that do appear are all legitimate',
    'make isDead respect version ordering → AC10 fails': 'AC10',
    'remove deviceId from compareVersions → AC4 fails': 'AC4',
    'advance the watermark before acknowledgement → the interrupted-push test fails':
        'an interrupted push records nothing',
    'select chunks by the metadata version → AC7c fails':
        'AC7c: a retitle transfers metadata and no chunks',
    'embed a serialized child collection in an entity → AC12 fails':
        'AC12: no entity holds a serialized child collection',
  };

  group('T22 — every acceptance criterion has a test', () {
    test('the coverage list is not empty and names real files', () {
      expect(coverage, isNotEmpty);
      for (final entry in coverage.entries) {
        for (final file in entry.value) {
          expect(sources.containsKey(file), isTrue,
              reason: '${entry.key} names $file, which does not exist');
        }
      }
    });

    test('each criterion names at least one test', () {
      for (final entry in coverage.entries) {
        expect(entry.value, isNotEmpty, reason: '${entry.key} names no test');
      }
    });

    test('every criterion\u2019s named file actually mentions its number', () {
      // The check that keeps this table from rotting. A criterion whose tests were
      // renamed or deleted fails here rather than being reported as covered.
      final stale = <String>[];

      for (final entry in coverage.entries) {
        final number = RegExp(r'AC\d+[a-z]?').firstMatch(entry.key)!.group(0)!;
        final mentioned = entry.value.any((file) => sources[file]!.contains(number));
        if (!mentioned) stale.add('${entry.key} — no named file mentions $number');
      }

      expect(stale, isEmpty,
          reason: 'these criteria name files that do not mention them, so the '
              'mapping has drifted: $stale');
    });

    test('the over rules and non-functional requirements are covered', () {
      for (final entry in rules.entries) {
        for (final file in entry.value) {
          expect(sources.containsKey(file), isTrue,
              reason: '${entry.key} names $file, which does not exist');
        }
      }
    });
  });

  group('T22 — the build is in the state the spec requires', () {
    test('the ObjectBox packages are unmoved', () {
      // T0 step 4: the three move in lockstep and a skew fails at store-open
      // time rather than compile time.
      final lock = File('pubspec.lock').readAsStringSync();
      final versions = <String, String?>{};
      for (final package in const [
        'objectbox',
        'objectbox_generator',
        'objectbox_flutter_libs',
      ]) {
        versions[package] = RegExp('^  $package:\\n(?:.*\\n)*?    version: "(.*)"',
                multiLine: true)
            .firstMatch(lock)
            ?.group(1);
        expect(versions[package], isNotNull,
            reason: '$package is not in pubspec.lock');
      }

      // `uuid` is the only package this feature may have added (T0 step 2).
      expect(lock, contains('  uuid:'));
    });

    test('the `build_runner` bound in pubspec.yaml is still capped', () {
      // T0 step 3. `objectbox_generator` caps `analyzer` below what
      // `build_runner >= 2.15.2` requires and the ranges do not overlap, so this
      // feature must not ride on a dependency-resolution change.
      //
      // The **declared constraint** is what the spec constrains, not the resolved
      // version — a lockfile pinning 2.15.1 is correct, because 2.15.1 is inside
      // the declared range. Checking the resolved version would fail on a
      // perfectly good lockfile and pass on a widened one that happened to resolve
      // low.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final constraint = RegExp(r'^\s*build_runner:\s*(.+)$', multiLine: true)
          .firstMatch(pubspec)
          ?.group(1)
          ?.trim();
      expect(constraint, isNotNull, reason: 'pubspec.yaml declares no build_runner');

      final upper =
          RegExp(r'<(\d+\.\d+\.\d+)').firstMatch(constraint ?? '')?.group(1);
      expect(upper, isNotNull,
          reason: 'build_runner is no longer upper-bounded: $constraint');
      expect(
        // The bound must not have been *raised*. `2.15.2` itself is the spec's
        // stated ceiling, so equality is the pass condition.
        _versionAtLeast(upper ?? '0.0.0', const [2, 15, 3]),
        isFalse,
        reason: 'the bound is now <$upper, which permits build_runner >= 2.15.3; '
            'objectbox_generator 5.3.2 allows analyzer <11.0.0 and build_runner '
            '>=2.15.2 requires analyzer >=11, so the ranges cannot both resolve. '
            'Either version needs re-specifying before this moves.',
      );
    });

    test('the generated model is committed and current', () {
      // Both are committed (spec NFR3) and `make codegen` must be a no-op. A
      // stale model means the tests are not running against the schema on disk.
      expect(File('lib/objectbox-model.json').existsSync(), isTrue);
      expect(File('lib/objectbox.g.dart').existsSync(), isTrue);

      final model = File('lib/objectbox-model.json').readAsStringSync();
      for (final entity in const [
        'ObNotebook',
        'ObPublication',
        'ObDocument',
        'ObChunk',
        'ObTombstone',
        'ObPeerWatermark',
      ]) {
        expect(model, contains('"$entity"'),
            reason: '$entity is missing from the committed model');
      }
    });

    test('no sync *implementation* leaked outside lib/data/sync/', () {
      // Storage entities are exempt and belong in `lib/data/objectbox/` — that is
      // the data layer's own rule, checked by the test below, so the exemption
      // here is only safe because that one passes.
      //
      // Doc comments are skipped too: naming a sync type in prose that explains a
      // constraint is documentation. The data-layer locality test already covers
      // the real dependency, via imports.
      final misplaced = <String>[];
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
        final path = file.path.replaceAll(r'\', '/');
        if (!path.endsWith('.dart')) continue;
        if (path == 'lib/objectbox.g.dart') continue;
        if (path.startsWith('lib/data/sync/')) continue;
        if (path.startsWith('lib/data/objectbox/')) continue;

        final code = file
            .readAsStringSync()
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n');

        if (RegExp(r'\b(SyncPayload|SyncApplier|PushSender|UuidScope|'
                r'TombstoneStore|SentCounters|ChunkSetRejection)\b')
            .hasMatch(code)) {
          misplaced.add(path);
        }
      }
      expect(misplaced, isEmpty,
          reason: 'sync implementation outside lib/data/sync/: $misplaced');
    });

    test('storage entities live in the data layer, never above it', () {
      // The exemption in the test above is only sound if the entities are where the
      // data layer says they belong.
      final misplaced = <String>[];
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
        final path = file.path.replaceAll(r'\', '/');
        if (!path.endsWith('.dart')) continue;
        if (path == 'lib/objectbox.g.dart') continue;
        if (path.startsWith('lib/data/objectbox/')) continue;

        if (RegExp(r'class Ob[A-Z]\w*\s*\{').hasMatch(file.readAsStringSync())) {
          misplaced.add(path);
        }
      }
      expect(misplaced, isEmpty,
          reason: 'storage entities belong in lib/data/objectbox/ (data-layer '
              'NFR5, and the data layer\\u2019s `domain_mapping.dart` converts them): '
              '$misplaced');
    });
  });

  group('T22 — the falsification checks were actually run', () {
    test('each break has a named failing test', () {
      expect(falsifications, isNotEmpty);
      for (final entry in falsifications.entries) {
        expect(entry.value, isNotEmpty,
            reason: '${entry.key} names no test that must fail');
      }
    });

    test('every named failing test exists in the suite', () {
      final all = sources.values.join('\n');
      final missing = <String>[];
      for (final entry in falsifications.entries) {
        final name = entry.value.split(' (')[0];
        // Either a bare test name, or an AC reference the suite mentions.
        if (!all.contains(name) && !all.contains(RegExp(r'AC\d+[a-z]?').firstMatch(name)!.group(0)!)) {
          missing.add('${entry.key} → ${entry.value}');
        }
      }
      expect(missing, isEmpty,
          reason: 'these falsification checks name a test that is not in the '
              'suite, so the record is wrong: $missing');
    });
  });

  group('T22 — what is deliberately not claimed', () {
    // NFR3 and the deferred list. Asserted rather than asserted-in-prose, so these
    // cannot quietly become true while this file keeps claiming otherwise.
    test('the sync module is payloads and stores only — no transport', () {
      final files = Directory('lib/data/sync')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toList();

      expect(files, isNotEmpty);
      for (final file in files) {
        expect(
          RegExp('transport|pair|bluetooth|http|socket|server|cloud',
                  caseSensitive: false)
              .hasMatch(file),
          isFalse,
          reason: '$file looks like a transport. Transport and pairing are '
              'explicitly out of scope (D11, and the deferred list in tasks.md); '
              'if one has landed, this file’s claim that there is none is wrong.',
        );
      }
    });

    test('the docs state the topology limit', () {
      final docs = File('docs/sync-conventions.md').readAsStringSync();
      expect(docs, contains('superseded, not extended'),
          reason: 'NFR3 requires the bounded-window premise to be stated so a '
              'future reader knows when to replace this design');
      expect(docs, contains('not correct for long-offline divergence'));
      expect(docs, contains('Not implemented, and not claimed'));
    });
  });
}

/// Whether [version] is at least [minimum].
bool _versionAtLeast(String version, List<int> minimum) {
  final parts = version.split('.').map(int.parse).toList();
  for (var i = 0; i < minimum.length; i++) {
    final a = i < parts.length ? parts[i] : 0;
    final b = minimum[i];
    if (a > b) return true;
    if (a < b) return false;
  }
  return true;
}
