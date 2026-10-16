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
  Set<int> _approvedIds = {};

  /// True until the approved set has been recorded once. The first pass after
  /// install, or after the approvals toggle is switched on, only records what
  /// is already approved instead of announcing all of it.
  bool _approvalsNeedBaseline = true;
  bool _lastNotifyApprovals = true;

  /// Requested reviewers per PR id, keyed on the PR's updated_at so a PR is
  /// only re-fetched when it changes.
  final Map<int, ({DateTime updatedAt, RequestedReviewers reviewers})> _reviewerCache = {};

  /// Review decisions and outstanding requests for the user's own PRs,
  /// likewise keyed on updated_at.
  final Map<int, ({DateTime updatedAt, Map<String, String> decisions, Set<int> copilotReviews, RequestedReviewers reviewers})>
      _ownPrCache = {};

  Set<int> _copilotSeenIds = {};
  bool _copilotNeedBaseline = true;
  bool _lastNotifyCopilot = true;

  List<PullRequest> _pullRequests = const [];
  List<PullRequest> get pullRequests => _pullRequests;

  List<OwnPullRequest> _myPullRequests = const [];
  List<OwnPullRequest> get myPullRequests => _myPullRequests;

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
    final approved = await settingsService.loadApprovedIds();
    _approvedIds = approved ?? {};
    _approvalsNeedBaseline = approved == null;
    _lastNotifyApprovals = settingsService.settings.notifyApprovals;
    final copilotSeen = await settingsService.loadCopilotReviewIds();
    _copilotSeenIds = copilotSeen ?? {};
    _copilotNeedBaseline = copilotSeen == null;
    _lastNotifyCopilot = settingsService.settings.notifyCopilotReviews;
    settingsService.addListener(_onSettingsChanged);
    _restartTimer();
    await refresh();
  }

  void _onSettingsChanged() {
    final s = settingsService.settings;
    github.token = s.token;
    if (s.notifyApprovals && !_lastNotifyApprovals) _approvalsNeedBaseline = true;
    _lastNotifyApprovals = s.notifyApprovals;
    if (s.notifyCopilotReviews && !_lastNotifyCopilot) _copilotNeedBaseline = true;
    _lastNotifyCopilot = s.notifyCopilotReviews;
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
      _myPullRequests = const [];
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

      final list = <PullRequest>[];
      for (final pr in merged.values) {
        list.add(await _withDirectTargets(pr, settings.targets));
      }
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _reviewerCache.removeWhere((id, _) => !merged.containsKey(id));

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

      // Seen ids are tracked even with notifications off, so switching them
      // on later only announces PRs that arrive after that point.
      for (final pr in fresh) {
        if (settings.notifyReviewRequests) await _notify(pr);
        _notifiedIds.add(pr.id);
      }
      if (fresh.isNotEmpty) await settingsService.saveNotifiedIds(_notifiedIds);

      await _refreshMyPullRequests(
        settings.org,
        notifyApprovals: settings.notifyApprovals,
        notifyCopilot: settings.notifyCopilotReviews,
      );
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

  /// Replace the search-derived targets with the ones the PR directly names.
  /// Falls back to the search result if the PR cannot be read.
  Future<PullRequest> _withDirectTargets(PullRequest pr, List<String> targets) async {
    var cached = _reviewerCache[pr.id];
    if (cached == null || cached.updatedAt != pr.updatedAt) {
      try {
        final reviewers = await github.getRequestedReviewers(pr.repoFullName, pr.number);
        cached = (updatedAt: pr.updatedAt, reviewers: reviewers);
        _reviewerCache[pr.id] = cached;
      } catch (e) {
        debugPrint('requested reviewers for ${pr.repoFullName}#${pr.number} failed: $e');
        return pr;
      }
    }
    final normalized = targets.map(_normalizeTarget);
    return pr.withRequestedFrom(cached.reviewers.resolve(normalized));
  }

  /// Rebuild the My PRs tab and announce newly approved ones. Approval is
  /// announced once per PR while it stays approved; a PR that drops out
  /// (merged, closed, approval dismissed) and comes back is announced again.
  Future<void> _refreshMyPullRequests(
    String org, {
    required bool notifyApprovals,
    required bool notifyCopilot,
  }) async {
    final mine = await github.searchMyOpenPrs(org: org);
    final own = <OwnPullRequest>[];
    for (final pr in mine) {
      own.add(await _deriveOwn(pr));
    }
    own.sort((a, b) => b.pr.updatedAt.compareTo(a.pr.updatedAt));
    _ownPrCache.removeWhere((id, _) => !mine.any((p) => p.id == id));
    _myPullRequests = own;

    await _announceCopilotReviews(own, notify: notifyCopilot);
    await _announceApprovals(own, notify: notifyApprovals);
  }

  /// Copilot reviews are announced once per review id. Ids are kept while the
  /// PR stays open, so a second Copilot pass on the same PR is announced too.
  Future<void> _announceCopilotReviews(List<OwnPullRequest> own, {required bool notify}) async {
    final current = <int, OwnPullRequest>{
      for (final o in own)
        for (final id in o.copilotReviewIds) id: o,
    };
    final fresh = current.keys.where((id) => !_copilotSeenIds.contains(id)).toList();
    _copilotSeenIds = _copilotSeenIds.intersection(current.keys.toSet());

    if (_copilotNeedBaseline || !notify) {
      _copilotSeenIds = current.keys.toSet();
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
    if (fresh.isNotEmpty) await settingsService.saveCopilotReviewIds(_copilotSeenIds);
  }

  Future<void> _announceApprovals(List<OwnPullRequest> own, {required bool notify}) async {
    final approved = own.where((o) => o.state == ReviewState.approved).toList();
    final currentIds = approved.map((o) => o.pr.id).toSet();
    final fresh = approved.where((o) => !_approvedIds.contains(o.pr.id)).toList();
    _approvedIds = _approvedIds.intersection(currentIds);

    if (_approvalsNeedBaseline || !notify) {
      // Record without announcing: first run, toggle just switched on, or
      // approvals muted. Keeps a later switch-on from replaying old approvals.
      _approvedIds = currentIds;
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
    if (fresh.isNotEmpty) await settingsService.saveApprovedIds(_approvedIds);
  }

  Future<OwnPullRequest> _deriveOwn(PullRequest pr) async {
    var cached = _ownPrCache[pr.id];
    if (cached == null || cached.updatedAt != pr.updatedAt) {
      try {
        final reviews = await github.getReviews(pr.repoFullName, pr.number);
        final reviewers = await github.getRequestedReviewers(pr.repoFullName, pr.number);
        cached = (
          updatedAt: pr.updatedAt,
          decisions: GitHubService.latestDecisions(reviews),
          copilotReviews: GitHubService.copilotReviewIds(reviews),
          reviewers: reviewers,
        );
        _ownPrCache[pr.id] = cached;
      } catch (e) {
        debugPrint('own PR details for ${pr.repoFullName}#${pr.number} failed: $e');
        return OwnPullRequest.derive(pr: pr, latestDecisions: const {}, pendingReviewers: const {});
      }
    }
    return OwnPullRequest.derive(
      pr: pr,
      latestDecisions: cached.decisions,
      pendingReviewers: {...cached.reviewers.users, ...cached.reviewers.teams},
      copilotReviewIds: cached.copilotReviews,
    );
  }

  /// `@org/team` loses its `@`; everything else passes through. A target with
  /// a `/` is a team slug, anything else is a username.
  static String _normalizeTarget(String raw) {
    var t = raw.trim();
    if (t.startsWith('@')) t = t.substring(1);
    return t;
  }

  Future<void> _notify(PullRequest pr) => _notifyRaw(
        id: 'pr-${pr.id}',
        title: 'Review requested: ${pr.repoName} #${pr.number}',
        body: '${pr.title} — by ${pr.author}',
        url: pr.htmlUrl,
      );

  Future<void> _notifyRaw({
    required String id,
    required String title,
    required String body,
    required String url,
  }) async {
    try {
      await _channel.invokeMethod('notify', {
        'id': id,
        'title': title,
        'body': body,
        'url': url,
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
