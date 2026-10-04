/// The **local** delete paths: cascade and tombstone, stamping a version so a
/// delete can be selected into a later push (peer-sync FR11, delete-notebook
/// FR5).
///
/// A delete has to travel, and delta selection compares versions — so a local
/// delete must advance the record's version, or it would be stuck at counter
/// zero and no peer would ever learn of it. The version is the record's own,
/// incremented once: a delete is the next edit to that record, and reusing its
/// counter keeps one version line per record rather than two that have to be
/// reconciled.
///
/// **The cascade physics live in the data layer.** This class calls
/// `ObjectBoxLibraryRepository` to remove rows and only ever writes tombstones.
/// That is the same split `deletePublication` / this class already had; it is
/// kept because a tombstone is a sync concept and a cascade is not.
///
/// **A tombstone is written in the same transaction as its delete.** Written
/// after a commit it could be lost, leaving a deleted object resurrectable by an
/// in-flight push; written before, a rollback leaves a live object nothing can
/// update. There is no safe order outside the transaction, so the data layer's
/// own `runInTransaction` is allowed to nest inside this one (ObjectBox reuses
/// the enclosing transaction).
library;

import 'package:mylittlenotebooks/data/objectbox/ob_ai_config.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_publication.dart';
import 'package:mylittlenotebooks/data/objectbox_library_repository.dart';
import 'package:mylittlenotebooks/data/sync/device_id.dart';
import 'package:mylittlenotebooks/data/sync/sync_tombstones.dart';
import 'package:mylittlenotebooks/data/sync/sync_version.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

class SyncDeleter {
  SyncDeleter({
    required Store store,
    String? deviceId,
    TombstoneStore? tombstones,
    this.faultHook,
  })  : _store = store,
        _deviceId = deviceId ?? resolveDeviceId(store),
        _tombstones = tombstones ?? TombstoneStore(store),
        _library = ObjectBoxLibraryRepository(store);

  final Store _store;
  final ObjectBoxLibraryRepository _library;
  final TombstoneStore _tombstones;
  final String _deviceId;

  /// Test-only seam, invoked **inside** the notebook-delete transaction after
  /// the cascade and before the tombstones. Production passes nothing.
  ///
  /// Throwing from here is a genuine mid-transaction failure: it proves the
  /// data-layer cascade and the tombstone writes roll back together (AC5).
  final void Function()? faultHook;

  /// Deletes a publication locally, cascading and tombstoning in one
  /// transaction (peer-sync FR11, FR17).
  void deletePublicationLocally(String publicationUuid) {
    final publication = _findPublication(publicationUuid);
    final version = nextVersion(
      publication == null ? noVersion : _versionOf(publication.versionCounter),
      _deviceId,
    );

    _store.runInTransaction(TxMode.write, () {
      if (publication != null) _library.deletePublication(publicationUuid);
      _tombstones.markDead(publicationUuid, versionCounter: version.counter);
      return null;
    });
  }

  /// Deletes a notebook locally: the notebook, every **exclusive** publication,
  /// and a tombstone for each, all in one transaction (delete-notebook FR4,
  /// FR5, FR11).
  ///
  /// A **shared** publication is left alone; only its edge to this notebook goes
  /// away with the notebook, exactly as the data-layer cascade does.
  ///
  /// A delete for a notebook this device never had is **idempotent**: it
  /// records a tombstone and returns without throwing, because a repeated or
  /// peer-driven delete must not fail (peer-sync FR12).
  void deleteNotebookLocally(String notebookUuid) {
    final notebook = _findNotebook(notebookUuid);
    if (notebook == null) {
      _store.runInTransaction(TxMode.write, () {
        _tombstones.markDead(notebookUuid);
        return null;
      });
      return;
    }

    final version = nextVersion(_versionOf(notebook.versionCounter), _deviceId);

    _store.runInTransaction(TxMode.write, () {
      // The data layer removes the notebook and its exclusive publications and
      // returns each cascaded publication's uuid and pre-delete counter. Its
      // own `runInTransaction` joins this one, so the rows and the tombstones
      // commit together.
      final cascaded = _library.deleteNotebook(notebookUuid);

      // The notebook's own tombstone, at the version it died at.
      _tombstones.markDead(notebookUuid, versionCounter: version.counter);

      // One tombstone per cascaded publication, each at its own next version.
      for (final publication in cascaded) {
        _tombstones.markDead(
          publication.uuid,
          versionCounter:
              nextVersion(_versionOf(publication.versionCounter), _deviceId)
                  .counter,
        );
      }

      faultHook?.call();
      return null;
    });
  }

  SyncVersion _versionOf(int counter) => (counter: counter, deviceId: _deviceId);

  /// Deletes an AI endpoint configuration locally: the row and its tombstone in
  /// one transaction (settings-for-ai FR9, FR14).
  ///
  /// The **token** is not touched here: the keychain cannot share an ObjectBox
  /// transaction, so the repository deletes it immediately after this call and
  /// boot reconciliation removes it if that fails (FR18). An absent uuid still
  /// tombstones, so an in-flight push cannot resurrect a tuple the user deleted.
  void deleteAiConfigLocally(String uuid) {
    final config = _findAiConfig(uuid);
    final version = nextVersion(
      config == null ? noVersion : _versionOf(config.versionCounter),
      _deviceId,
    );

    _store.runInTransaction(TxMode.write, () {
      if (config != null) _store.box<ObAiConfig>().remove(config.id);
      _tombstones.markDead(uuid, versionCounter: version.counter);
      return null;
    });
  }

  ObAiConfig? _findAiConfig(String uuid) {
    final query =
        _store.box<ObAiConfig>().query(ObAiConfig_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  ObNotebook? _findNotebook(String uuid) {
    final query = _store
        .box<ObNotebook>()
        .query(ObNotebook_.uuid.equals(uuid))
        .build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  ObPublication? _findPublication(String uuid) {
    final query = _store
        .box<ObPublication>()
        .query(ObPublication_.uuid.equals(uuid))
        .build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }
}
