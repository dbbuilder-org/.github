# Setting up GitHub <-> Linear sync for a new project + Linear team

Everything a human needs to do, start to finish, to get a **new GitHub repo**
syncing with a **new Linear team**. The underlying system (Cloudflare Worker,
GitHub App, org secrets) is shared, already-deployed infrastructure — nothing
below touches it. What's below is the per-project checklist.

## What this system syncs

Four independent data types, each with its own automation:

| Data | GitHub -> Linear | Linear -> GitHub |
|---|---|---|
| **Status** (open/closed handled by Linear natively) | webhook-driven | webhook-driven |
| **Priority** | webhook-driven | webhook-driven |
| **Relationships** (blocks/blocked-by) | webhook-driven | **polling only**, every 15 min (Linear has no webhook for relation changes) |
| **Sub-issues** (parent/child) | not custom — Linear's own native GitHub integration already does this | same |

## What's already set up org-wide (nothing to redo per-project)

- **Cloudflare Worker** `plain-pine-0b38` — relays GitHub/Linear webhooks to
  `dbbuilder-org/.github` Actions. No per-project changes ever needed; it
  resolves everything dynamically from each webhook's own payload.
- **`dbbuilder-workflow` GitHub App** — installed org-wide on **all**
  repositories already (confirmed `repository_selection: "all"` via
  `gh api orgs/dbbuilder-org/installations`), so nothing to install per repo.
  Subscribed to the webhook events this whole system depends on
  (`issues`, `issue_dependencies`, `projects_v2_item`, etc.).
- **Org secrets** `LINEAR_API_KEY` and `LINEAR_WEBHOOK_SECRET` — already
  present on `dbbuilder-org`.
- **GitHub's org-wide "Priority" Issue Field** — a custom Issue Field
  (Urgent/High/Medium/Low), already created at the org level. Applies to
  every repo automatically; nothing to configure per project. (If a new
  repo's issues don't show a Priority field at all, that's an org-level
  GitHub settings question, not something this sync sets up.)

## Step-by-step: onboarding a repo + team pair

### 1. Linear.app — create/prepare the team

1. Create the Linear team if it doesn't exist yet, and note its **key**
   (e.g. `BB`) — every step below needs it.
2. Check **Team Settings -> Workflow** and make sure these states exist by
   exactly these names:
   - **Required**: `Todo`, `Blocked`, `In Review`, `Done`, `Canceled`,
     `Duplicate` (the onboarding workflow *fails* if any are missing).
   - **Optional**: `Backlog`, `In Progress` — if absent, those two statuses
     are just skipped, not an error.
   - `Duplicate` can't be deleted from Linear's default state list, which is
     why it's required — it's mapped to a `Condition:Duplicate` GitHub label
     plus Canceled status, since GitHub has no matching column for it.

### 2. Linear.app — connect the GitHub integration for this repo

