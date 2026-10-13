import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted user configuration. Targets are GitHub usernames or team slugs;
/// a team is written as `org/team-slug` (the org prefix is optional and will
/// be filled from [org] when omitted).
class Settings {
  final String token;
  final String org;
  final List<String> targets;
  final int pollIntervalSeconds;

  const Settings({
    this.token = '',
    this.org = '',
    this.targets = const [],
    this.pollIntervalSeconds = 60,
  });

  bool get isConfigured => token.isNotEmpty && org.isNotEmpty && targets.isNotEmpty;

  Settings copyWith({
    String? token,
    String? org,
    List<String>? targets,
    int? pollIntervalSeconds,
  }) =>
      Settings(
        token: token ?? this.token,
        org: org ?? this.org,
        targets: targets ?? this.targets,
        pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
      );
}

class SettingsService extends ChangeNotifier {
  static const _kToken = 'github_token';
  static const _kOrg = 'github_org';
  static const _kTargets = 'github_targets';
  static const _kPollInterval = 'poll_interval_seconds';
  static const _kNotifiedIds = 'notified_pr_ids';

  Settings _settings = const Settings();
  Settings get settings => _settings;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _settings = Settings(
      token: prefs.getString(_kToken) ?? '',
      org: prefs.getString(_kOrg) ?? '',
      targets: prefs.getStringList(_kTargets) ?? const [],
      pollIntervalSeconds: prefs.getInt(_kPollInterval) ?? 60,
    );
    notifyListeners();
  }

  Future<void> save(Settings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, s.token.trim());
    await prefs.setString(_kOrg, s.org.trim());
    await prefs.setStringList(
      _kTargets,
      s.targets.map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
    );
    await prefs.setInt(_kPollInterval, s.pollIntervalSeconds.clamp(15, 3600));
    await load();
  }

  /// IDs of PRs we have already sent a notification for. Persisted so a
  /// restart does not re-notify for everything currently in the list.
  Future<Set<int>> loadNotifiedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_kNotifiedIds) ?? const [])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
  }

  Future<void> saveNotifiedIds(Set<int> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kNotifiedIds, ids.map((i) => '$i').toList());
  }
}
