import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/pull_request.dart';
import 'app_log.dart';

class GitHubException implements Exception {
  final int statusCode;
  final String message;

  /// True for primary or secondary rate limiting (403/429 with a limit
  /// message, or a GraphQL RATE_LIMITED error).
  final bool rateLimited;

  /// How long GitHub asked us to wait, when it said.
  final Duration? retryAfter;

  GitHubException(this.statusCode, this.message, {this.rateLimited = false, this.retryAfter});

  @override
  String toString() => 'GitHub $statusCode: $message';
}

/// GraphQL budget as reported by the last poll.
class RateLimitInfo {
  final int limit;
  final int remaining;
  final int cost;
  final DateTime? resetAt;
  const RateLimitInfo({required this.limit, required this.remaining, required this.cost, this.resetAt});
}

/// Who a PR is currently asking for review. Users are logins; teams are
/// `owner/slug`. Both lowercased.
class RequestedReviewers {
  final Set<String> users;
  final Set<String> teams;
  const RequestedReviewers({required this.users, required this.teams});

  factory RequestedReviewers.fromPullJson(Map<String, dynamic> j, {required String owner}) {
    final users = ((j['requested_reviewers'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map((u) => (u['login'] as String? ?? '').toLowerCase())
        .where((u) => u.isNotEmpty)
        .toSet();
    final teams = ((j['requested_teams'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map((t) => '${owner.toLowerCase()}/${(t['slug'] as String? ?? '').toLowerCase()}')
        .where((t) => !t.endsWith('/'))
        .toSet();
    return RequestedReviewers(users: users, teams: teams);
  }

  /// From a GraphQL `reviewRequests { nodes { requestedReviewer } }` list.
  factory RequestedReviewers.fromGraphNodes(List<dynamic> nodes) {
    final users = <String>{};
    final teams = <String>{};
    for (final n in nodes) {
      final r = (n as Map<String, dynamic>?)?['requestedReviewer'] as Map<String, dynamic>?;
      if (r == null) continue;
      if (r['__typename'] == 'Team') {
        final org = (r['organization'] as Map<String, dynamic>?)?['login'] as String? ?? '';
        final slug = r['slug'] as String? ?? '';
        if (org.isNotEmpty && slug.isNotEmpty) teams.add('${org.toLowerCase()}/${slug.toLowerCase()}');
      } else {
        final login = r['login'] as String? ?? '';
        if (login.isNotEmpty) users.add(login.toLowerCase());
      }
    }
    return RequestedReviewers(users: users, teams: teams);
  }

  /// The configured targets this PR is directly asking for. GitHub's
  /// `review-requested:user` search also matches requests sent to a team the
  /// user belongs to, so the search result alone over-reports the user. When
  /// no configured target is named directly, the actual requested teams are
  /// returned instead so the chip still tells the truth.
  Set<String> resolve(Iterable<String> configuredTargets) {
    final direct = <String>{};
    for (final t in configuredTargets) {
      final key = t.toLowerCase();
      if (key.contains('/') ? teams.contains(key) : users.contains(key)) direct.add(t);
    }
    if (direct.isNotEmpty) return direct;
    if (teams.isNotEmpty) return teams;
    return users;
  }
}

class GitHubUser {
  final String login;
  final String? name;
  const GitHubUser({required this.login, this.name});
}

/// Everything one poll needs, from a single GraphQL request.
class PollResult {
  final String viewer;
  final List<PullRequest> toReview;
  final List<OwnPullRequest> mine;
  final RateLimitInfo? rateLimit;
  final int requests;
  const PollResult({
    required this.viewer,
    required this.toReview,
    required this.mine,
    required this.rateLimit,
    required this.requests,
  });
}

/// GitHub client. Polling is one GraphQL search per tick, which keeps the
/// app well clear of the REST search limits and GitHub's secondary
/// (burst) limits. REST is only used for the token's own identity.
class GitHubService {
  static const _restBase = 'https://api.github.com';
  static const _graphql = 'https://api.github.com/graphql';
  static const _maxPages = 3;

  String _token = '';
  set token(String value) => _token = value;

  /// Human-readable summary of non-fatal GraphQL errors from the last
  /// request, or null when it was clean. Typically a missing token
  /// permission for part of the data (teams need Members: Read).
  String? get lastPartialWarning => _lastPartialWarning;
  String? _lastPartialWarning;
  String? _lastPartialSignature;

  Map<String, String> get _headers => {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'gnotify-macos',
        if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
      };

  /// Returns the user the current token belongs to.
  Future<GitHubUser> getAuthenticatedUser() async {
    final response = await http.get(Uri.parse('$_restBase/user'), headers: _headers);
    if (response.statusCode != 200) throw _restError(response);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return GitHubUser(login: json['login'] as String, name: json['name'] as String?);
  }

  /// Builds the one search string that covers both tabs:
  /// your own open PRs, plus open PRs by others that ask one of the targets
  /// for review. Drafts are included on both sides: teams here request
  /// reviews on drafts, and GitHub's own "review requested" view lists them.
  static String pollQuery({required String org, required List<String> targets}) {
    final reqs = targets
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .map((t) => t.startsWith('@') ? t.substring(1) : t)
        .map((t) => t.contains('/') ? 'team-review-requested:$t' : 'review-requested:$t')
        .join(' OR ');
    final theirs = reqs.isEmpty ? '' : ' OR (-author:@me ($reqs))';
    return 'org:$org is:pr is:open ((author:@me)$theirs)';
  }

  static const _document = r'''
query($q: String!, $after: String) {
  viewer { login }
  rateLimit { cost remaining limit resetAt }
  search(type: ISSUE_ADVANCED, query: $q, first: 100, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      __typename
      ... on PullRequest {
        databaseId number title url isDraft createdAt updatedAt
        author { login avatarUrl }
        repository { nameWithOwner }
        reviewRequests(first: 30) { nodes { requestedReviewer {
          __typename
          ... on User { login }
          ... on Team { slug organization { login } }
          ... on Bot { login }
          ... on Mannequin { login }
        } } }
        latestReviews(first: 50) { nodes { databaseId state author { login } } }
        reviewThreads(first: 100) { nodes { isResolved } }
      }
    }
  }
}
''';

  /// One poll: a single GraphQL request (more only if the org has over 100
  /// matching PRs). Returns both tabs' contents fully resolved.
  Future<PollResult> poll({required String org, required List<String> targets}) async {
    final q = pollQuery(org: org, targets: targets);
    String? after;
    String viewer = '';
    RateLimitInfo? rate;
    final nodes = <Map<String, dynamic>>[];
    var requests = 0;
    var dropped = 0;

    do {
      final data = await _graphqlRequest(_document, {'q': q, 'after': after});
      requests++;
      viewer = ((data['viewer'] as Map<String, dynamic>?)?['login'] as String?) ?? viewer;
      final rl = data['rateLimit'] as Map<String, dynamic>?;
      if (rl != null) {
        rate = RateLimitInfo(
          limit: rl['limit'] as int? ?? 0,
          remaining: rl['remaining'] as int? ?? 0,
          cost: (rate?.cost ?? 0) + (rl['cost'] as int? ?? 0),
          resetAt: DateTime.tryParse(rl['resetAt'] as String? ?? ''),
        );
      }
      final search = data['search'] as Map<String, dynamic>? ?? const {};
      final rawNodes = (search['nodes'] as List?) ?? const [];
      for (final n in rawNodes) {
        if (n is Map<String, dynamic> && n['__typename'] == 'PullRequest' && n['databaseId'] != null) {
          nodes.add(n);
        } else {
          dropped++;
        }
      }
      final page = search['pageInfo'] as Map<String, dynamic>? ?? const {};
      after = page['hasNextPage'] == true ? page['endCursor'] as String? : null;
    } while (after != null && requests < _maxPages);

    if (dropped > 0) {
      AppLog.instance.warn('poll: $dropped search result(s) came back unreadable and were dropped. '
          'The search index found them under your account but the token could not open them; '
          'check the token\'s repository access.');
      _lastPartialWarning ??= 'Token cannot read $dropped PR(s) the search found. Check its repository access.';
    }

    final me = viewer.toLowerCase();
    final toReview = <PullRequest>[];
    final mine = <OwnPullRequest>[];
    for (final n in nodes) {
      final reviewers = RequestedReviewers.fromGraphNodes(
        ((n['reviewRequests'] as Map<String, dynamic>?)?['nodes'] as List?) ?? const [],
      );
      final reviews = _normalizeReviews(((n['latestReviews'] as Map<String, dynamic>?)?['nodes'] as List?) ?? const []);
      final author = ((n['author'] as Map<String, dynamic>?)?['login'] as String? ?? '').toLowerCase();
      if (author == me) {
        mine.add(OwnPullRequest.derive(
          pr: PullRequest.fromGraphNode(n),
          latestDecisions: latestDecisions(reviews),
          pendingReviewers: {...reviewers.users, ...reviewers.teams},
          copilotReviewIds: copilotReviewIds(reviews),
        ));
      } else {
        toReview.add(PullRequest.fromGraphNode(n, requestedFrom: reviewers.resolve(targets)));
      }
    }
    toReview.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    mine.sort((a, b) => b.pr.updatedAt.compareTo(a.pr.updatedAt));
    return PollResult(viewer: viewer, toReview: toReview, mine: mine, rateLimit: rate, requests: requests);
  }

  /// Confirms the token can search PRs inside [org] through the same path the
  /// poll uses. Throws a [GitHubException] with GitHub's own explanation when
  /// it cannot, which is the usual failure for a fine-grained token issued
  /// under the wrong resource owner.
  Future<void> checkOrgSearchable(String org) async {
    const doc = r'query($q: String!) { search(type: ISSUE_ADVANCED, query: $q, first: 1) { issueCount } }';
    await _graphqlRequest(doc, {'q': 'org:$org is:pr'});
  }

  /// GraphQL review nodes in the REST review shape the helpers below expect.
  static List<Map<String, dynamic>> _normalizeReviews(List<dynamic> nodes) => [
        for (final n in nodes.whereType<Map<String, dynamic>>())
          {
            'id': n['databaseId'],
            'state': n['state'],
            'user': {'login': (n['author'] as Map<String, dynamic>?)?['login']},
          },
      ];

  /// Copilot code review shows up as the requested reviewer `Copilot` and
  /// submits under `copilot-pull-request-reviewer[bot]`.
  static bool isCopilot(String login) => login.toLowerCase().contains('copilot');

  /// Ids of submitted (non-pending) reviews written by Copilot.
  static Set<int> copilotReviewIds(List<Map<String, dynamic>> reviews) => {
        for (final r in reviews)
          if (r['id'] is int &&
              r['state'] != 'PENDING' &&
              isCopilot((r['user'] as Map<String, dynamic>?)?['login'] as String? ?? ''))
            r['id'] as int,
      };

  /// Reduces a review list to each reviewer's latest decision.
  static Map<String, String> latestDecisions(List<Map<String, dynamic>> reviews) {
    final latest = <String, String>{};
    for (final r in reviews) {
      final login = (r['user'] as Map<String, dynamic>?)?['login'] as String?;
      final state = r['state'] as String?;
      if (login == null || state == null) continue;
      if (state == 'COMMENTED' || state == 'PENDING') continue;
      latest[login] = state;
    }
    return latest;
  }

  /// Reviewers whose latest decision is APPROVED.
  static List<String> latestApprovers(List<Map<String, dynamic>> reviews) => [
        for (final e in latestDecisions(reviews).entries)
          if (e.value == 'APPROVED') e.key,
      ];

  // ---------------------------------------------------------------- transport

  Future<Map<String, dynamic>> _graphqlRequest(String document, Map<String, dynamic> variables) async {
    final response = await http.post(
      Uri.parse(_graphql),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'query': document, 'variables': variables}),
    );
    if (response.statusCode != 200) throw _restError(response);

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final errors = (body['errors'] as List?)?.whereType<Map>().toList() ?? const [];
    final data = body['data'] as Map<String, dynamic>?;
    if (errors.isNotEmpty) {
      final types = errors.map((e) => e['type']).whereType<String>().toSet();
      final message = errors.map((e) => e['message']).whereType<String>().join('; ');
      final rateLimited = types.contains('RATE_LIMITED');
      if (data == null || data['search'] == null || rateLimited) {
        final status = rateLimited || types.contains('FORBIDDEN') || types.contains('INSUFFICIENT_SCOPES') ? 403 : 422;
        throw GitHubException(status, message, rateLimited: rateLimited, retryAfter: _retryAfter(response.headers));
      }
      _notePartialErrors(errors);
    } else {
      _lastPartialWarning = null;
      _lastPartialSignature = null;
    }
    if (data == null) throw GitHubException(502, 'Empty GraphQL response');
    return data;
  }

  /// Partial errors repeat on every poll for as long as the cause exists, so
  /// they are logged once per distinct set and summarised for the footer.
  void _notePartialErrors(List<Map> errors) {
    final byPath = <String, int>{};
    for (final e in errors) {
      final path = ((e['path'] as List?) ?? const []).whereType<String>().join('.');
      final key = '${e['type'] ?? 'ERROR'} ${e['message']} @ $path';
      byPath[key] = (byPath[key] ?? 0) + 1;
    }
    final signature = (byPath.keys.toList()..sort()).join('|');
    final paths = byPath.keys.join(' ');
    final notAccessible = paths.contains('not accessible by');

    String warning;
    if (notAccessible && paths.contains('requestedReviewer')) {
      warning = 'Token cannot read team review requests. Add Members: Read on the org.';
    } else if (notAccessible && RegExp(r'search\.nodes(\s|$)').hasMatch(paths)) {
      warning = 'Token cannot read some PRs the search found. Check its repository access.';
    } else if (notAccessible) {
      warning = 'Token is missing a permission for part of the data. See the log.';
    } else {
      warning = 'GitHub returned ${errors.length} partial error(s). See the log.';
    }
    _lastPartialWarning = warning;

    if (signature == _lastPartialSignature) return;
    _lastPartialSignature = signature;
    final detail = byPath.entries.map((e) => '${e.value}× ${e.key}').join('; ');
    AppLog.instance.warn('GraphQL partial errors (${errors.length}), data still usable: $detail');
    AppLog.instance.warn('hint: $warning');
  }

  GitHubException _restError(http.Response response) {
    String message = response.reasonPhrase ?? 'Request failed';
    try {
      final body = jsonDecode(response.body);
      if (body is Map) {
        if (body['message'] is String) message = body['message'];
        final errors = body['errors'];
        if (errors is List) {
          final details = errors.whereType<Map>().map((e) => e['message']).whereType<String>().join('; ');
          if (details.isNotEmpty) message = details;
        }
      }
    } catch (_) {}
    final lower = message.toLowerCase();
    final rateLimited = response.statusCode == 429 ||
        (response.statusCode == 403 && (lower.contains('rate limit') || lower.contains('abuse')));
    return GitHubException(
      response.statusCode,
      message,
      rateLimited: rateLimited,
      retryAfter: _retryAfter(response.headers),
    );
  }

  /// `Retry-After` in seconds, else time until `x-ratelimit-reset` when the
  /// remaining count is zero. Null when GitHub gave no hint.
  static Duration? _retryAfter(Map<String, String> headers) {
    final h = {for (final e in headers.entries) e.key.toLowerCase(): e.value};
    final retry = int.tryParse(h['retry-after'] ?? '');
    if (retry != null && retry > 0) return Duration(seconds: retry);
    if (h['x-ratelimit-remaining'] == '0') {
      final reset = int.tryParse(h['x-ratelimit-reset'] ?? '');
      if (reset != null) {
        final until = DateTime.fromMillisecondsSinceEpoch(reset * 1000).difference(DateTime.now());
        if (until > Duration.zero) return until;
      }
    }
    return null;
  }
}
