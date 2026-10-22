import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/pull_request.dart';
import 'app_log.dart';
import 'github_service.dart';
import 'settings_service.dart';

/// Polls GitHub on an interval with a single request per tick, keeps both
/// tabs' lists, pushes the badge count to the menubar, and announces review
/// requests, approvals and Copilot reviews once each.
class WatcherService extends ChangeNotifier {
  static const _channel = MethodChannel('com.jasoncamp.gnotify/menubar');

  /// Popover opens and other soft triggers are ignored this soon after a poll.
  static const _debounce = Duration(seconds: 10);
  static const _minBackoff = Duration(seconds: 60);

  /// An announced PR is forgotten only after it has been absent from this
  /// many consecutive polls. GitHub's search index occasionally returns a
  /// blank or partial result; forgetting on the first miss replayed every
  /// notification when the next poll came back full.
  static const forgetAfterPolls = 5;
  static const _maxBackoff = Duration(minutes: 15);

  final GitHubService github;
  final SettingsService settingsService;
  final AppLog _log = AppLog.instance;

  WatcherService({required this.github, required this.settingsService});

  Timer? _timer;
  bool _polling = false;
  DateTime? _lastPollAt;

  Set<int> _notifiedIds = {};
  Set<int> _approvedIds = {};
  Set<int> _copilotSeenIds = {};
  final Map<int, int> _missingNotified = {};
  final Map<int, int> _missingApproved = {};
  final Map<int, int> _missingCopilot = {};
  int _lastTotal = 0;

  /// Silent first pass for approvals / Copilot after install or re-enable.
  bool _approvalsNeedBaseline = true;
  bool _copilotNeedBaseline = true;
  bool _lastNotifyApprovals = true;
  bool _lastNotifyCopilot = true;

  /// Set when persisted ids predate the current id scheme; the next
  /// successful poll records everything silently instead of announcing it.
  bool _idsNeedRebaseline = false;

  DateTime? _backoffUntil;
  int _backoffStrikes = 0;

  List<PullRequest> _pullRequests = const [];
  List<PullRequest> get pullRequests => _pullRequests;

  List<OwnPullRequest> _myPullRequests = const [];
  List<OwnPullRequest> get myPullRequests => _myPullRequests;

  RateLimitInfo? _rateLimit;
  RateLimitInfo? get rateLimit => _rateLimit;

  DateTime? _lastUpdated;
  DateTime? get lastUpdated => _lastUpdated;

  DateTime? get backoffUntil => _backoffUntil;

  String? _error;
  String? get error => _error;

  /// GitHub's own wording for the last error, when it gave one.
  String? _errorDetail;
  String? get errorDetail => _errorDetail;

  bool get isPolling => _polling;

  Future<void> start() async {
    _notifiedIds = await settingsService.loadNotifiedIds();
    final approved = await settingsService.loadApprovedIds();
    _approvedIds = approved ?? {};
    _approvalsNeedBaseline = approved == null;
    final copilotSeen = await settingsService.loadCopilotReviewIds();
    _copilotSeenIds = copilotSeen ?? {};
    _copilotNeedBaseline = copilotSeen == null;
    final s = settingsService.settings;
    _lastNotifyApprovals = s.notifyApprovals;
    _lastNotifyCopilot = s.notifyCopilotReviews;

    final idsVersion = await settingsService.loadIdsVersion();
    _idsNeedRebaseline = idsVersion < SettingsService.currentIdsVersion;
    if (_idsNeedRebaseline) {
      _log.info('id scheme $idsVersion -> ${SettingsService.currentIdsVersion}: next poll baselines silently');
    }

    settingsService.addListener(_onSettingsChanged);
    _restartTimer();
    await refresh(force: true);
  }

  void _onSettingsChanged() {
    final s = settingsService.settings;
    github.token = s.token;
    if (s.notifyApprovals && !_lastNotifyApprovals) _approvalsNeedBaseline = true;
    _lastNotifyApprovals = s.notifyApprovals;
    if (s.notifyCopilotReviews && !_lastNotifyCopilot) _copilotNeedBaseline = true;
    _lastNotifyCopilot = s.notifyCopilotReviews;
    _backoffUntil = null;
    _backoffStrikes = 0;
    _restartTimer();
    refresh(force: true);
  }

  void _restartTimer() {
    _timer?.cancel();
    final seconds = settingsService.settings.pollIntervalSeconds;
    _timer = Timer.periodic(Duration(seconds: seconds), (_) => refresh());
  }

