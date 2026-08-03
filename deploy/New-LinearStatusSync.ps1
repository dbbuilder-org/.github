<#
.SYNOPSIS
	Onboards a repo onto the GitHub <-> Linear status-sync system:
	  - GitHub issue/PR events + GitHub Project drags -> Linear issue state
	  - Linear issue state changes -> GitHub Project "Status" field

	Mirrors the pattern set up for dbbuilder-org/billboard <-> Linear team SV1.
	Automates everything reachable via the GitHub/Linear APIs; anything that
	can't be (see the accompanying README.md) is called out at the end as a
	manual step.

.PARAMETER Repo
	Repository name to onboard (e.g. "billboard"). Required.

.PARAMETER LinearTeamKey
	The Linear team key to sync with (e.g. "SV1"). Required.

.PARAMETER LinearApiKey
	A Linear Personal API Key (or workspace API key) with read/write access.
	Required. Get one at linear.app/settings/account/security.

.PARAMETER LinearWebhookSecret
	The EXACT value already configured as the Cloudflare Worker's
	LINEAR_WEBHOOK_SECRET. Required. The worker verifies every incoming
	Linear webhook against one shared secret, so the new webhook this script
	creates must reuse that same value rather than a freshly generated one.

.PARAMETER Organization
	Org/owner name. Defaults to dbbuilder-org.

.PARAMETER GitHubProjectNumber
	The existing GitHub Project (org-level) number to use as this repo's
	Issue Boards — its Status field options must match Linear's state names.
	Required; this script does not create projects.

.PARAMETER WorkerUrl
	Base URL of the shared Cloudflare Worker. Defaults to the existing one.

.PARAMETER RepoClonePath
	Path to a local clone of the target repo. Defaults to a folder with the
	name of -Repo parallel to this repo (matching workflow-templates'
	Add-RepoPRWorkFlow.ps1 convention).

.PARAMETER OpenPullRequestForGithub
	By default, the project-drag.yml / linear-drag.yml edits in this
	(dbbuilder-org/.github) repo are committed and pushed straight to main,
	matching how every other change to those files has been made this far.
	Pass this switch to push to a branch and open a PR instead.

.PARAMETER SkipAccessCheck
	Skips the gh auth scope check. Do not use unless you've already verified
	you have project/repo/workflow scopes.

.EXAMPLE
	./New-LinearStatusSync.ps1 -Repo billboard -LinearTeamKey SV1 -GitHubProjectNumber 8 `
	  -LinearApiKey $env:LINEAR_API_KEY -LinearWebhookSecret $env:WORKER_LINEAR_WEBHOOK_SECRET
#>
param(
	[Parameter(Mandatory)]
	[string] $Repo,

	[Parameter(Mandatory)]
	[string] $LinearTeamKey,

	[Parameter(Mandatory)]
	[int] $GitHubProjectNumber,

	[Parameter(Mandatory)]
	[string] $LinearApiKey,

	[Parameter(Mandatory)]
	[string] $LinearWebhookSecret,

	[string] $Organization = "dbbuilder-org",

	[string] $WorkerUrl = "https://plain-pine-0b38.ransom-1d4.workers.dev",

	[string] $RepoClonePath = (Resolve-Path "$PSScriptRoot/../../$Repo" -ErrorAction SilentlyContinue),

	[switch] $OpenPullRequestForGithub,

	[switch] $SkipAccessCheck
)

$ErrorActionPreference = "Stop"

#region ========== Constants ===========================================================================

$Script:_workflowRepoPath = Resolve-Path "$PSScriptRoot/.."   # this checkout IS dbbuilder-org/.github
$Script:_callerWorkflowRelPath = ".github/workflows/linear-status-sync.yml"
$Script:_projectDragFile = Join-Path $Script:_workflowRepoPath ".github/workflows/project-drag.yml"
$Script:_linearDragFile = Join-Path $Script:_workflowRepoPath ".github/workflows/linear-drag.yml"

# Canonical state/status names shared by both systems. Duplicate has no
# GitHub Project column (Issue Boards has no such status) — it becomes a
# Condition:Duplicate label instead, handled already by linear-drag.yml.
$Script:_requiredLinearStates = @("Todo", "Blocked", "In Review", "Done", "Canceled", "Duplicate")
$Script:_optionalLinearStates = @("Backlog", "In Progress")
$Script:_requiredProjectOptions = @("Todo", "Blocked", "In Review", "Done", "Canceled")
$Script:_optionalProjectOptions = @("Backlog", "In Progress")

$manualSteps = New-Object System.Collections.Generic.List[string]

#endregion ======= Constants ===========================================================================

#region ========== Helper functions ====================================================================

function Invoke-LinearGraphQL {
	param(
		[Parameter(Mandatory)] [string] $Query,
		[hashtable] $Variables = @{}
	)
	$body = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 10
	$response = Invoke-RestMethod -Uri "https://api.linear.app/graphql" -Method Post `
		-Headers @{ Authorization = $LinearApiKey; "Content-Type" = "application/json" } `
		-Body $body
	if ($response.errors) {
		throw "Linear API error: $($response.errors | ConvertTo-Json -Depth 5)"
	}
	return $response
}

# Slugifies a repo name into a safe GitHub Actions job-key suffix.
function ConvertTo-JobSlug {
	param([string] $Text)
	return ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

#endregion ======= Helper functions ====================================================================

#region ========== Verify authentication with needed scopes ===========================================

if (-not $SkipAccessCheck) {
	Write-Host "Verifying GitHub authentication..." -ForegroundColor Cyan
	$neededScopes = @("repo", "project", "workflow")
	$scopes = (gh auth status --json hosts --jq '.hosts."github.com"[0].scopes') -split ", "
	$missing = Compare-Object $scopes $neededScopes | Where-Object SideIndicator -EQ "=>"
	if ($null -ne $missing) {
		gh auth refresh -h github.com -s ($neededScopes -join ",")
		if ($LASTEXITCODE -ne 0) { throw "Cannot get needed auth scopes: $missing" }
	}
	Write-Host "`tOK" -ForegroundColor Green
}

