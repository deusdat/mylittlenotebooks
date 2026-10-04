import 'package:objectbox/objectbox.dart';

/// Storage entity for one OpenAI-compatible endpoint configuration
/// (settings-for-ai FR1).
///
/// The application-level identity is [uuid]; the int id is an ObjectBox storage
/// detail and never leaves the data layer.
///
/// **There is deliberately no token column.** The token is a bearer credential
/// and this store is an unencrypted file; it lives in the platform secret store
/// under `ai_config_token.<uuid>` instead (FR2, FR3). A future property named
/// `token`, `secret`, or `apiKey` here would be a defect, and a test asserts
/// none exists.
@Entity()
class ObAiConfig {
  @Id()
  int id = 0;

  /// Generated once, never reassigned. `@Unique()` rather than `@Index()`: a
  /// non-unique index permits duplicates, and a lookup by a duplicated uuid
  /// then returns an arbitrary one (peer-sync FR2).
  @Unique()
  String uuid;

  /// The user-facing name. Required by the UI, but not unique — the uuid is the
  /// identity (FR21 / plan D5).
  String label;

  /// The OpenAI-compatible base URL. Validated by the UI, stored opaque here.
  String endpoint;

  /// Whether this tuple may travel to the user's other devices (FR11–FR13).
  ///
  /// This is a product concept the user sets, not protocol vocabulary: the
  /// domain model learns it, but nothing under `lib/models/` learns about
  /// tombstones, watermarks, or DTOs.
  bool shared;

  /// Half of this record's last-write-wins version (peer-sync FR9, FR10); the
  /// `deviceId` half lives once per store.
  @Index()
  int versionCounter;

  @Property(type: PropertyType.dateUtc)
  DateTime createdAt;

  ObAiConfig({
    required this.uuid,
    required this.label,
    required this.endpoint,
    required this.shared,
    required this.createdAt,
    this.versionCounter = 0,
  });
}
