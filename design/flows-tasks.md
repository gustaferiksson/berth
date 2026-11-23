# Tasks: flows

A task groups the sessions working toward one goal, across folders, repos, branches and PRs.
Berth owns the model; a GitHub issue is an optional link on it. The first slice
is built in two steps. Slice 1a (done): store, automatic forming, branch-name suggestions, task rows
inside the sidebar's groups, rename, Remove from Task, Delete Task and New Task from Selection.
Slice 1b: the task card in Review with stacked repo sections (built), Add to Task, Link Issue, merge (not built).
Board, Open Diff in New Window and Harbor are under Later.

Numbers below were measured over 60 days of the author's transcripts (253 sessions, 105 PRs,
124 branch names); they size the signals, not the product.

## Model

- A task is a name, an optional issue, the member sessions, the sessions excluded from it, and an
  origin (`auto` or `local`). Repos, branches and PRs are never stored: each scan derives them from
  the members, so nobody declares which repos a session spans.
- Stored (`StoredTask`): `id` (`task:<uuid>`, assigned when the task forms), `name` (nil until
  renamed), `issue` (`IssueRef`: repository `owner/name` + number, nil for none), `origin`,
  `sessionIDs` (ordered, sticky joins) and `excluded` (session ids that never rejoin this task).
  Beside the tasks, one `dismissed` set of signal keys (`issue:acme/billing#57`,
  `pr:acme/web#89`, `branch:usage-export`): a deleted auto task or a dismissed suggestion writes its
  key, so the same evidence never forms or suggests it again.
- A session belongs to at most one task. Joining another task moves it; the old task keeps no trace.
- Persisted like `customGroups`: one JSON string in UserDefaults (`tasks`:
  `{"version":1,"tasks":[…],"dismissed":[…]}`), read and written only behind `persistsTabs`, so
  snapshots never touch it (`-snapshotTasks YES` seeds fixture tasks in memory).
  Decoding is per task, like `LanguageServerEntry.stored`: an unreadable entry is skipped and kept
  when the list is written back.
- Display title, first hit wins: the renamed `name`, the issue's title (from the PR lookup's
  `closingIssuesReferences`), the newest member's title. The newest PR's title is not in the chain yet. Tasks sort by their newest member's `lastPrompt`, group
  order rules as in `flows-groups.md` (reorders wait until the pointer leaves the sidebar).
- Pure logic lives in `Packages/BerthCore` (`TaskFormation`: stored tasks + per-session signals in,
  tasks + suggestions out), tested from fixtures for the sticky rules: a join survives evidence rolling
  out of the tail, an exclusion survives every scan, a dismissed key never returns.

## Signals

| Signal | Source | Effect | Measured |
|---|---|---|---|
| Typed issue URL | `github.com/<o>/<r>/issues/<n>` in a typed prompt, read from transcript head and tail like the title, remembered in memory across scans like branches | Joins the session to that issue's task | 40 of 253 sessions; 5 issues join 16 sessions that share no PR |
| PR closes an issue | `closingIssuesReferences` of the session's PRs (pr-link records and the branch lookup) | Joins the PR's sessions to that issue's task | 81 of 105 PRs close an issue; 3 issues join sessions that share no PR |
| Same PR | `SessionSummary.pullRequests` (pr-link) or the branch lookup's PR | Joins both sessions | 10 groups of 26 sessions; 2 span repos |
| Same branch name | `SessionSummary.branches` in two repos | Suggests only | 9 of 124 branch names |
| Edits, cwd, worktree | Tool paths in the transcript, folder, checkout | Adds repos to a session's view, never joins sessions | 19 of 155 sessions edit another repo |

Guesses: join on an issue or a PR, suggest on a branch name.

## Forming and updating

Runs in `Store.refresh` after the PR lookup merges (and again when a lookup lands), off the main
thread, over every listed session, archived ones included.

1. Per session, collect issue refs (typed first, then closing refs) and PR refs. A sweep, a session with
   6 or more PRs (2 measured) or 4 or more distinct typed issue URLs, contributes no signals; it can
   still be added by hand. Otherwise a session names at most 3 issues.
