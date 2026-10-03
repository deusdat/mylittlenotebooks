import 'package:objectbox/objectbox.dart';

/// Records that a uuid is dead (peer-sync FR12).
///
/// **No entity-type column.** A globally-unique uuid identifies what is dead on
/// its own, and the entity type is needed only at delete time to run the local
/// cascade — where the deleting code already knows the type. That constraint is
/// FR15's and it still holds.
///
/// **Local-only state.** Tombstones are never part of a payload (FR13). Devices
/// converge on deletes without exchanging them: the sender deletes and
/// tombstones locally, and the receiver does the same when the delete arrives.
/// What *does* travel is a delete record carrying this uuid and a version.
///
/// A tombstone **beats any live record, unconditionally, regardless of version**
/// (FR14). That is stronger than ordering and is what removes the resurrection
/// window — no sequence comparison can conclude that an upsert is newer than a
/// tombstone.
///
/// Purged after a year (FR16), which is safe only because long-late records do
/// not occur under the bounded-window topology (NFR3).
@Entity()
class ObTombstone {
  @Id()
  int id = 0;

  /// The uuid of the dead object. No entity type — see the class note.
  @Unique()
  String uuid;

  @Property(type: PropertyType.dateUtc)
  DateTime deletedAt;

  /// Half of the version this object died at (FR11).
  ///
  /// A delete has to travel, and FR11 selects a delta by version — so a delete
  /// needs a version, and the tombstone is where a delete is recorded. FR15
  /// constrains the *entity type* column, not this one, and the reason it gives
  /// ("a globally-unique uuid identifies what is dead") is unaffected.
  ///
  /// Zero means "died before this device tracked versions", which sorts as older
  /// than anything and is therefore always selected into a delta. That is the
  /// safe default: re-sending a delete is harmless, dropping one resurrects.
  @Index()
  int versionCounter;

  ObTombstone({
    required this.uuid,
    required this.deletedAt,
    this.versionCounter = 0,
  });
}
