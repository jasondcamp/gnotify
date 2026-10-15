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

  PullRequest withRequestedFrom(Set<String> targets) => PullRequest(
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
        requestedFrom: targets,
      );

  String get repoName => repoFullName.contains('/') ? repoFullName.split('/').last : repoFullName;
}

enum ReviewState { draft, awaiting, approved, changesRequested }

enum CopilotStatus { none, reviewing, reviewed }

/// One of the user's own PRs with its current review situation.
class OwnPullRequest {
  final PullRequest pr;
  final ReviewState state;
  final List<String> approvers;
  final List<String> changesRequestedBy;

  /// Who is still being asked, as logins and `owner/team` slugs. Copilot is
  /// excluded here and reported through [copilot] instead.
  final Set<String> pendingReviewers;

  final CopilotStatus copilot;

  /// Ids of Copilot's submitted reviews on this PR.
  final Set<int> copilotReviewIds;

  const OwnPullRequest({
    required this.pr,
    required this.state,
    this.approvers = const [],
    this.changesRequestedBy = const [],
    this.pendingReviewers = const {},
    this.copilot = CopilotStatus.none,
    this.copilotReviewIds = const {},
  });

  /// Derives the state from the PR's draft flag, the latest decision of each
  /// reviewer and the outstanding requests.
  factory OwnPullRequest.derive({
    required PullRequest pr,
    required Map<String, String> latestDecisions,
    required Set<String> pendingReviewers,
    Set<int> copilotReviewIds = const {},
  }) {
    final copilotPending = pendingReviewers.any((r) => r.toLowerCase().contains('copilot'));
    final humans = pendingReviewers.where((r) => !r.toLowerCase().contains('copilot')).toSet();
    final copilot = copilotPending
        ? CopilotStatus.reviewing
        : copilotReviewIds.isNotEmpty
            ? CopilotStatus.reviewed
            : CopilotStatus.none;
    final approvers = [
      for (final e in latestDecisions.entries)
        if (e.value == 'APPROVED') e.key,
    ];
    final changes = [
      for (final e in latestDecisions.entries)
        if (e.value == 'CHANGES_REQUESTED') e.key,
    ];
    final state = pr.draft
        ? ReviewState.draft
        : changes.isNotEmpty
            ? ReviewState.changesRequested
            : approvers.isNotEmpty
                ? ReviewState.approved
                : ReviewState.awaiting;
    return OwnPullRequest(
      pr: pr,
      state: state,
      approvers: approvers,
      changesRequestedBy: changes,
      pendingReviewers: humans,
      copilot: copilot,
      copilotReviewIds: copilotReviewIds,
    );
  }
}
