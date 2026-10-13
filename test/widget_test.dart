import 'package:flutter_test/flutter_test.dart';
import 'package:gnotify/models/pull_request.dart';

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
}

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
