import 'package:flutter_test/flutter_test.dart';
import 'package:gnotify/models/pull_request.dart';
import 'package:gnotify/services/github_service.dart';

void main() {
  test('PullRequest parses a search item', () {
    final pr = PullRequest.fromSearchJson({
      'id': 1,
      'number': 42,
      'title': 'Fix things',
      'html_url': 'https://github.com/acme/widgets/pull/42',
      'repository_url': 'https://api.github.com/repos/acme/widgets',
      'user': {'login': 'octocat', 'avatar_url': 'https://avatars.githubusercontent.com/u/1?v=4'},
      'draft': false,
      'created_at': '2026-10-01T00:00:00Z',
      'updated_at': '2026-10-02T00:00:00Z',
      'pull_request': {},
    }, target: 'me');
    expect(pr.repoFullName, 'acme/widgets');
    expect(pr.repoName, 'widgets');
    expect(pr.requestedFrom, {'me'});
  });

  test('mergeTargets unions the requesting targets', () {
    final a = PullRequest.fromSearchJson(_item(1), target: 'me');
    final b = PullRequest.fromSearchJson(_item(1), target: 'acme/platform');
    expect(a.mergeTargets(b).requestedFrom, {'me', 'acme/platform'});
  });

  test('resolve reports the user only when named directly', () {
    final viaTeamOnly = RequestedReviewers.fromPullJson({
      'requested_reviewers': [],
      'requested_teams': [{'slug': 'platform'}],
    }, owner: 'acme');
    expect(viaTeamOnly.resolve(['acme/platform', 'jasondcamp']), {'acme/platform'});

    final both = RequestedReviewers.fromPullJson({
      'requested_reviewers': [{'login': 'JasonDCamp'}],
      'requested_teams': [{'slug': 'platform'}],
    }, owner: 'acme');
    expect(both.resolve(['acme/platform', 'jasondcamp']), {'acme/platform', 'jasondcamp'});

    // Requested via a team that is not configured: show the real team.
    final otherTeam = RequestedReviewers.fromPullJson({
      'requested_reviewers': [],
      'requested_teams': [{'slug': 'infra'}],
    }, owner: 'acme');
    expect(otherTeam.resolve(['jasondcamp']), {'acme/infra'});
  });

  test('OwnPullRequest.derive picks the right state', () {
    final pr = PullRequest.fromSearchJson(_item(7), target: '@me');
    OwnPullRequest d(Map<String, String> decisions, {Set<String> pending = const {}}) =>
        OwnPullRequest.derive(pr: pr, latestDecisions: decisions, pendingReviewers: pending);

    expect(d({}).state, ReviewState.awaiting);
    expect(d({'alice': 'APPROVED'}).state, ReviewState.approved);
    expect(d({'alice': 'APPROVED', 'bob': 'CHANGES_REQUESTED'}).state, ReviewState.changesRequested);
    expect(d({'alice': 'DISMISSED'}).state, ReviewState.awaiting);
    expect(d({'alice': 'APPROVED'}).approvers, ['alice']);

    final draft = PullRequest.fromSearchJson({..._item(8), 'draft': true}, target: '@me');
    expect(
      OwnPullRequest.derive(pr: draft, latestDecisions: {'alice': 'APPROVED'}, pendingReviewers: {}).state,
      ReviewState.draft,
    );
  });

  test('Copilot reviews are detected and reported separately from humans', () {
    final reviews = [
      {'id': 1, 'user': {'login': 'alice'}, 'state': 'COMMENTED'},
      {'id': 2, 'user': {'login': 'copilot-pull-request-reviewer[bot]'}, 'state': 'COMMENTED'},
      {'id': 3, 'user': {'login': 'copilot-pull-request-reviewer[bot]'}, 'state': 'PENDING'},
    ];
    expect(GitHubService.copilotReviewIds(reviews), {2});

    final pr = PullRequest.fromSearchJson(_item(9), target: '@me');
    final reviewing = OwnPullRequest.derive(
      pr: pr,
      latestDecisions: const {},
      pendingReviewers: {'copilot', 'bob'},
    );
    expect(reviewing.copilot, CopilotStatus.reviewing);
    expect(reviewing.pendingReviewers, {'bob'});

    final reviewed = OwnPullRequest.derive(
      pr: pr,
      latestDecisions: const {},
      pendingReviewers: const {},
      copilotReviewIds: {2},
    );
    expect(reviewed.copilot, CopilotStatus.reviewed);
    expect(reviewed.state, ReviewState.awaiting);
  });

  test('latestApprovers keeps only reviewers whose last decision is approval', () {
    final approvers = GitHubService.latestApprovers([
      _review('alice', 'APPROVED'),
      _review('bob', 'CHANGES_REQUESTED'),
      _review('bob', 'COMMENTED'),
      _review('carol', 'APPROVED'),
      _review('carol', 'DISMISSED'),
      _review('dave', 'COMMENTED'),
      _review('bob', 'APPROVED'),
    ]);
    expect(approvers, ['alice', 'bob']);
  });
}

Map<String, dynamic> _review(String login, String state) => {
      'user': {'login': login},
      'state': state,
    };

Map<String, dynamic> _item(int id) => {
      'id': id,
      'number': id,
      'title': 't',
      'html_url': 'u',
      'repository_url': 'https://api.github.com/repos/acme/widgets',
      'user': {'login': 'x'},
      'created_at': '2026-10-01T00:00:00Z',
      'updated_at': '2026-10-02T00:00:00Z',
      'pull_request': {},
    };
