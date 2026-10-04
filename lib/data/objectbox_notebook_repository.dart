import 'package:mylittlenotebooks/data/identity.dart';
import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_notebook.dart';
import 'package:mylittlenotebooks/data/sync/sync_deleter.dart';
import 'package:mylittlenotebooks/domain_mapping.dart';
import 'package:mylittlenotebooks/models/notebook.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// Durable [NotebookRepository] backed by ObjectBox.
///
/// **Synchronous throughout**, because the router's `redirect` guard calls
/// `exists` inside `go_router`'s navigation machinery with no way to await
/// (spec FR18, plan I6). `Box` is synchronous, so this costs nothing — do not
/// make these methods `async`.
///
/// Notebook ordering is creation order, oldest first, unchanged from the shell
/// spec (FR8, D5).
class ObjectBoxNotebookRepository implements NotebookRepository {
  ObjectBoxNotebookRepository(this._store, {SyncDeleter? deleter})
      : _box = _store.box<ObNotebook>(),
        _deleter = deleter ?? SyncDeleter(store: _store);

  final Store _store;
  final Box<ObNotebook> _box;

  /// The single notebook-delete entry point.
  ///
  /// A notebook delete must tombstone the notebook **and** every publication it
  /// cascades, in the same transaction (delete-notebook FR11), so the physical
  /// removal and the tombstone writes are not reachable apart. Delegating to
  /// [SyncDeleter] is what keeps that true; this repository does not delete a
  /// notebook itself.
  final SyncDeleter _deleter;

  /// The store is exposed so sibling repositories share one connection rather
  /// than each holding their own; ObjectBox permits exactly one open store per
  /// directory.
  Store get store => _store;

  @override
  List<Notebook> list() {
    final query = _box.query().order(ObNotebook_.createdAt).build();
    try {
      return query.find().map((entity) => entity.toDomain()).toList();
    } finally {
      query.close();
    }
  }

  @override
  Notebook create() {
    // RFC 9562 v7. The previous scheme was a microsecond timestamp plus a
    // process-local counter, which collides across devices by construction:
    // two devices minting in the same microsecond with the same starting
    // counter produce the same identifier. That is the one failure sync cannot
    // tolerate, and it was already load-bearing because this id is a route
    // parameter.
    final uuid = newUuidV7();
    final clash = _box.query(ObNotebook_.uuid.equals(uuid)).build();
    try {
      if (clash.findFirst() != null) {
        throw StateError('notebook uuid collision: $uuid');
      }
    } finally {
      clash.close();
    }
    final entity = ObNotebook(
      uuid: uuid,
      title: 'Notebook ${_nextOrdinal()}',
      // Millisecond precision, matching what `PropertyType.dateUtc` persists —
      // otherwise the value returned by `create` differs from the one read back
      // (spec AC4, applied to notebooks by the same reasoning).
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().toUtc().millisecondsSinceEpoch,
        isUtc: true,
      ),
      // A creation is a modification, so the record starts at 1 (peer-sync FR9).
      versionCounter: 1,
    );
    _box.put(entity);
    return entity.toDomain();
  }

  @override
  bool exists(String id) {
    final query = _box.query(ObNotebook_.uuid.equals(id)).build();
    try {
      return query.findFirst() != null;
    } finally {
      query.close();
    }
  }

  @override
  void delete(String id) => _deleter.deleteNotebookLocally(id);

  /// The entity behind a domain value, for repositories that need to mutate the
  /// association rather than read it.
  ObNotebook entityFor(String uuid) {
    final query = _box.query(ObNotebook_.uuid.equals(uuid)).build();
    try {
      final entity = query.findFirst();
      if (entity == null) throw StateError('no notebook with uuid $uuid');
      return entity;
    } finally {
      query.close();
    }
  }

  /// Auto-named `Notebook N`, oldest first — preserving the shell spec's seeded
  /// behaviour (FR7, D6). The ordinal counts existing notebooks rather than a
  /// monotonic counter, so it stays correct after a delete.
  int _nextOrdinal() => _box.count() + 1;
}
