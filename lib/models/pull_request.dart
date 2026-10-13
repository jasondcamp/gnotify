class PullRequest {
  final int id;
  final int number;
  final String title;
  final String htmlUrl;
  final String repoFullName;
  final String author;
  final String? authorAvatarUrl;
  final bool draft;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Which configured targets (user or team) this PR is requesting review from.
  final Set<String> requestedFrom;

  const PullRequest({
    required this.id,
    required this.number,
    required this.title,
    required this.htmlUrl,
    required this.repoFullName,
    required this.author,
    required this.authorAvatarUrl,
    required this.draft,
    required this.createdAt,
    required this.updatedAt,
    required this.requestedFrom,
  });

  /// Parses an item from the GitHub search API (`/search/issues`).
  factory PullRequest.fromSearchJson(Map<String, dynamic> j, {required String target}) {
    final repoUrl = j['repository_url'] as String? ?? '';
    final repoFullName = repoUrl.replaceFirst(RegExp(r'^.*/repos/'), '');
    final user = j['user'] as Map<String, dynamic>?;
    return PullRequest(
      id: j['id'] as int,
      number: j['number'] as int,
      title: j['title'] as String? ?? '',
      htmlUrl: j['html_url'] as String? ?? '',
      repoFullName: repoFullName,
      author: user?['login'] as String? ?? '',
      authorAvatarUrl: user?['avatar_url'] as String?,
      draft: j['draft'] as bool? ?? false,
      createdAt: DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? '') ?? DateTime.now(),
      requestedFrom: {target},
    );
  }

  PullRequest mergeTargets(PullRequest other) => PullRequest(
        id: id,
        number: number,
        title: title,
        htmlUrl: htmlUrl,
        repoFullName: repoFullName,
        author: author,
        authorAvatarUrl: authorAvatarUrl,
        draft: draft,
        createdAt: createdAt,
        updatedAt: updatedAt,
        requestedFrom: {...requestedFrom, ...other.requestedFrom},
      );

  String get repoName => repoFullName.contains('/') ? repoFullName.split('/').last : repoFullName;
}