#endregion ======= Verify authentication with needed scopes ============================================

#region ========== Resolve the Linear team + its workflow states ======================================

Write-Host "Resolving Linear team '$LinearTeamKey'..." -ForegroundColor Cyan

$teamQuery = @'
query($key: String!) {
  teams(filter: { key: { eq: $key } }) {
    nodes {
      id
      name
      key
      states(first: 50) { nodes { id name type } }
    }
  }
}
'@
$teamResult = Invoke-LinearGraphQL -Query $teamQuery -Variables @{ key = $LinearTeamKey }
$team = $teamResult.data.teams.nodes | Select-Object -First 1
if (-not $team) { throw "No Linear team found with key '$LinearTeamKey'" }

$linearStates = @{}
foreach ($state in $team.states.nodes) {
	$linearStates[$state.name] = $state.id
}

$missingRequired = $Script:_requiredLinearStates | Where-Object { -not $linearStates.ContainsKey($_) }
if ($missingRequired.Count -gt 0) {
	throw "Linear team '$LinearTeamKey' is missing required workflow state(s): $($missingRequired -join ', '). " +
		"Add them (or rename existing states to match) before re-running."
}
foreach ($name in $Script:_optionalLinearStates) {
	if (-not $linearStates.ContainsKey($name)) {
		$manualSteps.Add("Linear team '$LinearTeamKey' has no '$name' state — the project-drag path will skip that status until one is added.")
	}
}

Write-Host "`tFound team '$($team.name)' ($($team.id))" -ForegroundColor Green

#endregion ======= Resolve the Linear team + its workflow states =======================================

#region ========== Resolve the GitHub "Issue Boards" project ===========================================

Write-Host "Resolving GitHub Project #$GitHubProjectNumber..." -ForegroundColor Cyan

$project = gh project view $GitHubProjectNumber --owner $Organization --format json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Could not find project $GitHubProjectNumber for $Organization" }

$fields = gh project field-list $GitHubProjectNumber --owner $Organization --format json | ConvertFrom-Json
$statusField = $fields.fields | Where-Object { $_.name -eq "Status" }
if (-not $statusField) { throw "Project $GitHubProjectNumber has no 'Status' field" }

$projectOptions = @{}
foreach ($opt in $statusField.options) { $projectOptions[$opt.name] = $opt.id }

$missingRequired = $Script:_requiredProjectOptions | Where-Object { -not $projectOptions.ContainsKey($_) }
if ($missingRequired.Count -gt 0) {
	throw "Project $GitHubProjectNumber's Status field is missing required option(s): $($missingRequired -join ', ')."
}
foreach ($name in $Script:_optionalProjectOptions) {
	if (-not $projectOptions.ContainsKey($name)) {
		$manualSteps.Add("Project $GitHubProjectNumber's Status field has no '$name' option — that status will be skipped on drag-sync until it's added.")
	}
}

Write-Host "`tUsing project #$GitHubProjectNumber ($($project.id)), field $($statusField.id)" -ForegroundColor Green

#endregion ======= Resolve the GitHub "Issue Boards" project ============================================