2. Start from the stored tasks. Drop members whose transcript is gone, and members in `excluded`.
3. A session with an issue ref whose issue matches a stored task's issue joins that task (one task per
   issue ref). Else it joins the task holding one of its PRs. A session whose refs match two tasks
   stays where it is and the conflict becomes a suggestion (Merge, see below), never a silent merge.
   With several issue refs the first one the session named wins.
   A sweep joins nothing, not even by a PR its task already holds. A key a session is excluded from
   (the issue and member PRs of a task it was removed from) is no signal for forming either, so two
   removed sessions that share the issue never form a second task of their own.
4. Remaining sessions are unioned by shared issue ref or PR ref. A component forms a new task when it
   has 2 or more sessions, or 1 session whose repos (checkout roots and its PRs' repositories, not the
   issue's) number 2 or more. 47 of 73 PR-linked sessions share nothing with another session, and 36 of
   those stay in one repo: they look exactly as today.
5. Order of the three outcomes: stored first, then new tasks, then suggestions.
6. Pinned and archived do not change membership.

Stickiness:

- A join is stored once made, whether automatic or manual, so a session does not leave when its tail rolls
  past the evidence, when `gh` is missing on the next launch, or when its PR merges.
- Remove from Task stores the exclusion and nothing else; the session returns to its project group.
  Inference never overrides an exclusion. It may still join the session to a different task.
- Manual adds (Add to Task, New Task from Selection) are joins like any other; they also move the session
  out of its old task and clear it from the new task's `excluded`.
- When a signal disappears nothing happens: no signal is ever a reason to remove a member. A task is
  shown while it has 2 or more members, or a `name`, or is `local`, or has 1 member spanning 2 repos.
  An `auto` task with no `name` that falls below that is dropped on a scan, unless it still holds
  exclusions: it then stays stored but hidden (its members show as plain rows), so removed sessions stay
  removed and a later session naming its issue joins it again. An `auto` task with no listed member
  at all is dropped. A renamed or local task stays with 1 member, and a local task stays empty.
- A task with no issue takes one when a member's closing refs name an issue no other task holds
  (the PR lookup lands after the first scan).
- Deleting a task (row menu, Delete Task…) is Dissolve: members are untouched, and for an auto task
  its issue and PR keys go into `dismissed` so it does not re-form.
- A task gains an issue only from a signal or Link Issue… (typed URL in a small field). Linking makes
  later sessions that name that issue join it.

Local tasks: New Task… (File menu, palette, the sidebar's Tasks header +, multi-selection menu "New
Task from Selection…") asks for a name and starts empty or with the selection. Add to Task ▸ (session
row menu: existing tasks, then New Task…) is the manual join. Merge Into Task… and splitting are plain
store edits (move `sessionIDs`, union `excluded`; a merge is refused when both tasks carry different
issues) and are in Later unless the first slice has room; splitting already works as Remove from Task on a
multi-selection followed by New Task from Selection.

## Suggestions

- One rule: a non-default branch name shared by sessions in 2 or more repos where at least one of the
  sessions is outside the task (or the sessions are in no task at all). Default branches, the repository's
  default, `HEAD` and a short denylist (`dev`, `wip`, `fix`, `test`, `tmp`) never match. A sweep never counts.
- The result is one of: Join <task>? (one side is in a task) or Make a task from N sessions? (neither is).
  It also carries the merge conflict from step 3 as Merge <a> and <b>?.
- Suggestions are recomputed each scan, never stored, and never change membership. Accepting writes
  the join (and the task, when new). Dismissing writes `branch:<name>` (or the merge pair) into
  `dismissed`. A session that has joined elsewhere drops its suggestion.
- A session whose refs match two tasks stays unjoined and gets no Merge suggestion in slice 1a
  (merge is under Later).
- Shown inline on the session row (decided, mock `sugg` stays out of notice bars and badges): a quiet
  third line, "Join “<task>”?" or "Make a task from N sessions?", in the secondary colour, with a
  checkmark (accept) and a cross (dismiss) on hover. The row menu has the same two as "Join <task>"
  and "Not Related". Nothing else on screen announces a suggestion.

## Sidebar

Decided from the mock (`place` groups, `row` nested, `keep` move, `sugg` inline):

- Order: Terminals, Pinned, the groups, Done. Tasks have no section of their own: a task row
  sits in the group where its newest member session would sit, at that member's position, so it is
  ordered among the session rows by the member's `lastPrompt`. In Recent grouping that is the day
  bucket of the newest member, in Project and Repository the newest member's project, custom groups
  the same rule. Group order and the pointer freeze are untouched.
- Members move: a member appears only under its task, never also as a standalone row in its own
  group. A group left with no rows disappears (custom groups stay). A pinned member stays in
  Pinned; the task row then lists only its unpinned, unarchived members and is hidden with none.
  Done members show in Done. `Store.groups` stays whole (Harbor, remote, palette, search and
  Review see every session); only the sidebar layer folds members into task rows.
- Task row, nested: a chevron and the task title in semibold, the age of the newest member's last
  prompt, and the roll-up status in the status slot (working dots when any member is busy, else
  needs-you, else the unread dot). Line 2 is the issue chip (`#57`, opens the issue) and the member
  count. No repo pills and no PR tags on the row. Title: the renamed name, the issue's title, the
  newest member's title. Members are ordinary session rows indented by 16 pt (text under the title,
  the hover and selection fill indented too) with the project name always shown, since members span
  projects.