  /// [force] skips the debounce (user pressed Refresh, settings changed) but
  /// never the rate-limit backoff.
  Future<void> refresh({bool force = false}) async {
    if (_polling) return;
    final now = DateTime.now();
    if (_backoffUntil != null && now.isBefore(_backoffUntil!)) return;
    if (!force && _lastPollAt != null && now.difference(_lastPollAt!) < _debounce) return;

    final settings = settingsService.settings;
    github.token = settings.token;

    if (!settings.isConfigured) {
      _pullRequests = const [];
      _myPullRequests = const [];
      _error = null;
      _errorDetail = null;
      _pushBadge(0);
      _pushTooltip('gnotify - Not configured');
      notifyListeners();
      return;
    }

    _polling = true;
    _lastPollAt = now;
    notifyListeners();

    try {
      final sw = Stopwatch()..start();
      final result = await github.poll(org: settings.org, targets: settings.targets);
      sw.stop();
      _rateLimit = result.rateLimit;
      final rl = result.rateLimit;
      _log.info('poll ok: ${result.requests} request(s) in ${sw.elapsedMilliseconds}ms, '
          'toReview=${result.toReview.length} mine=${result.mine.length}'
          '${rl == null ? '' : ', budget ${rl.remaining}/${rl.limit} (cost ${rl.cost})'}');

      final total = result.toReview.length + result.mine.length;
      if (total == 0 && _lastTotal > 0) {
        _log.warn('empty result after $_lastTotal PRs last poll; announced ids are kept for '
            '$forgetAfterPolls polls in case the search index blinked');
      }
      _lastTotal = total;

      _pullRequests = result.toReview;
      _myPullRequests = result.mine;
      _lastUpdated = DateTime.now();
      _error = null;
      _errorDetail = null;
      _backoffUntil = null;
      _backoffStrikes = 0;

      _pushBadge(_pullRequests.length);
      final n = _pullRequests.length;
      _pushTooltip('gnotify - ${n == 1 ? '1 PR awaiting review' : '$n PRs awaiting review'}');

      if (_idsNeedRebaseline) {
        _notifiedIds = _pullRequests.map((p) => p.id).toSet();
        _missingNotified.clear();
        await settingsService.saveNotifiedIds(_notifiedIds);
        _approvalsNeedBaseline = true;
        _copilotNeedBaseline = true;
        _idsNeedRebaseline = false;
        await settingsService.saveIdsVersion(SettingsService.currentIdsVersion);
        _log.info('ids rebaselined: ${_notifiedIds.length} review requests recorded silently');
      }

      await _announceReviewRequests(_pullRequests, notify: settings.notifyReviewRequests);
      await _announceCopilotReviews(_myPullRequests, notify: settings.notifyCopilotReviews);
      await _announceApprovals(_myPullRequests, notify: settings.notifyApprovals);
    } on GitHubException catch (e) {
      _handleGitHubError(e, settings.org);
    } catch (e) {
      _error = 'Network error';
      _errorDetail = '$e';
      _log.warn('poll failed: $e');
      _pushTooltip('gnotify - offline');
    } finally {
      _polling = false;
      notifyListeners();
    }
  }

  void _handleGitHubError(GitHubException e, String org) {
    _errorDetail = e.message;
    if (e.rateLimited) {
      _backoffStrikes++;
      final exp = _minBackoff * math.pow(2, _backoffStrikes - 1).toInt();
      var wait = e.retryAfter ?? exp;
      if (wait < _minBackoff) wait = _minBackoff;
      if (wait > _maxBackoff) wait = _maxBackoff;
      _backoffUntil = DateTime.now().add(wait);
      final at = _backoffUntil!;
      final hh = at.hour.toString().padLeft(2, '0');
      final mm = at.minute.toString().padLeft(2, '0');
      _error = 'GitHub rate limit, next try at $hh:$mm';
      _log.warn('rate limited (${e.statusCode}): ${e.message}; '
          'retryAfter=${e.retryAfter?.inSeconds}s strikes=$_backoffStrikes waiting ${wait.inSeconds}s');
    } else {
      _error = switch (e.statusCode) {
        401 => 'Token rejected (401)',
        403 => 'Forbidden (403)',
        422 => 'Token cannot search org $org. Check its resource owner and repo access.',
        _ => 'GitHub error ${e.statusCode}: ${e.message}',
      };
      _log.warn('poll failed (${e.statusCode}): ${e.message}');
    }
    _pushTooltip('gnotify - $_error');
  }

