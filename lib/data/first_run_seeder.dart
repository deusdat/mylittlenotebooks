import 'package:mylittlenotebooks/data/notebook_repository.dart';
import 'package:mylittlenotebooks/data/objectbox/ob_device_meta.dart';
import 'package:mylittlenotebooks/models/notebook.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// Seeds the demonstration notebook exactly once per install (shell spec D10).
///
/// **A persisted "seeded" flag distinguishes a first install from a user who
/// deleted every notebook.** Those are different questions, and keying the seed
/// off "is the store empty" conflates them: after a delete-all the store is empty
/// again, so an emptiness check would resurrect the demonstration on the next
/// launch. That is the bug this class exists to prevent — a durable store must
/// not undo a deliberate deletion.
///
/// The flag lives on [ObDeviceMeta] (the store-level metadata row that already
/// holds the device id), so it survives restarts with the data it governs.
class FirstRunSeeder {
  FirstRunSeeder(Store store) : _meta = store.box<ObDeviceMeta>();

  final Box<ObDeviceMeta> _meta;

  /// Whether this install has already run the first-run seed.
  bool get hasSeeded {
    final query = _meta.query(ObDeviceMeta_.id.equals(1)).build();
    try {
      return query.findFirst()?.seeded ?? false;
    } finally {
      query.close();
    }
  }

  /// Seeds [repo] with the first-run notebook and records that it happened.
  ///
  /// Does nothing when the install has already seeded — even if every notebook
  /// has since been deleted, which is the point. Returns the notebook it created,
  /// or null when seeding was skipped.
  Notebook? seedOnce(NotebookRepository repo) {
    if (hasSeeded) return null;
    final created = repo.create();
    _markSeeded();
    return created;
  }

  void _markSeeded() {
    final query = _meta.query(ObDeviceMeta_.id.equals(1)).build();
    try {
      final row = query.findFirst();
      if (row != null) {
        row.seeded = true;
        _meta.put(row);
      } else {
        // The device id row is normally written first by `resolveDeviceId`, but
        // do not depend on ordering: create the row if it is absent.
        _meta.put(ObDeviceMeta(id: 1, value: '', seeded: true));
      }
    } finally {
      query.close();
    }
  }
}
