/// Stable per-install device identity (spec FR10).
///
/// Only has to be **unique among devices that share a library**, not globally
/// unique — it is a tiebreaker, not a security principal. It is stored once per
/// install and never changes, so a record's version ordering does not shift
/// under a peer that has already seen it.
///
/// Deliberately not derived from anything device-identifying: a `deviceId` ends
/// up in payloads that a person may read while debugging a peer disagreement,
/// and it should mean nothing outside this library.
library;

import 'dart:io' show pid;

import 'package:mylittlenotebooks/data/objectbox/ob_device_meta.dart';
import 'package:mylittlenotebooks/objectbox.g.dart';
import 'package:objectbox/objectbox.dart';

/// Reads this install's device id, creating it on first use.
String resolveDeviceId(Store store) {
  final box = store.box<ObDeviceMeta>();
  final existing = box.query().build();
  try {
    final found = existing.findFirst();
    if (found != null && found.value.isNotEmpty) return found.value;
    if (found != null) {
      // The row exists (the first-run seeder writes it before any sync), but has
      // no device id yet. Preserve every other field — losing `seeded` here
      // would re-arm the first-run seed on the next launch.
      found.value = _mintDeviceId();
      box.put(found);
      return found.value;
    }
  } finally {
    existing.close();
  }

  final created = ObDeviceMeta(id: 1, value: _mintDeviceId());
  box.put(created);
  return created.value;
}

/// A short, opaque, install-scoped id.
///
/// Uses the process id and a timestamp rather than anything hardware-derived:
/// it must not leak a device fingerprint into a shared payload, and it does not
/// need to survive a reinstall (a reinstalled device is a new participant).
String _mintDeviceId() {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36);
  final process = pid.toRadixString(36);
  final noise = DateTime.now().microsecond.toRadixString(36);
  return 'd-$now-$process-$noise';
}