- Collapse is the sidebar's own `collapsedGroups` list, keyed `task:<id>`, expanded by default.
  Task rows are flat sibling rows with their own chevron, not a `DisclosureGroup`.
- Click toggles the task. A double-click toggles twice and opens the newest member (`Store.activate`
  with `SidebarItem.task`, the same path as Return on a task row). A locked newest member shows the
  usual notice. Shift and command clicks do not select task rows.
- Keys: ↑/↓ walk the visible rows in order, task rows and expanded members included (a task row only
  moves the cursor). → expands and ← collapses a task row; ← on a member collapses its task and puts
  the cursor on the task row; → on a member expands its group as before.
- Menu on a task row: Rename Task… (an alert with a text field, an empty name goes back to the issue
  or member title) and Delete Task… (confirmation). A member's menu: Remove from Task (the sticky
  exclusion; also on a pinned row), Join / Not Related for a pending suggestion. The multi-selection
  menu gains New Task from N Sessions (a `local` task, unnamed until renamed). Link Issue…, Add to
  Task and Open Issue on GitHub are in slice 1b.
- Palette: not in the first slice, nor tasks as palette rows or ⌘N scopes.
- Per-group cap: a group shows 5 rows, a task row with its members counting as one; the header
  counts sessions.

## Review: task card and stacked repos

Built (slice 1b, review part). Decided from the mock: card `fold`, repos `stack`.

- A session in a task gets a collapsible task card as the first row of the Changes list: a chevron, the
  issue chip (opens the issue), the title and "N repos" while folded; open, a line "N sessions · M PRs · K
  repos" and the members (at most 6, then "N more") as buttons that run `Store.activate(.session)`, the
  current one semibold, each with its project name. The fold state is in memory
  (`Store.collapsedReviewRepositories`, key `task:<id>`). The title is `Store.title(of:)`, the sidebar
  row's chain over all members.
- Below it, one section per repo, in the same list: the session's own repo first, then the repos of the
  task's other members (newest member's folder per repo; worktrees merge into their repo, as in
  Grouping), then repos the session edited outside its own. A session in no task with edits elsewhere
  gets the sections and no card; a session in no task and no outside edits shows the panel exactly as
  before (pixel-identical, checked against `-snapshotReview`).
- Each section is a `Section(isExpanded:)` under the sidebar's `GroupHeader`: the repo name, and on the
  right the branch → base (not for the own repo, whose branch and base stay in the panel header) and one
  `PullRequestTag` per PR with its checks. A repo's PRs are those of the task members in that repo plus
  the section branch's (`Store.pullRequests(inRoot:of:branch:)`, deduped by number). Collapsed state is per
  repo root, in memory. The own repo's section also carries today's full branch card (PR card, commits,
  Create Pull Request, base picker in the header) as its first row; other repos get the compact header
  only. Under each header, "Uncommitted" and "Committed" subheadings (count, +/-) over the existing rows,
  list or tree. They do not collapse: a `List` section cannot nest, so collapse is per repo.
