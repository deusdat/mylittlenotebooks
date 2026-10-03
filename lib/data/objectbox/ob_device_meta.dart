import 'package:objectbox/objectbox.dart';

/// Store-level metadata: this install's device id (spec FR10).
///
/// A single row with a fixed id of 1. The device id is read once and repeated in
/// every version, so storing it once here rather than as a string on every
/// record avoids carrying a repeated identifier through every row.
@Entity()
class ObDeviceMeta {
  @Id(assignable: true)
  int id = 1;

  String value;

  ObDeviceMeta({required this.id, required this.value});
}
