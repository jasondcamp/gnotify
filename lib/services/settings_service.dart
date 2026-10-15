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

  /// Notify when a PR starts asking one of the targets for review.
  final bool notifyReviewRequests;

  /// Notify when a PR the token's user authored gets an approving review.
  final bool notifyApprovals;

  /// Notify when Copilot finishes reviewing a PR the token's user authored.
  final bool notifyCopilotReviews;

  const Settings({
    this.token = '',
    this.org = '',
    this.targets = const [],
    this.pollIntervalSeconds = 60,
    this.notifyReviewRequests = true,
    this.notifyApprovals = true,
    this.notifyCopilotReviews = true,
  });

  bool get isConfigured => token.isNotEmpty && org.isNotEmpty && targets.isNotEmpty;

  Settings copyWith({
    String? token,
    String? org,
    List<String>? targets,
    int? pollIntervalSeconds,
    bool? notifyReviewRequests,
    bool? notifyApprovals,
    bool? notifyCopilotReviews,
  }) =>
      Settings(
        token: token ?? this.token,
        org: org ?? this.org,
        targets: targets ?? this.targets,
        pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
        notifyReviewRequests: notifyReviewRequests ?? this.notifyReviewRequests,
        notifyApprovals: notifyApprovals ?? this.notifyApprovals,
        notifyCopilotReviews: notifyCopilotReviews ?? this.notifyCopilotReviews,
      );
}

class SettingsService extends ChangeNotifier {
  static const _kToken = 'github_token';
  static const _kOrg = 'github_org';
  static const _kTargets = 'github_targets';
  static const _kPollInterval = 'poll_interval_seconds';
  static const _kNotifyReviewRequests = 'notify_review_requests';
  static const _kNotifyApprovals = 'notify_approvals';
  static const _kNotifiedIds = 'notified_pr_ids';
  static const _kNotifyCopilot = 'notify_copilot_reviews';
  static const _kApprovedIds = 'approved_pr_ids';
  static const _kCopilotReviewIds = 'copilot_review_ids';

  Settings _settings = const Settings();
  Settings get settings => _settings;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _settings = Settings(
      token: prefs.getString(_kToken) ?? '',
      org: prefs.getString(_kOrg) ?? '',
      targets: prefs.getStringList(_kTargets) ?? const [],
      pollIntervalSeconds: prefs.getInt(_kPollInterval) ?? 60,
      notifyReviewRequests: prefs.getBool(_kNotifyReviewRequests) ?? true,
      notifyApprovals: prefs.getBool(_kNotifyApprovals) ?? true,
      notifyCopilotReviews: prefs.getBool(_kNotifyCopilot) ?? true,
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
    await prefs.setBool(_kNotifyReviewRequests, s.notifyReviewRequests);
    await prefs.setBool(_kNotifyApprovals, s.notifyApprovals);
    await prefs.setBool(_kNotifyCopilot, s.notifyCopilotReviews);
    await load();
  }

  /// IDs of PRs we have already sent a notification for. Persisted so a
  /// restart does not re-notify for everything currently in the list.
  Future<Set<int>> loadNotifiedIds() => _loadIds(_kNotifiedIds);
  Future<void> saveNotifiedIds(Set<int> ids) => _saveIds(_kNotifiedIds, ids);

  /// IDs of the user's own PRs already announced as approved. Null when the
  /// app has never recorded a baseline, so the first pass can stay silent.
  Future<Set<int>?> loadApprovedIds() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_kApprovedIds)) return null;
    return _loadIds(_kApprovedIds);
  }
  Future<void> saveApprovedIds(Set<int> ids) => _saveIds(_kApprovedIds, ids);

  /// IDs of Copilot reviews already announced. Null until a baseline exists.
  Future<Set<int>?> loadCopilotReviewIds() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_kCopilotReviewIds)) return null;
    return _loadIds(_kCopilotReviewIds);
  }
  Future<void> saveCopilotReviewIds(Set<int> ids) => _saveIds(_kCopilotReviewIds, ids);

  Future<Set<int>> _loadIds(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(key) ?? const [])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
  }

  Future<void> _saveIds(String key, Set<int> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, ids.map((i) => '$i').toList());
  }
}
