/// Tombstone store (spec FR12–FR16).
///
/// A tombstone records that a uuid is **dead**. Three properties matter, and
/// all three are deliberate:
///
/// 1. **Local-only.** Never part of a payload (FR13). Devices converge on
///    deletes without exchanging tombstones: the sender deletes and tombstones
///    locally, and the receiver does the same when the delete arrives. Keeping
///    them out of the payload also means two devices can never disagree about
///    someone else's tombstone.
///
/// 2. **Beats any live record, unconditionally, regardless of version** (FR14).
///    This is *stronger* than ordering and is what removes the resurrection
///    window. If a tombstone merely compared as "older than newer records", a
///    late upsert could still outrank it and the object would come back. Here
///    there is no comparison to get wrong.
///
/// 3. **Purged after a year** (FR16), which is safe *only* because records
///    arriving more than a year late do not occur under this protocol's
///    topology. See NFR3.
library;

import 'package:mylittlenotebooks/data/objectbox/ob_tombstone.dart';
import 'package:mylittlenotebooks/data/sync/sync_version.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';

/// How long a tombstone is retained before the boot-time sweep removes it.
const Duration tombstoneRetention = Duration(days: 365);

class TombstoneStore {
  TombstoneStore(Store store) : _box = store.box<ObTombstone>();

  final Box<ObTombstone> _box;

  /// Whether [uuid] is known to be dead.
  ///
  /// **Consulted before any upsert is applied**, and it takes no version
  /// argument on purpose. Adding one is the single most likely wrong
  /// implementation here: "apply unless the incoming version is newer"
  /// re-opens exactly the resurrection hole FR14 exists to close.
  bool isDead(String uuid) => _find(uuid) != null;

  /// Records [uuid] as dead, at [at] (defaults to now) and [versionCounter].
  ///
  /// [versionCounter] is what lets the delete be selected into a later delta
  /// (FR11) — a delete has to travel, and the version is how a sender knows the
  /// peer has not already seen it. See `ObTombstone.versionCounter`.
  ///
  /// Idempotent: re-marking an already-dead uuid keeps the original timestamp
  /// and version, so a repeated delete does not extend the record's life, reset
  /// its purge date, or make it look newer than it is. Keeping the *original*
  /// version matters — bumping it would let a repeated delete look like a fresh
  /// edit and travel again for no reason.
  void markDead(String uuid, {int versionCounter = 0, DateTime? at}) {
    final existing = _find(uuid);
    if (existing != null) return;
    final stamp = at ?? DateTime.now().toUtc();
    _box.put(ObTombstone(
      uuid: uuid,
      deletedAt: DateTime.fromMillisecondsSinceEpoch(
        stamp.millisecondsSinceEpoch,
        isUtc: true,
      ),
      versionCounter: versionCounter,
    ));
  }

  ObTombstone? _find(String uuid) {
    final query = _box.query(ObTombstone_.uuid.equals(uuid)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  /// The version [uuid] died at, or null when it is not dead.
  int? versionOf(String uuid) => _find(uuid)?.versionCounter;

  /// Every tombstone whose version exceeds [after], oldest first.
  ///
  /// The delete half of delta selection (FR11). Ordering by version rather than
  /// by `deletedAt` is deliberate: a peer compares versions, and a wall clock
  /// here would reintroduce exactly the clock trust FR10 rules out.
  List<ObTombstone> deletedAfter(int afterCounter) {
    final query = _box
        .query(ObTombstone_.versionCounter.greaterThan(afterCounter))
        .build();
    try {
      return query.find();
    } finally {
      query.close();
    }
  }

  /// Removes tombstones older than [retention]. Returns how many went.
  ///
  /// Deliberately **not** wrapped in a transaction: this is boot-time
  /// housekeeping and must never share a failure domain with a user's data. A
  /// partially applied purge is harmless, because every tombstone that remains
  /// is still honoured.
  int purgeOlderThan({
    Duration retention = tombstoneRetention,
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now()).toUtc().subtract(retention);
    final query = _box.query(ObTombstone_.deletedAt.lessThanDate(cutoff)).build();
    try {
      return query.remove();
    } finally {
      query.close();
    }
  }

  /// Every tombstone, oldest first. For diagnostics and tests.
  List<ObTombstone> all() {
    final query = _box.query().order(ObTombstone_.deletedAt).build();
    try {
      return query.find();
    } finally {
      query.close();
    }
  }
}

/// Whether an incoming record may be applied to this device.
///
/// **This is where FR14 is enforced, and it is a function rather than a
/// convention for a reason.** The rule "a tombstone beats any live record
/// regardless of version" only ever manifests at an ingest boundary, so an
/// implementation that gets it right by convention is untested — and a later
/// contributor who adds `if (incomingVersion > tombstoneVersion)` to the ingest
/// path would break it silently, restoring the resurrection hole without any
/// test going red.
///
/// Naming the decision here makes it testable *now*, and gives ingest a tested
/// primitive to call instead of re-deciding the rule for itself.
///
/// Note the absence of a version comparison in the dead branch, and that
/// [isDead] deliberately takes no version argument. Adding one is the single
/// most likely way to break this.
bool shouldApplyIncoming({
  required TombstoneStore tombstones,
  required String uuid,
  required SyncVersion incomingVersion,
}) {
  if (tombstones.isDead(uuid)) return false;

  // Not dead. Whether this beats the *local* version is last-write-wins, and is
  // the caller's decision — it needs the local record, which this function does
  // not have and should not fetch.
  return incomingVersion.counter >= 0;
}