#region ========== Link the repo to the project (idempotent) ===========================================

Write-Host "Linking $Organization/$Repo to project #$GitHubProjectNumber..." -ForegroundColor Cyan

$repoId = gh api "repos/$Organization/$Repo" --jq ".node_id"
if (-not $repoId) { throw "Could not resolve repo node ID for $Organization/$Repo. Does it exist?" }

$linkedRepos = gh api graphql -f query='
  query($proj: ID!) {
    node(id: $proj) {
      ... on ProjectV2 { repositories(first: 100) { nodes { nameWithOwner } } }
    }
  }' -f proj=$($project.id) --jq '.data.node.repositories.nodes[].nameWithOwner'

if ($linkedRepos -contains "$Organization/$Repo") {
	Write-Host "`talready linked." -ForegroundColor DarkGray
}
else {
	gh api graphql -f query='
      mutation($proj: ID!, $repo: ID!) {
        linkProjectV2ToRepository(input: { projectId: $proj, repositoryId: $repo }) {
          repository { nameWithOwner }
        }
      }' -f proj=$($project.id) -f repo=$repoId | Out-Null
	Write-Host "`tlinked." -ForegroundColor Green
}

#endregion ======= Link the repo to the project (idempotent) ===========================================

#region ========== Create the Linear webhook (idempotent) ==============================================

Write-Host "Creating Linear webhook for team '$LinearTeamKey'..." -ForegroundColor Cyan

$webhookUrl = "$WorkerUrl/linear-webhook"
$existing = Invoke-LinearGraphQL -Query '{ webhooks { nodes { id url team { key } } } }'
$already = $existing.data.webhooks.nodes | Where-Object { $_.url -eq $webhookUrl -and $_.team.key -eq $LinearTeamKey }

if ($already) {
	Write-Host "`talready exists ($($already.id))." -ForegroundColor DarkGray
}
else {
	$webhookMutation = @'
mutation($input: WebhookCreateInput!) {
  webhookCreate(input: $input) {
    success
    webhook { id url }
  }
}
'@
	$webhookInput = @{
		label         = "$LinearTeamKey status sync (GitHub)"
		url           = $webhookUrl
		resourceTypes = @("Issue")
		teamId        = $team.id
		secret        = $LinearWebhookSecret
		enabled       = $true
	}
	$webhookResult = Invoke-LinearGraphQL -Query $webhookMutation -Variables @{ input = $webhookInput }
	if (-not $webhookResult.data.webhookCreate.success) {
		throw "Failed to create Linear webhook: $($webhookResult | ConvertTo-Json -Depth 5)"
	}
	Write-Host "`tcreated ($($webhookResult.data.webhookCreate.webhook.id))." -ForegroundColor Green
}

#endregion ======= Create the Linear webhook (idempotent) ==============================================

#region ========== Write the caller workflow into the target repo, commit + PR =========================

Write-Host "Adding caller workflow to $Organization/$Repo..." -ForegroundColor Cyan

if (-not $RepoClonePath -or -not (Test-Path $RepoClonePath)) {
	throw "RepoClonePath '$RepoClonePath' does not exist. Clone $Organization/$Repo locally first (see README.md), or pass -RepoClonePath explicitly."
}

$callerWorkflowPath = Join-Path $RepoClonePath $Script:_callerWorkflowRelPath