- The Files outline stays the own repo's. A session whose own folder is in no repository but that edited
  repos shows just the stack (no header, card or Files) instead of No Git Repository.
- Edited repos: `TranscriptEdits` reads Edit, Write, MultiEdit and NotebookEdit paths (`file_path`, else
  `notebook_path`) from the selected session's transcript only (not its subagent files), the first time in
  full, then appended bytes, cached per open session (`Store.editedRepositories`) and refreshed on scan,
  on selection and when the panel shows. Each path's folder resolves to its repository: the identity is
  the main checkout (`RepositoryRoot`), the folder to diff is the enclosing worktree root. Paths in no
  repository and relative paths are ignored. An edited-only repo with no changes and no comments is
  hidden (sessions that edited and committed to the default branch would otherwise keep an empty
  section); a task member's repo always shows.
- Models: `Store.reviewModels[sessionID]` stays the own repo's model; other repos are
  `reviewModels["<session id>\n<root>"]`, listed in `Store.reviewRepositories[sessionID]`, created and
  dropped by `prepareReviewModel` (kept while they hold drafts or comments). `Store.activeReviewRoots`
  names the model the diff column shows; every `ReviewModel.open` sets it (`onOpen`), so any row, Open File
  button or comment opens its file in its own repo and the column follows. Tabs, history and editors
  therefore live per repo: the tab strip shows the active repo's tabs only. Closing the last tab of another
  repo falls back to the own repo. `ReviewDocument.root` (nil: the own model's) tags rows in the one
  `List`, so the same path in two repos never collides.
- Comments live in the model of the file they are on. The panel lists all of them (another repo's prefixed
  `repo:`) and Send pastes one prompt into the selected session: the own repo's block as before, then one
  block per other repo whose heading names the repo and its path and whose comment paths are prefixed
  `repo:`. A successful send clears every model's comments.
- Watching: one `FileWatcher` per shown repo root (`Store.watchReview(_:)`), each reloading every shown
  model through `refreshReview`. The PR lookup for another repo's branch runs from the panel
  (`Store.fetchPullRequests`, once per unknown branch) and its base follows the PR's `baseRefName` like
  the own repo's.
- Not built: Link Issue, Add to Task and Merge (still slice 1b leftovers), repos without a folder on disk
  (they are left out, not greyed), a repo switcher (the stack replaced it).
- Snapshot: `-snapshotTasksReview YES` builds three scratch repos under `.build/tasks-review`
  (billing, web, infra; plain `git commit` with the user's identity) and the task fixtures on them;
  `-snapshotTasksReviewSession task-infra` is the no-task variant and `task-parent` a session outside any
  repository that edited two. `-snapshotTasksReviewPoints "web=x,y|infra=x,y|chevron=x,y|member=x,y|send=x,y"`
  sends real double-clicks and clicks at those points (top-left origin), `-snapshotRemoteLog /abs/file`
  fakes the session live over `tee -a` so Send's paste can be read back, and `-snapshotTasksReviewTranscript
  YES` skips the seeded edited repositories so `CFFIXED_USER_HOME` with a compact-JSON transcript under the
  fixture session id drives `TranscriptEdits` end to end. Pass `-reviewChangesAsTree NO|YES` and run with `GIT_CEILING_DIRECTORIES` set to `.build`. The cards' and
  subheadings' list insets are tuned per mode (tree rows sit 9 pt further in).

## Data cost

- `closingIssuesReferences(first: 5) { nodes { number title state repository { nameWithOwner } } }` joins
  the existing per-repo `gh api graphql` batch beside `statusCheckRollup`, for open and merged PRs of the
  batched branches: no new call. An issue that no session's PR names, but a task carries, adds an aliased
  `issue(number:) { title state }` to its repository's call, a repository the batch may not otherwise
  query (at most one call per such repo, same one-minute throttle, in memory, failure keeps old values).
- Typed issue URLs: a raw-byte prefilter for `/issues/` on typed prompts in the head and tail passes of
  `Transcript.summary`, a new `SessionSummary.issueRefs`, kept across scans in `TranscriptIndex`. Misses:
  a URL typed mid-session of a long one, like a branch seen only mid-transcript. Search's whole-file
  pass could close that later; the first slice does not use it.
- No `gh`: no closing refs, no issue titles. Typed URLs and pr-link still join, the chip still shows the
  `owner/name#n`, titles fall back down the display chain.
- Forming is a union-find over at most a few hundred sessions: well under a millisecond per scan.

## Edge states

- Done sessions stay members and count toward forming. Done rows show in Done, not in the task;
  a task with no unarchived member is hidden (a local one shows "No sessions"). Unarchiving returns it.
- Archiving a task: not in the first slice; archive its sessions.
- Folder deleted, session unlistable: as in groups; the id is pruned from the task on the next scan.
- Session in two tasks: impossible; the first named issue wins and the other task keeps no ghost
  row in the first slice (open question).
- Same issue named by a session whose task was dissolved: `dismissed` keeps it out, until Link Issue… on a
  task writes the issue back (and clears the key).
- Sweeps: auto-join skipped, manual add allowed, the task row counts them like any session.
- Live session locked in another terminal: still a member, the row dims as usual.
- Worktree sessions: repos by checkout, so a worktree and its main checkout are one chip.
- Task with a merged or closed issue and all PRs merged: nothing special in the first slice
  (the PR tags turn merged purple).
- Without `gh` or an `origin` remote: task from pr-link and typed URLs only.
- A repo whose folder no longer exists: left out of the stack.
- Review off: no task card, no repo sections; the sidebar's task rows stay.
- Snapshots: `-snapshotTasks`, plus `-snapshotTaskIssues "<json>"` for the fixture's closing refs
  (snapshot mode never calls `gh`).

## Build order

1. `TaskFormation` + store (BerthCore) with fixtures, then `Store.tasks` and persistence.
2. Typed issue refs in the transcript scan, `closingIssuesReferences` in the PR batch.
3. Task rows in the groups, rename, Remove from Task, Delete Task, New Task from Selection (Add to Task in slice 1b).
4. Suggestions UI.
5. Review task card, stacked repo sections, (session, repo) models, edited-repos read (done).

## Later

- Board (tasks as columns of work, concept 3), after the task card.
- Open Diff in New Window, as its own feature.
- Merge Into Task…, issue titles for typed-only issues beyond the first call, tasks in the palette and
  ⌘N, a Harbor pier per task, search by task, the remote's task view.

## Open questions

Decided in slice 1a:

- Row click: it toggles the task (it does not select the newest member); a double-click, or Return,
  opens the newest member.
- Ghost row for the second task of a conflicted session: no, the session just stays unjoined.
- Sweep threshold: 6 PRs or 4 typed issue URLs, as proposed.
- Repo of a task whose issue repository holds no checkout: moot, the row shows no repo pills.
- Task title: the renamed name comes before the issue's title (the doc's order, not the brief's).

Still open:

- Do finished tasks (all PRs merged, nothing active for 7 days) move to a Done fold or archive?
- Branch suggestions across 2 repos only, or also in one repo (worktree pairs)? Two repos only for now.
- The repository's default branch is not excluded from branch suggestions yet, only the generic names
  (`main`, `master`, `develop`, `dev`, `trunk`, `wip`, `fix`, `test`, `tmp`, `HEAD`).
- Closing refs come from the branch lookup only: a PR known just from a `pr-link` record joins by
  its number but carries no closing refs.
- Review's task card (decided: collapsible, first row of the Changes list) and repo form (decided: stacked sections).

## Implementation notes

Moved from CLAUDE.md. Some of this repeats the sections above.

Tasks (`design/flows-tasks.md`): `SessionSummary.issueRefs` are issue URLs typed in prompts (head and tail, oldest first, kept across scans like branches); `PullRequestStatus` reads `closingIssuesReferences` in the per-repo batch. Tasks form in `Store.formTasks` after each scan, repository resolve and PR lookup: sessions sharing an issue or PR join, a lone session forms one only across 2 repos, a sweep (6+ PRs or 4+ typed issues) never joins, a branch name shared across repos only suggests (a third caption line with ✓/×, or Join / Not Related in the row menu).

Joins and removals are sticky; a deleted task dismisses its keys. Tasks have no section: a task row sits in the group of its newest unpinned member and members appear only under it (`SidebarItem.task`, `SessionTask.entries`); `Store.groups` still holds every session (Harbor, remote, palette, search). A click toggles it (collapse in `collapsedGroups` as `task:<id>`), a double-click or Return opens the newest member. Task rows always put their chevron in the status slot (right collapsed, down expanded), so the row leads with its issue chip (before the title, after the chevron) and a task's text starts at a plain session's title x; a collapsed task with a working, needs-you or unread member shows that state left of the row's time, in the activity dot's slot, and an expanded task shows none; issue chips are coloured by state (open green, completed purple, not planned or unknown grey) from the PR batch's `closingIssuesReferences { state stateReason }`.

In Review, a session in a task gets a task header (above the repo picker) and one `Section` per repo (its own, the task members' other repos, and repos it edited outside its own, from BerthCore's `TranscriptEdits`); other repos' models are `reviewModels["<session>\n<root>"]` listed in `Store.reviewRepositories`, `Store.activeReviewRoots` names the one the diff column shows (every `ReviewModel.open` sets it; tabs are per repo), `ReviewDocument.root` tags rows, and Send pastes all models' comments into the selected session, other repos' prefixed `repo:`.

Every repo section starts with the single-repo panel's branch/PR card (an extra repo's PR detail is one `gh` query per shown PR, cached in its model; its Create Pull Request button is hidden), falling back to `ReviewBranchStatus.unknown` when the status failed; the header shows the repo name, `branch → base` for extra repos and chips only for PRs the card isn't showing. The task header (`ReviewTaskHeader`) leads with the issue state pill and `#n`, then the title, `owner/repo` and a caption "N sessions · N PRs · N repos" that toggles the member list (collapsed by default, `Store.expandedReviewTasks`, in memory; titles truncate only when the row can't also fit the repo name).

