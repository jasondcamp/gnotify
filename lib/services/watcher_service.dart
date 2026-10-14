import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/pull_request.dart';
import 'github_service.dart';
import 'settings_service.dart';

/// Polls GitHub on an interval, keeps the current list of PRs awaiting
/// review, pushes the badge count to the menubar and fires a notification
/// the first time each PR shows up.
class WatcherService extends ChangeNotifier {
  static const _channel = MethodChannel('com.jasoncamp.gnotify/menubar');

  final GitHubService github;
  final SettingsService settingsService;

  WatcherService({required this.github, required this.settingsService});

  Timer? _timer;
  bool _polling = false;
  Set<int> _notifiedIds = {};

  List<PullRequest> _pullRequests = const [];
  List<PullRequest> get pullRequests => _pullRequests;

  DateTime? _lastUpdated;
  DateTime? get lastUpdated => _lastUpdated;

  String? _error;
  String? get error => _error;

  /// GitHub's own wording for the last error, when it gave one.
  String? _errorDetail;
  String? get errorDetail => _errorDetail;

  bool get isPolling => _polling;

  Future<void> start() async {
    _notifiedIds = await settingsService.loadNotifiedIds();
    settingsService.addListener(_onSettingsChanged);
    _restartTimer();
    await refresh();
  }

  void _onSettingsChanged() {
    github.token = settingsService.settings.token;
    _restartTimer();
    refresh();
  }

  void _restartTimer() {
    _timer?.cancel();
    final seconds = settingsService.settings.pollIntervalSeconds;
    _timer = Timer.periodic(Duration(seconds: seconds), (_) => refresh());
  }

  Future<void> refresh() async {
    if (_polling) return;
    final settings = settingsService.settings;
    github.token = settings.token;

    if (!settings.isConfigured) {
      _pullRequests = const [];
      _error = null;
      _errorDetail = null;
      _pushBadge(0);
      _pushTooltip('gnotify - Not configured');
      notifyListeners();
      return;
    }

    _polling = true;
    notifyListeners();

    try {
      final merged = <int, PullRequest>{};
      for (final rawTarget in settings.targets) {
        final target = _normalizeTarget(rawTarget);
        final results = await github.searchReviewRequests(org: settings.org, target: target);
        for (final pr in results) {
          merged[pr.id] = merged.containsKey(pr.id) ? merged[pr.id]!.mergeTargets(pr) : pr;
        }
      }

      final list = merged.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      final currentIds = list.map((p) => p.id).toSet();
      final fresh = list.where((p) => !_notifiedIds.contains(p.id)).toList();

      // Forget PRs that left the list so a re-requested review notifies again.
      _notifiedIds = _notifiedIds.intersection(currentIds);

      _pullRequests = list;
      _lastUpdated = DateTime.now();
      _error = null;
      _errorDetail = null;

      _pushBadge(list.length);
      final label = list.length == 1 ? '1 PR awaiting review' : '${list.length} PRs awaiting review';
      _pushTooltip('gnotify - $label');

      for (final pr in fresh) {
        await _notify(pr);
        _notifiedIds.add(pr.id);
      }
      if (fresh.isNotEmpty) await settingsService.saveNotifiedIds(_notifiedIds);
    } on GitHubException catch (e) {
      _error = switch (e.statusCode) {
        401 => 'Token rejected (401)',
        403 => 'Rate limited or forbidden (403)',
        422 => 'Token cannot search org ${settings.org}. Check its resource owner and repo access.',
        _ => 'GitHub error ${e.statusCode}: ${e.message}',
      };
      _errorDetail = e.message;
      _pushTooltip('gnotify - $_error');
    } catch (e) {
      _error = 'Network error';
      _errorDetail = '$e';
      _pushTooltip('gnotify - offline');
    } finally {
      _polling = false;
      notifyListeners();
    }
  }

  /// `@org/team` loses its `@`; everything else passes through. A target with
  /// a `/` is a team slug, anything else is a username.
  static String _normalizeTarget(String raw) {
    var t = raw.trim();
    if (t.startsWith('@')) t = t.substring(1);
    return t;
  }

  Future<void> _notify(PullRequest pr) async {
    try {
      await _channel.invokeMethod('notify', {
        'id': 'pr-${pr.id}',
        'title': 'Review requested: ${pr.repoName} #${pr.number}',
        'body': '${pr.title} — by ${pr.author}',
        'url': pr.htmlUrl,
      });
    } catch (e) {
      debugPrint('notify failed: $e');
    }
  }

  void _pushBadge(int count) {
    _channel.invokeMethod('updateBadge', count).catchError((_) {});
  }

  void _pushTooltip(String text) {
    _channel.invokeMethod('updateTooltip', text).catchError((_) {});
  }

  static Future<void> openUrl(String url) async {
    await _channel.invokeMethod('openUrl', url);
  }

  static Future<void> closePopover() async {
    await _channel.invokeMethod('closePopover');
  }

  static Future<void> quitApp() async {
    await _channel.invokeMethod('quit');
  }

  @override
  void dispose() {
    _timer?.cancel();
    settingsService.removeListener(_onSettingsChanged);
    super.dispose();
  }
}