if (Test-Path $callerWorkflowPath) {
	Write-Host "`t$callerWorkflowPath already exists — leaving it alone." -ForegroundColor Yellow
	$manualSteps.Add("$Repo already has $Script:_callerWorkflowRelPath — verify it matches the expected shape rather than pointing at stale IDs.")
}
else {
	$dirty = git -C $RepoClonePath status --porcelain
	if ($dirty) { throw "$RepoClonePath has uncommitted changes — commit or stash them first." }

	git -C $RepoClonePath checkout main 2>&1 | Out-Null
	git -C $RepoClonePath pull --ff-only 2>&1 | Out-Null

	$branch = "feat/linear-status-sync"
	git -C $RepoClonePath checkout -b $branch 2>&1 | Out-Null

	$callerYaml = @"
name: Sync Status to Linear

on:
  issues:
    types: [closed, reopened, labeled, unlabeled]
  pull_request_target:
    types: [opened, closed]

permissions:
  contents: read
  issues: read
  pull-requests: read

jobs:
  sync:
    uses: $Organization/.github/.github/workflows/linear-status-sync.yml@main
    with:
      STATE_TODO: "$($linearStates['Todo'])"
      STATE_BLOCKED: "$($linearStates['Blocked'])"
      STATE_IN_REVIEW: "$($linearStates['In Review'])"
      STATE_DONE: "$($linearStates['Done'])"
      STATE_CANCELED: "$($linearStates['Canceled'])"
      STATE_DUPLICATE: "$($linearStates['Duplicate'])"
      event_name: `${{ github.event_name }}
      repo: `${{ github.repository }}
      action: `${{ github.event.action }}
      item_number: `${{ github.event.issue.number || github.event.pull_request.number }}
      html_url: `${{ github.event.issue.html_url || github.event.pull_request.html_url }}
      state_reason: `${{ github.event.issue.state_reason }}
      merged: `${{ github.event.pull_request.merged }}
    secrets:
      linear_api_key: `${{ secrets.LINEAR_API_KEY }}
"@
	New-Item -ItemType Directory -Force (Split-Path $callerWorkflowPath) | Out-Null
	Set-Content -Path $callerWorkflowPath -Value $callerYaml -NoNewline

	git -C $RepoClonePath add $Script:_callerWorkflowRelPath
	git -C $RepoClonePath commit -m "Add Linear status sync workflow" -m "Calls $Organization/.github's reusable linear-status-sync.yml, wired to Linear team $LinearTeamKey." 2>&1 | Out-Null
	git -C $RepoClonePath push -u origin $branch 2>&1 | Out-Null

	gh pr create --repo "$Organization/$Repo" --head $branch --base main `
		--title "Add Linear status sync workflow" `
		--body "Wires this repo into the shared linear-status-sync.yml, syncing issue/PR status to Linear team $LinearTeamKey. See $Organization/.github's deploy/README.md." | Out-Null

	$manualSteps.Add("Review and merge the 'Add Linear status sync workflow' PR in $Organization/$Repo.")
	Write-Host "`topened a PR." -ForegroundColor Green
}

#endregion ======= Write the caller workflow into the target repo, commit + PR ==========================

#region ========== Add drag-routing to project-drag.yml (this repo) ====================================

Write-Host "Adding project-drag.yml routing for project #$GitHubProjectNumber..." -ForegroundColor Cyan

$jobSlug = ConvertTo-JobSlug $Repo
$dragContent = Get-Content $Script:_projectDragFile -Raw

if ($dragContent -match [regex]::Escape($statusField.id)) {
	Write-Host "`talready routed." -ForegroundColor DarkGray
}
else {
	# Clone the existing "handle-drag-issue-boards" job as a template so
	# indentation/structure is guaranteed to match, then substitute values.
	if ($dragContent -notmatch '(?ms)^  handle-drag-issue-boards:.*?\n(?=  \S|\z)') {
		throw "Could not find a 'handle-drag-issue-boards' job in project-drag.yml to use as a template. Add the routing job manually."
	}
	$template = $Matches[0]

	$newJob = $template `
		-replace 'handle-drag-issue-boards:', "handle-drag-issue-boards-$($jobSlug):" `
		-replace "PVTSSF_lADODmqj9M4Be0uqzhZMFd8", $statusField.id `
		-replace 'STATE_BACKLOG: "[^"]*"', "STATE_BACKLOG: `"$($linearStates['Backlog'])`"" `
		-replace 'STATE_TODO: "[^"]*"', "STATE_TODO: `"$($linearStates['Todo'])`"" `
		-replace 'STATE_IN_PROGRESS: "[^"]*"', "STATE_IN_PROGRESS: `"$($linearStates['In Progress'])`"" `
		-replace 'STATE_BLOCKED: "[^"]*"', "STATE_BLOCKED: `"$($linearStates['Blocked'])`"" `
		-replace 'STATE_IN_REVIEW: "[^"]*"', "STATE_IN_REVIEW: `"$($linearStates['In Review'])`"" `
		-replace 'STATE_DONE: "[^"]*"', "STATE_DONE: `"$($linearStates['Done'])`"" `
		-replace 'STATE_CANCELED: "[^"]*"', "STATE_CANCELED: `"$($linearStates['Canceled'])`"" `
		-replace 'STATE_DUPLICATE: "[^"]*"', "STATE_DUPLICATE: `"$($linearStates['Duplicate'])`""

	Add-Content -Path $Script:_projectDragFile -Value "`n$newJob" -NoNewline
	Write-Host "`tadded job 'handle-drag-issue-boards-$jobSlug'." -ForegroundColor Green
}

#endregion ======= Add drag-routing to project-drag.yml (this repo) =====================================

#region ========== Add a repo case-arm to linear-drag.yml (this repo) ==================================

Write-Host "Adding linear-drag.yml case arm for $Organization/$Repo..." -ForegroundColor Cyan

