/// Last-write-wins versioning (spec FR9, FR10).
///
/// A [SyncVersion] is a **monotonic counter paired with a device id** — never a wall
/// clock. That choice is the whole reason this is trustworthy:
///
/// A laptop whose clock is five minutes fast would, under timestamp-based LWW,
/// win *every* conflict permanently — including against a correctly-clocked
/// phone. A counter has no such failure mode, because the winner is decided by
/// how many local edits have happened, not by whose clock is right.
///
/// The pair gives a **total order**, which is what makes the protocol converge:
/// two devices comparing the same two versions independently reach the same
/// winner without talking to each other.
typedef SyncVersion = ({int counter, String deviceId});

/// The version a record has before it has ever been edited locally.
///
/// Treated as older than everything, so a peer that has never seen a record
/// still accepts its first version.
const SyncVersion noVersion = (counter: 0, deviceId: '');

/// Total order over versions: counter first, then device id.
///
/// The device-id tiebreak exists so that two devices which independently edited
/// from the same base version still agree on a winner. Without it they would
/// each believe their own edit won, and the next push would flip-flop forever.
int compareVersions(SyncVersion a, SyncVersion b) {
  final byCounter = a.counter.compareTo(b.counter);
  if (byCounter != 0) return byCounter;
  return a.deviceId.compareTo(b.deviceId);
}

/// Whether [incoming] should replace [local] under last-write-wins.
bool supersedes(SyncVersion incoming, SyncVersion local) =>
    compareVersions(incoming, local) > 0;

/// The next version after editing a record locally.
///
/// Increments this device's own counter, keeping the device id. A record's
/// counter therefore only ever advances through edits made *on this device*,
/// which is what stops one device with a busy history from dominating forever.
SyncVersion nextVersion(SyncVersion current, String deviceId) =>
    (counter: current.counter + 1, deviceId: deviceId);

/// Whether this version was produced by [deviceId].
bool isLocalVersion(SyncVersion version, String deviceId) =>
    version.deviceId == deviceId;