It sits above the Changes `List` on the panel's 8 pt edges; header and repo picker share one subtle card (`ReviewRepoRows`: a row per repo with its name, `branch → base` and square PR tag, plus an All repos row; selection per task in memory in `Store.reviewRepoTabs`, falling back to the own repo when the picked one disappears, switched by opening a file in another repo; the List's `.id` includes the shown repo and the repo set). A single repo's tab shows its card outside the List and its rows without a section header or collapse.

The repo's other PRs (linked from the task's sessions or found by branch) show under the card under an "Other pull requests" label, a title with a square state tag on the right each (`ReviewOtherPullRequests`), so every PR of the repo is reachable. A closed PR is dropped from a task's PR count and those rows unless its head is the member's current branch or it closes the task's issue (`PullRequestSelection.current`, used by `Store.currentPullRequests`). The repo header's PR chip fades (opacity only, width kept), its branch text never animates, and `ReviewBranchCard` is a `.geometryGroup()` so a section expand doesn't re-lay out its parts.

`GroupHeader` lays its content out at the width it measured while not hovered, less a 25 pt trailing reserve, so the system chevron's hover width never moves or re-truncates it (no chevron measuring); `-snapshotHover "<title>"` forces the state, and synthetic `mouseMoved` events don't trigger SwiftUI `onHover` offscreen, so snapshots can't show the real chevron. Every row in Review's lists (headers, cards, subheadings, file and folder rows) has zero list-row insets and pads itself from `ReviewInset.content` (16 pt) plus 16 pt per tree level (`reviewRow`, `ReviewRepositories.swift`); the lists are `.plain` with separators hidden, and the plain list's own 8 pt edge is subtracted once as `ReviewInset.listMargin`.