$dragBackContent = Get-Content $Script:_linearDragFile -Raw
$repoKey = "$Organization/$Repo"

if ($dragBackContent -match [regex]::Escape("$repoKey)")) {
	Write-Host "`talready registered." -ForegroundColor DarkGray
}
else {
	if ($dragBackContent -notmatch '(?ms)^(\s+)dbbuilder-org/billboard\)\n(.*?\n\1  ;;\n)') {
		throw "Could not find the 'dbbuilder-org/billboard)' case arm in linear-drag.yml to use as a template. Add the case arm manually."
	}
	$indent = $Matches[1]
	$template = "$indent" + "dbbuilder-org/billboard)`n" + $Matches[2]

	$newArm = $template `
		-replace [regex]::Escape("dbbuilder-org/billboard"), $repoKey `
		-replace 'PVT_kwDODmqj9M4Be0uq', $project.id `
		-replace 'PVTSSF_lADODmqj9M4Be0uqzhZMFd8', $statusField.id `
		-replace 'OPT_BACKLOG="[^"]*"', "OPT_BACKLOG=`"$($projectOptions['Backlog'])`"" `
		-replace 'OPT_TODO="[^"]*"', "OPT_TODO=`"$($projectOptions['Todo'])`"" `
		-replace 'OPT_IN_PROGRESS="[^"]*"', "OPT_IN_PROGRESS=`"$($projectOptions['In Progress'])`"" `
		-replace 'OPT_IN_REVIEW="[^"]*"', "OPT_IN_REVIEW=`"$($projectOptions['In Review'])`"" `
		-replace 'OPT_BLOCKED="[^"]*"', "OPT_BLOCKED=`"$($projectOptions['Blocked'])`"" `
		-replace 'OPT_DONE="[^"]*"', "OPT_DONE=`"$($projectOptions['Done'])`"" `
		-replace 'OPT_CANCELED="[^"]*"', "OPT_CANCELED=`"$($projectOptions['Canceled'])`""

	# Insert the new arm right before the existing template arm (so the
	# default `*)` catch-all at the bottom of the case stays last).
	$updated = $dragBackContent.Replace($template, "$newArm$template")
	Set-Content -Path $Script:_linearDragFile -Value $updated -NoNewline
	Write-Host "`tadded case arm for $repoKey." -ForegroundColor Green
}

#endregion ======= Add a repo case-arm to linear-drag.yml (this repo) ===================================

#region ========== Commit + publish this repo's changes =================================================

$thisRepoDirty = git -C $Script:_workflowRepoPath status --porcelain -- .github/workflows/project-drag.yml .github/workflows/linear-drag.yml
if (-not $thisRepoDirty) {
	Write-Host "No changes needed in $Organization/.github (routing already existed)." -ForegroundColor DarkGray
}
else {
	Write-Host "Publishing $Organization/.github changes..." -ForegroundColor Cyan
	git -C $Script:_workflowRepoPath add .github/workflows/project-drag.yml .github/workflows/linear-drag.yml

	if ($OpenPullRequestForGithub) {
		$branch = "feat/linear-status-sync-$jobSlug"
		git -C $Script:_workflowRepoPath checkout -b $branch 2>&1 | Out-Null
		git -C $Script:_workflowRepoPath commit -m "Route $repoKey's drags to/from Linear team $LinearTeamKey" 2>&1 | Out-Null
		git -C $Script:_workflowRepoPath push -u origin $branch 2>&1 | Out-Null
		gh pr create --repo "$Organization/.github" --head $branch --base main `
			--title "Route $repoKey's drags to/from Linear team $LinearTeamKey" `
			--body "Adds project-drag.yml + linear-drag.yml routing for $repoKey <-> Linear team $LinearTeamKey." | Out-Null
		$manualSteps.Add("Review and merge the routing PR in $Organization/.github.")
		Write-Host "`topened a PR." -ForegroundColor Green
	}
	else {
		git -C $Script:_workflowRepoPath commit -m "Route $repoKey's drags to/from Linear team $LinearTeamKey" 2>&1 | Out-Null
		git -C $Script:_workflowRepoPath push origin main 2>&1 | Out-Null
		Write-Host "`tpushed to main." -ForegroundColor Green
	}
}

#endregion ======= Commit + publish this repo's changes =================================================

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Magenta
if ($manualSteps.Count -eq 0) {
	Write-Host "No manual steps outstanding beyond what's already in README.md's checklist." -ForegroundColor Green
}
else {
	Write-Host "Remaining manual steps:" -ForegroundColor Yellow
	foreach ($item in $manualSteps) { Write-Host " - $item" }
}
