# Onboarding a repo onto GitHub <-> Linear status sync

`.github/workflows/onboard-linear-status-sync.yml` wires a new repo
into the same two-way status sync already running for
`dbbuilder-org/billboard` <-> Linear team `BB`:

- **GitHub -> Linear**: issue closed/reopened/labeled, PR opened/closed, and
  drags on the repo's GitHub "Issue Boards" project all move the linked
  Linear issue to a matching workflow state.
- **Linear -> GitHub**: any Linear state change other than open/closed
  (Linear's own native GitHub integration already handles that one) moves
  the linked card's Status field on the Issue Boards project. `Duplicate`
  has no matching project column, so it becomes a `Condition:Duplicate`
  label instead.

It's a `workflow_dispatch` workflow (named/prefixed "Dispatch:" so future
manually-triggered admin workflows group together in the Actions UI), run
from GitHub itself rather than a local script — it reads `LINEAR_API_KEY`
and `LINEAR_WEBHOOK_SECRET` directly from `dbbuilder-org` org secrets, so
nothing sensitive ever needs to be typed or pasted locally. It automates
everything reachable via the GitHub/Linear APIs; a few things genuinely
can't be — those are prerequisites below, and the run's step summary lists
anything still needed when it finishes.

`.github/workflow-dependencies/apply_routing.py` and
`.github/workflow-dependencies/caller-workflow-template.yml` are helper
files the workflow calls — not meant to be run directly.

## Before running it

1. **Linear's GitHub integration must already be connected** for the
   workspace/repo pair (Settings -> Integrations -> GitHub in Linear). This
   whole system depends on Linear having already linked issues between the
   two sides — without that link (an `attachment` on each side), there's
   nothing for either direction to look up, and the sync silently no-ops.
2. **The Linear team needs these exact workflow states**: `Todo`, `Blocked`,
   `In Review`, `Done`, `Canceled`, `Duplicate` (required — the workflow
   fails if any are missing). `Backlog` and `In Progress` are optional;
   without them, those two statuses are simply skipped rather than causing
   failures.
3. **A GitHub Project must already exist** for the repo (org-level "Issue
   Boards" style — nothing creates one automatically) with a single-select
   **Status** field whose options include at least: `Todo`, `Blocked`,
   `In Review`, `Done`, `Canceled`. `Backlog`/`In Progress` are optional,
   same as above.
4. **`LINEAR_API_KEY` and `LINEAR_WEBHOOK_SECRET` must exist as
   `dbbuilder-org` org secrets.** `LINEAR_API_KEY` already does (org-wide,
   from the initial setup). `LINEAR_WEBHOOK_SECRET` must hold the **exact**
   value already configured on the Cloudflare Worker (`plain-pine-0b38`) —
   the worker verifies every incoming Linear webhook against that one
   shared secret, so a new team's webhook has to reuse it, not a freshly
   generated one. Cloudflare secrets are write-only after being set, so get
   this from wherever it was first recorded (not retrievable from either
   dashboard after the fact).
5. **Permission to trigger `workflow_dispatch` runs** in
   `dbbuilder-org/.github` (write access to the repo, or an org role that
   grants it).

## How to call it

Via `gh`:

```powershell
gh workflow run onboard-linear-status-sync.yml --repo dbbuilder-org/.github `
  -f repo=billboard `
  -f linear_team_key=BB `
  -f github_project_number=8
```

Or via the Actions tab: `dbbuilder-org/.github` -> Actions -> "Dispatch:
Onboard Linear Status Sync" -> Run workflow, filling in the same fields.

Optional inputs:

- `organization` — defaults to `dbbuilder-org`.
- `worker_url` — defaults to the existing Cloudflare Worker's URL.
- `open_pr_for_github` — `true` opens a PR for the `project-drag.yml` /
  `linear-drag.yml` changes instead of pushing straight to `main` (the
  default, matching how those files have been maintained so far).

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
   (the caller for the shared reusable workflow), via
   `.github/workflow-dependencies/caller-workflow-template.yml`, commits it
   to a new branch, and opens a PR.
6. Runs `.github/workflow-dependencies/apply_routing.py` to add a routing job to `project-drag.yml`
   and a case arm to `linear-drag.yml` (both in this repo) for the new
   repo/Project/field/option IDs.
7. Commits and pushes (or PRs, if `open_pr_for_github` was set) the changes
   from step 6.
8. Writes a checklist of what's left to the run's step summary.

## After it runs

1. Open the run and check its **step summary** for the checklist of
   anything still needed (usually just the PR(s) to merge).
2. **Merge the PR** it opened in the target repo.
3. If `open_pr_for_github` was set, **merge the PR** it opened in
   `dbbuilder-org/.github` too. Otherwise the routing changes already
   landed on `main` directly.
4. **No Cloudflare deploy needed.** The worker resolves the target repo
   dynamically from each webhook's own payload (GitHub project drags carry
   their own repo; Linear webhooks resolve it via the issue's attachment) —
   it doesn't hardcode anything repo-specific, so onboarding another repo
   never requires touching or redeploying it.
5. **Test all three paths**, same as the billboard/BB verification:
   - Close/reopen/label an issue in the new repo -> confirm the linked
     Linear issue's state changes.
   - Change the Linear issue's state (drag, or via API) -> confirm the
     GitHub Project card's Status field updates.
   - Drag a card on the new GitHub Project board -> confirm the linked
     Linear issue's state changes.

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
- **The onboarding run itself fails** — `gh run list --repo dbbuilder-org/.github
  --workflow=onboard-linear-status-sync.yml` and `gh run view <id> --log`
  to see which step failed; each step is written to error clearly on a
  missing Linear state, missing Project option, or missing Status field
  rather than failing silently.
