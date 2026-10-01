import 'package:mylittlenotebooks/data/panel_state_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [PanelStateStore] backed by a single key on disk.
///
/// Uses [SharedPreferencesAsync] rather than the legacy cached
/// `SharedPreferences` API, which pub.dev marks for future deprecation and whose
/// local cache buys nothing for one boolean.
class PrefsPanelStateStore implements PanelStateStore {
  static const collapsedKey = 'nav_panel.collapsed';

  final SharedPreferencesAsync _prefs;

  PrefsPanelStateStore({SharedPreferencesAsync? prefs})
    : _prefs = prefs ?? SharedPreferencesAsync();

  @override
  Future<bool> readCollapsed() async {
    try {
      // A missing key reads as the expanded default. A wrongly-typed value
      // throws from the plugin, and is treated the same way: a panel that
      // fails to restore must still open.
      return await _prefs.getBool(collapsedKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> writeCollapsed(bool collapsed) =>
      _prefs.setBool(collapsedKey, collapsed);
}