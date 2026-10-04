import 'package:objectbox/objectbox.dart';

/// Store-level metadata: this install's device id (spec FR10) and whether the
/// first-run notebook seed has happened.
///
/// A single row with a fixed id of 1. The device id is read once and repeated in
/// every version, so storing it once here rather than as a string on every
/// record avoids carrying a repeated identifier through every row.
@Entity()
class ObDeviceMeta {
  @Id(assignable: true)
  int id = 1;

  String value;

  /// Whether the demonstration notebook has already been seeded.
  ///
  /// **A persisted flag, not "is the store empty".** Those are different
  /// questions: a first install has never seeded, whereas a user who deleted
  /// every notebook *did* seed and must be left empty. Keying the seed off the
  /// row count would resurrect the demonstration on every launch after a
  /// delete-all — the exact bug this flag exists to prevent.
  bool seeded;

  ObDeviceMeta({required this.id, required this.value, this.seeded = false});
}
