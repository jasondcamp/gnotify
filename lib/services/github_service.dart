import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/pull_request.dart';

class GitHubException implements Exception {
  final int statusCode;
  final String message;
  GitHubException(this.statusCode, this.message);

  @override
  String toString() => 'GitHub $statusCode: $message';
}

class GitHubUser {
  final String login;
  final String? name;
  const GitHubUser({required this.login, this.name});
}

/// Thin client over the pieces of the GitHub REST API this app needs.
class GitHubService {
  static const _baseUrl = 'https://api.github.com';

  String _token = '';
  set token(String value) => _token = value;

  Map<String, String> get _headers => {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'gnotify-macos',
        if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
      };

  /// Returns the user the current token belongs to.
  Future<GitHubUser> getAuthenticatedUser() async {
    final json = await _getJson('$_baseUrl/user');
    return GitHubUser(
      login: json['login'] as String,
      name: json['name'] as String?,
    );
  }

  /// Open, non-draft PRs in [org] that are requesting review from [target].
  /// A target containing `/` is treated as a team slug (`org/team`).
  Future<List<PullRequest>> searchReviewRequests({
    required String org,
    required String target,
  }) async {
    final qualifier = target.contains('/')
        ? 'team-review-requested:$target'
        : 'review-requested:$target';
    final q = 'is:pr is:open draft:false org:$org $qualifier';
    final uri = Uri.parse('$_baseUrl/search/issues').replace(queryParameters: {
      'q': q,
      'sort': 'updated',
      'order': 'desc',
      'per_page': '100',
      'advanced_search': 'true',
    });
    final json = await _getJson(uri.toString());
    final items = (json['items'] as List?) ?? const [];
    return items
        .cast<Map<String, dynamic>>()
        .where((j) => j['pull_request'] != null)
        .map((j) => PullRequest.fromSearchJson(j, target: target))
        .toList();
  }

  /// Open PRs in [org] authored by the token's user that carry at least one
  /// approving review.
  Future<List<PullRequest>> searchMyApprovedPrs({required String org}) async {
    final uri = Uri.parse('$_baseUrl/search/issues').replace(queryParameters: {
      'q': 'is:pr is:open org:$org author:@me review:approved',
      'sort': 'updated',
      'order': 'desc',
      'per_page': '100',
      'advanced_search': 'true',
    });
    final json = await _getJson(uri.toString());
    final items = (json['items'] as List?) ?? const [];
    return items
        .cast<Map<String, dynamic>>()
        .where((j) => j['pull_request'] != null)
        .map((j) => PullRequest.fromSearchJson(j, target: '@me'))
        .toList();
  }

  /// Logins whose most recent review on the PR is an approval.
  Future<List<String>> getApprovers(String repoFullName, int number) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/repos/$repoFullName/pulls/$number/reviews?per_page=100'),
      headers: _headers,
    );
    if (response.statusCode != 200) return const [];
    final reviews = (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
    return latestApprovers(reviews);
  }

  /// Reduces a chronological review list to the reviewers whose latest
  /// decision is APPROVED. Comments do not change a reviewer's decision;
  /// CHANGES_REQUESTED and DISMISSED do.
  static List<String> latestApprovers(List<Map<String, dynamic>> reviews) {
    final latest = <String, String>{};
    for (final r in reviews) {
      final login = (r['user'] as Map<String, dynamic>?)?['login'] as String?;
      final state = r['state'] as String?;
      if (login == null || state == null) continue;
      if (state == 'COMMENTED' || state == 'PENDING') continue;
      latest[login] = state;
    }
    return [
      for (final e in latest.entries)
        if (e.value == 'APPROVED') e.key,
    ];
  }

  /// Confirms the token can search PRs inside [org]. Throws a
  /// [GitHubException] with GitHub's own explanation when it cannot, which
  /// is the usual failure for a fine-grained token issued under the wrong
  /// resource owner.
  Future<void> checkOrgSearchable(String org) async {
    final uri = Uri.parse('$_baseUrl/search/issues').replace(queryParameters: {
      'q': 'is:pr org:$org',
      'per_page': '1',
      'advanced_search': 'true',
    });
    await _getJson(uri.toString());
  }

  Future<Map<String, dynamic>> _getJson(String url) async {
    final response = await http.get(Uri.parse(url), headers: _headers);
    if (response.statusCode != 200) {
      String message = response.reasonPhrase ?? 'Request failed';
      try {
        final body = jsonDecode(response.body);
        if (body is Map) {
          if (body['message'] is String) message = body['message'];
          // Validation errors carry the useful explanation in `errors[].message`.
          final errors = body['errors'];
          if (errors is List) {
            final details = errors
                .whereType<Map>()
                .map((e) => e['message'])
                .whereType<String>()
                .join('; ');
            if (details.isNotEmpty) message = details;
          }
        }
      } catch (_) {}
      throw GitHubException(response.statusCode, message);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}