This is the linking mechanism the *entire* system depends on (every sync
direction resolves its counterpart via Linear's own attachment links) —
skipping it means everything below silently no-ops.

1. In Linear: **Settings -> Integrations -> GitHub**.
2. Make sure the **target GitHub repo is included**. This step matters more
   than it looks: Linear's own GitHub App (`linear-code`) is installed with
   **"selected repositories" access**, not "all" — unlike our own
   `dbbuilder-workflow` App. A brand-new repo is **not** automatically
   visible to Linear until you explicitly add it here (which will prompt a
   GitHub permission-grant flow).
3. If a repo doesn't appear or issues aren't linking, check
   `github.com/organizations/dbbuilder-org/settings/installations` ->
   `linear-code` -> confirm the repo is listed under its repository access.
4. Sanity-check the link works: open (or create) a GitHub issue in the repo,
   confirm a matching Linear issue appears in the team shortly after
   (Linear's native mirroring), and that each side shows an attachment
   linking to the other.

### 3. GitHub — create the "Issue Boards" project (if the repo doesn't have one)

Nothing creates this automatically — it must already exist before running
the onboarding workflow.

1. Create an org-level GitHub Project (`gh project create --owner
   dbbuilder-org --title "..."`, or via the UI), or reuse an existing one
   if repos share a board.
2. It needs a single-select **Status** field whose options include at
   least: `Todo`, `Blocked`, `In Review`, `Done`, `Canceled`.
   `Backlog`/`In Progress` are optional, same rule as the Linear states.
3. Note the **project number** (visible in its URL).

### 4. Run the onboarding workflow

This automates everything reachable via the GitHub/Linear APIs for **status
sync only** (see the gaps in step 5 for what it doesn't cover yet).

```powershell
gh workflow run onboard-linear-status-sync.yml --repo dbbuilder-org/.github `
  -f repo=<repo-name> `
  -f linear_team_key=<TEAM_KEY> `
  -f github_project_number=<number>
```

Or via the Actions tab: `dbbuilder-org/.github` -> Actions -> "Dispatch:
Onboard Linear Status Sync" -> Run workflow.

Optional inputs: `organization` (default `dbbuilder-org`), `worker_url`
(defaults to the existing Worker), `open_pr_for_github` (`true` opens a PR
for the `project-drag.yml`/`linear-drag.yml` routing changes instead of
pushing straight to `main`). Safe to re-run — every step checks for
existing state first and skips rather than duplicating.

What it does: looks up the Linear team's state IDs and the GitHub Project's
Status field/option IDs, links the repo to the Project, creates a Linear
webhook (reusing the existing shared signing secret), writes a caller
`linear-status-sync.yml` into the target repo (via PR), and adds routing
entries to `project-drag.yml`/`linear-drag.yml` in `dbbuilder-org/.github`.

### 5. Manual follow-up the onboarding workflow does *not* cover

These were added to the system after the onboarding workflow was built, so
they're not yet automated — do them by hand:

- **Merge the PR(s)** the workflow opened (check its run's step summary for
  exactly which ones — usually the caller-workflow PR in the target repo,
  and sometimes a routing PR in `dbbuilder-org/.github` if
  `open_pr_for_github` was set).
- **Relationships polling — add the new team's key.** Edit
  `.github/workflows/linear-relation-poll.yml` in `dbbuilder-org/.github`
  and add the new Linear team key to the `TEAM_KEYS` line, e.g.:
  ```bash
  TEAM_KEYS="BB <NEW_KEY>"
  ```
  Without this, blocked-by relations created directly in Linear.app for the
  new team will never reconcile onto GitHub (the webhook-driven GitHub ->
  Linear leg works regardless — it isn't team-scoped).
- **Priority sync**: nothing to do — it rides the same Linear Issue webhook
  the onboarding workflow already creates, and GitHub's Priority field is
  org-wide. Confirm it works in the testing checklist below rather than
  configuring anything.
- **Sub-issues**: nothing to do, and nothing to build — confirm Linear's
  native GitHub integration (step 2 above) is connected; parent/child sync
  happens on its own, independent of anything in this repo.

## Full verification checklist

Do these after merging the PR(s) above. Give each webhook a few seconds to a
minute to land before checking.

- **Status**
  - [ ] Close/reopen/label a GitHub issue in the new repo -> linked Linear
        issue's state changes.
  - [ ] Change the Linear issue's state (drag or API) -> GitHub Project
        card's Status field updates.
  - [ ] Drag a card on the GitHub Project board -> linked Linear issue's
        state changes.
- **Priority**
  - [ ] Set the GitHub issue's Priority field -> Linear issue's priority
        updates.
  - [ ] Change the Linear issue's priority -> GitHub issue's Priority field
        updates.
- **Relationships (blocks/blocked-by)**
  - [ ] On GitHub, set issue A "blocked by" issue B -> Linear shows a
        matching `blocks` relation (B blocks A) shortly after.
  - [ ] In Linear.app, create a `blocks` relation between two linked issues
        -> GitHub shows the matching blocked-by edge **after the next poll
        run** (every 15 min — trigger `linear-relation-poll.yml` manually
        via `workflow_dispatch` to check sooner without waiting).
- **Sub-issues** (confirms Linear's *native* sync, not this system — there's
  no custom workflow to watch here anymore)
  - [ ] Set a parent/child relationship on GitHub -> Linear's `parentId`
        updates on its own.
  - [ ] Set it in Linear -> GitHub's native sub-issue relation updates on
        its own.

## Troubleshooting

- **A Linear webhook delivery does nothing, and no GitHub Actions run ever
  appears** — the Cloudflare Worker is likely throwing before it can
  dispatch. A crashing Worker returns a generic Cloudflare error page
  (`error code: 1101`), not a useful message. The most common cause is a
  missing or misnamed Worker secret — double-check the exact (case-sensitive)
  names in the Cloudflare dashboard under Settings -> Variables and Secrets
  match what `cloudflare-worker/worker.js` expects.
- **Nothing syncs at all, in either direction, for a specific repo** — check
  step 2 first: is the target repo actually granted to the `linear-code`
  GitHub App under `github.com/organizations/dbbuilder-org/settings/installations`?
  Since that App uses "selected repositories" access (not "all"), a repo
  simply not being listed there means Linear has no attachment link to
  resolve, and every direction silently no-ops.
- **A GitHub Actions run fires but does nothing** — check its logs for
  `"has no linked Linear issue"` / `"no Issue Boards project registered"` /
  `"not linked to Linear"` / `"Unknown status"` style messages; these are
  intentional no-ops, usually meaning the item isn't Linear-linked yet, or a
  state/team isn't registered for that repo.
- **Blocked-by relations created in Linear.app never appear on GitHub** —
  confirm the new team's key was actually added to `TEAM_KEYS` in
  `linear-relation-poll.yml` (step 5 above); this is the one manual wiring
  step the onboarding workflow doesn't do yet.
- **The onboarding run itself fails** —
  `gh run list --repo dbbuilder-org/.github --workflow=onboard-linear-status-sync.yml`
  and `gh run view <id> --log` to see which step failed; each step errors
  clearly on a missing Linear state, missing Project option, or missing
  Status field rather than failing silently.
