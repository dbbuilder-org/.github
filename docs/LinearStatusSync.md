# Onboarding a repo onto GitHub <-> Linear status sync

`New-LinearStatusSync.ps1` wires a new repo into the same two-way status sync
already running for `dbbuilder-org/billboard` <-> Linear team `SV1`:

- **GitHub -> Linear**: issue closed/reopened/labeled, PR opened/closed, and
  drags on the repo's GitHub "Issue Boards" project all move the linked
  Linear issue to a matching workflow state.
- **Linear -> GitHub**: any Linear state change other than open/closed
  (Linear's own native GitHub integration already handles that one) moves
  the linked card's Status field on the Issue Boards project. `Duplicate`
  has no matching project column, so it becomes a `Condition:Duplicate`
  label instead.

The script automates everything reachable via the GitHub/Linear APIs. A few
things genuinely can't be automated — those are prerequisites below, and the
script also prints anything it noticed is still missing when it finishes.

## Before running the script

1. **Linear's GitHub integration must already be connected** for the
   workspace/repo pair (Settings -> Integrations -> GitHub in Linear). This
   whole system depends on Linear having already linked issues between the
   two sides — without that link (an `attachment` on each side), there's
   nothing for either direction to look up, and the sync silently no-ops.
2. **The Linear team needs these exact workflow states**: `Todo`, `Blocked`,
   `In Review`, `Done`, `Canceled`, `Duplicate` (required — the script stops
   if any are missing). `Backlog` and `In Progress` are optional; without
   them, those two statuses are simply skipped rather than causing failures.
3. **A GitHub Project must already exist** for the repo (org-level "Issue
   Boards" style — the script does not create one) with a single-select
   **Status** field whose options include at least: `Todo`, `Blocked`,
   `In Review`, `Done`, `Canceled`. `Backlog`/`In Progress` are optional,
   same as above.
4. **A Linear API key** (Personal API Key or workspace key) with read/write
   access — linear.app/settings/account/security.
5. **The Cloudflare Worker's exact `LINEAR_WEBHOOK_SECRET` value.** The
   worker verifies every incoming Linear webhook against one shared secret,
   so a new team's webhook must reuse that same value, not a freshly
   generated one. Cloudflare secrets are write-only after being set, so get
   this from wherever it was first recorded (not retrievable from the
   dashboard).
6. **A clean local clone of the target repo**, on its default branch, with a
   remote you can push to and open PRs against. Defaults to a folder named
   after the repo parallel to this one (e.g. `R:\billboard` next to
   `R:\.github`) — pass `-RepoClonePath` to point elsewhere.
7. **`gh` CLI authenticated** with `repo`, `project`, and `workflow` scopes.
   The script checks this and offers to refresh automatically unless you
   pass `-SkipAccessCheck`.

`LINEAR_API_KEY` as a GitHub Actions org secret already exists org-wide from
the initial setup — nothing to do there for additional repos.

## How to call it

```powershell
cd R:\.github\deploy
./New-LinearStatusSync.ps1 `
  -Repo billboard `
  -LinearTeamKey SV1 `
  -GitHubProjectNumber 8 `
  -LinearApiKey <your Linear API key> `
  -LinearWebhookSecret <the worker's LINEAR_WEBHOOK_SECRET value>
```

Useful optional flags:

- `-Organization <name>` — defaults to `dbbuilder-org`.
- `-RepoClonePath <path>` — if the target repo isn't cloned in the default
  sibling-folder location.
- `-OpenPullRequestForGithub` — opens a PR for the `project-drag.yml` /
  `linear-drag.yml` changes in this repo instead of pushing straight to
  `main` (the default, matching how those files have been maintained so far).
- `-SkipAccessCheck` — skips the `gh auth` scope check.

Safe to re-run: every step (webhook creation, repo-project linking, the two
workflow-file edits) checks for existing state first and skips rather than
duplicating.

## What it does, step by step

1. Looks up the Linear team's ID and workflow-state IDs.
2. Looks up the GitHub Project's Status field and option IDs.
3. Links the repo to that Project, if not already linked.
4. Creates a Linear webhook (Issue events, scoped to the team) pointed at
   the shared Cloudflare Worker — reusing the existing signing secret.
5. Writes `.github/workflows/linear-status-sync.yml` into the target repo
   (the caller for the shared reusable workflow), commits it to a new
   branch, and opens a PR.
6. Adds a routing job to `project-drag.yml` (in this repo) gated on the
   new Project's Status field ID.
7. Adds a case arm to `linear-drag.yml` (in this repo) with the new
   Project/field/option IDs, keyed by `owner/repo`.
8. Commits and pushes (or PRs) the changes from steps 6-7.

## After running the script

1. **Merge the PR** it opened in the target repo.
2. If you used `-OpenPullRequestForGithub`, **merge the PR** it opened in
   `dbbuilder-org/.github` too. Otherwise steps 6-7 above already landed on
   `main` directly.
3. **No Cloudflare deploy needed.** The worker resolves the target repo
   dynamically from each webhook's own payload (GitHub project drags carry
   their own repo; Linear webhooks resolve it via the issue's attachment) —
   it doesn't hardcode anything repo-specific, so onboarding another repo
   never requires touching or redeploying it.
4. **Test all three paths**, same as the billboard/SV1 verification:
   - Close/reopen/label an issue in the new repo -> confirm the linked
     Linear issue's state changes.
   - Change the Linear issue's state (drag, or via API) -> confirm the
     GitHub Project card's Status field updates.
   - Drag a card on the new GitHub Project board -> confirm the linked
     Linear issue's state changes.
5. Address anything printed under "Remaining manual steps" when the script
   finished (typically a missing optional `Backlog`/`In Progress` state or
   option).

## Troubleshooting

- **A Linear webhook delivery does nothing, and no GitHub Actions run ever
  appears** — the Cloudflare Worker is likely throwing before it can
  dispatch. A crashing Worker returns a generic Cloudflare error page
  (`error code: 1101`), not a useful message. The most common cause is a
  missing or misnamed Worker secret — double-check the exact (case-sensitive)
  names in the Cloudflare dashboard under Settings -> Variables and Secrets
  match what `cloudflare-worker/worker.js` expects.
- **A GitHub Actions run fires but does nothing** — check its logs for
  `"has no linked Linear issue"` / `"no Issue Boards project registered"` /
  `"Unknown status"` style messages; these are intentional no-ops, usually
  meaning the item isn't Linear-linked yet, or a state name doesn't match
  what's registered for that repo.
