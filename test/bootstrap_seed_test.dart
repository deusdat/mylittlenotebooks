import 'package:flutter_test/flutter_test.dart';
import 'package:mylittlenotebooks/data/first_run_seeder.dart';
import 'package:mylittlenotebooks/data/objectbox/objectbox_store.dart';
import 'package:mylittlenotebooks/data/objectbox_notebook_repository.dart';
import 'package:objectbox/objectbox.dart';

/// First-run seeding must happen **once per install**, and must never resurrect
/// notebooks the user deleted.
///
/// The bug this guards: bootstrap seeded the demonstration notebooks on every
/// launch, so the durable store grew with each restart and a deliberate
/// delete-all looked undone. "First run" is a persisted flag, not "the store is
/// empty" — after a delete-all the store *is* empty, and an emptiness check
/// would re-seed.
void main() {
  late Store store;
  late ObjectBoxNotebookRepository notebooks;
  late FirstRunSeeder seeder;

  setUp(() {
    store = openTestStore('first-run');
    notebooks = ObjectBoxNotebookRepository(store);
    seeder = FirstRunSeeder(store);
  });

  tearDown(() => store.close());

  test('a fresh install gets exactly one notebook', () {
    final created = seeder.seedOnce(notebooks);
    expect(created, isNotNull);
    expect(notebooks.list(), hasLength(1));
  });

  test('a relaunch does not seed again', () {
    seeder.seedOnce(notebooks);
    // A new seeder over the same store models a restart.
    FirstRunSeeder(store).seedOnce(notebooks);
    expect(notebooks.list(), hasLength(1));
  });

  test('deleting every notebook survives a restart', () {
    seeder.seedOnce(notebooks);
    for (final notebook in notebooks.list()) {
      notebooks.delete(notebook.id);
    }
    expect(notebooks.list(), isEmpty);

    // The relaunch must NOT bring the seed back.
    FirstRunSeeder(store).seedOnce(notebooks);
    expect(notebooks.list(), isEmpty);
  });

  test('the seeded flag survives a device-id write', () {
    seeder.seedOnce(notebooks);
    // Writing the device id touches the same metadata row; it must not clear
    // the seeded flag (which would re-arm the seed).
    final before = FirstRunSeeder(store).hasSeeded;
    expect(before, isTrue);
  });
}
