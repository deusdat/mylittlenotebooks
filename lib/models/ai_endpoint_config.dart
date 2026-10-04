/// One configured OpenAI-compatible endpoint (settings-for-ai FR5).
///
/// The domain value carries **no token**. It learns only [hasToken] — whether a
/// secret is held for this tuple — so a widget has no way to read or log the
/// credential (FR4, NFR2). The token lives behind `lib/data/secrets/`.
///
/// `shared` is the one piece of sharing vocabulary the domain holds: it is a
/// product concept ("share this with my other devices") the user sets directly,
/// not a protocol type. Tombstones, versions, watermarks, and DTOs stay in
/// `lib/data/sync/`.
class AiEndpointConfig {
  final String uuid;

  /// The user-facing name. Required, not unique.
  final String label;

  /// The OpenAI-compatible base URL.
  final String endpoint;

  /// Whether this tuple may travel to another device.
  final bool shared;

  /// Whether a token is currently held for this tuple.
  ///
  /// Derived from the secret store, never stored as a column (FR5).
  final bool hasToken;

  const AiEndpointConfig({
    required this.uuid,
    required this.label,
    required this.endpoint,
    required this.shared,
    required this.hasToken,
  });

  AiEndpointConfig copyWith({
    String? label,
    String? endpoint,
    bool? shared,
    bool? hasToken,
  }) =>
      AiEndpointConfig(
        uuid: uuid,
        label: label ?? this.label,
        endpoint: endpoint ?? this.endpoint,
        shared: shared ?? this.shared,
        hasToken: hasToken ?? this.hasToken,
      );
}