  /// Seen ids are tracked even with notifications off, so switching them on
  /// later only announces PRs that arrive after that point. A PR that leaves
  /// the list and comes back (review re-requested) is announced again.
  Future<void> _announceReviewRequests(List<PullRequest> list, {required bool notify}) async {
    final currentIds = list.map((p) => p.id).toSet();
    final fresh = list.where((p) => !_notifiedIds.contains(p.id)).toList();
    final pruned = pruneSeen(_notifiedIds, currentIds, _missingNotified, forgetAfterPolls);
    final changed = pruned.length != _notifiedIds.length;
    _notifiedIds = pruned;
    for (final pr in fresh) {
      if (notify) {
        await _notifyRaw(
          id: 'pr-${pr.id}',
          title: 'Review requested: ${pr.repoName} #${pr.number}',
          body: '${pr.title} — by ${pr.author}',
          url: pr.htmlUrl,
        );
      }
      _notifiedIds.add(pr.id);
    }
    if (fresh.isNotEmpty || changed) await settingsService.saveNotifiedIds(_notifiedIds);
  }

  /// Copilot is announced once per PR. It re-reviews on every push, so
  /// per-review announcements would repeat for the life of the PR. A PR that
  /// leaves the list and comes back is announced again.
  Future<void> _announceCopilotReviews(List<OwnPullRequest> own, {required bool notify}) async {
    final current = <int, OwnPullRequest>{
      for (final o in own)
        if (o.copilotReviewIds.isNotEmpty) o.pr.id: o,
    };
    final fresh = current.keys.where((id) => !_copilotSeenIds.contains(id)).toList();
    final pruned = pruneSeen(_copilotSeenIds, current.keys.toSet(), _missingCopilot, forgetAfterPolls);
    final changed = pruned.length != _copilotSeenIds.length;
    _copilotSeenIds = pruned;

    if (_copilotNeedBaseline || !notify) {
      _copilotSeenIds = current.keys.toSet();
      _missingCopilot.clear();
      if (notify) _copilotNeedBaseline = false;
      await settingsService.saveCopilotReviewIds(_copilotSeenIds);
      return;
    }

    for (final id in fresh) {
      final o = current[id]!;
      await _notifyRaw(
        id: 'copilot-$id',
        title: 'Copilot reviewed: ${o.pr.repoName} #${o.pr.number}',
        body: o.pr.title,
        url: o.pr.htmlUrl,
      );
      _copilotSeenIds.add(id);
    }
    if (fresh.isNotEmpty || changed) await settingsService.saveCopilotReviewIds(_copilotSeenIds);
  }

  Future<void> _announceApprovals(List<OwnPullRequest> own, {required bool notify}) async {
    final approved = own.where((o) => o.state == ReviewState.approved).toList();
    final currentIds = approved.map((o) => o.pr.id).toSet();
    final fresh = approved.where((o) => !_approvedIds.contains(o.pr.id)).toList();
    final pruned = pruneSeen(_approvedIds, currentIds, _missingApproved, forgetAfterPolls);
    final changed = pruned.length != _approvedIds.length;
    _approvedIds = pruned;

    if (_approvalsNeedBaseline || !notify) {
      // Record without announcing: first run, toggle just switched on, or
      // approvals muted. Keeps a later switch-on from replaying old approvals.
      _approvedIds = currentIds;
      _missingApproved.clear();
      if (notify) _approvalsNeedBaseline = false;
      await settingsService.saveApprovedIds(_approvedIds);
      return;
    }

    for (final o in fresh) {
      final by = o.approvers.isEmpty ? 'approved' : 'approved by ${o.approvers.join(', ')}';
      await _notifyRaw(
        id: 'approved-${o.pr.id}',
        title: 'Approved: ${o.pr.repoName} #${o.pr.number}',
        body: '${o.pr.title} — $by',
        url: o.pr.htmlUrl,
      );
      _approvedIds.add(o.pr.id);
    }
    if (fresh.isNotEmpty || changed) await settingsService.saveApprovedIds(_approvedIds);
  }

  /// Drops ids from [seen] only once they have been absent from [current]
  /// for [threshold] consecutive calls. [missing] carries the per-id miss
  /// count between calls and is kept in step with [seen].
  static Set<int> pruneSeen(Set<int> seen, Set<int> current, Map<int, int> missing, int threshold) {
    for (final id in seen) {
      if (current.contains(id)) {
        missing.remove(id);
      } else {
        missing[id] = (missing[id] ?? 0) + 1;
      }
    }
    missing.removeWhere((id, _) => !seen.contains(id));
    final drop = {
      for (final e in missing.entries)
        if (e.value >= threshold) e.key,
    };
    for (final id in drop) {
      missing.remove(id);
    }
    return seen.difference(drop);
  }

  Future<void> _notifyRaw({
    required String id,
    required String title,
    required String body,
    required String url,
  }) async {
    _log.info('notify: $title');
    try {
      await _channel.invokeMethod('notify', {'id': id, 'title': title, 'body': body, 'url': url});
    } catch (e) {
      _log.warn('notify failed: $e');
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
