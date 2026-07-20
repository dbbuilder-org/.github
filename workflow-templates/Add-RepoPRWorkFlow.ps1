<#
.SYNOPSIS
	Adds a repo to the shared "PR Boards" project (dbbuilder-org/projects/7)
	and wires up its PR status sync automation.

.PARAMETER Repo
	Repository name for which a board is to be added to PR Boards
	Required.

.PARAMETER Organization
	Org/owner name
	Defaults to dbbuilder-org.

.PARAMETER RepoClonePath
	Path to a local clone of the repo.
	Defaults to a folder with the name of the Repo parallel to this repo.

.PARAMETER SkipAccessCheck
	Specifies the checks for verifying org secrets access and GitHub App visibility are not needed.
	Do not use unless these have been verified by hand by somebody that has the correct access.

.EXAMPLE
	./Add-Repo.ps1 -Repo MyRepo

.EXAMPLE
	./Add-Repo.ps1 -Repo MyRepo -RepoClonePath C:/Repos/MyRepo
#>
param(
	[Parameter(Mandatory)]
	[string] $Repo,

	[string] $Organization = "dbbuilder-org",

	[string] $RepoClonePath = (Resolve-Path "$PSScriptRoot/../../$Repo"),

	[switch] $SkipAccessCheck
)

$ErrorActionPreference = "Stop"

#region Constants

$Script:_scopes = @(
	"project"   # Required to Gather IDs for the PR Board Project
	"repo"      # Required to access the Repos in $Script:_repos
	"workflow"  # Required to add/update files in the Target Repo's .github/workflows/ folder
	"admin:org" # Required to read the WORKFLOW_APP_ID / WORKFLOW_APP_PRIVATE_KEY org secrets and check the GitHub App's org-wide installation
)

$Script:_repos = @{
	Target   = "$Organization/$Repo"
	Workflow = "dbbuilder-org/.github"
}

$Script:_repoWorkflowTarget = ".github/workflows/pr-status-sync.yml"

$Script:_prBoardName = "PR Boards"

#endregion Constants

#region Internal Functions

<#
.SYNOPSIS
	Reads the specified file from the specified repo.

.PARAMETER Repo
	The {organization}/{Repo} where the file is located.
	If not specified, defaults to the default workflow Repo ($Script:_repos.Workflow)

.PARAMETER FilePath
	The path to the file in the Repo.

.NOTES
	Using gh api returns the content in base64 format with line breaks, so it has to be decoded.
#>
function Read-GitHubRepoFile {
	[CmdletBinding(DefaultParameterSetName = "Base")]
	param (
		[Parameter(Mandatory, Position = 0, ParameterSetName = "withRepo")]
		[string] $Repo,

		[Parameter(Mandatory, Position = 0, ParameterSetName = "Base")]
		[Parameter(Mandatory, Position = 1, ParameterSetName = "withRepo")]
		[string] $FilePath
	)
	if (!$Repo) { $Repo = $Script:_repos.Workflow }

	$repoPath = "repos/$Repo/contents/$FilePath"

	$content = gh api $repoPath --jq ".content" | 
		Join-String | 
		ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }

	if (!$content) {
		throw "Couldn't read '$repoPath'"
	}

	return $content
}

#endregion Internal Functions

#region ========== Verify Authentication with needed scopes. ==========================================================
Write-Host "Verifying Authentication..." -ForegroundColor Cyan
$scopes = (gh auth status --json hosts --jq '.hosts."github.com"[0].scopes') -split ", "
if ($LASTEXITCODE -ne 0) {
	Write-Host "`tAuthenticate: gh auth login" -ForegroundColor Yellow
	gh auth login --scopes $($Script:_scopes -join ", ")
	if ($LASTEXITCODE -ne 0) {
		throw "gh auth login failed."
	}
	$scopes = (gh auth status --json hosts --jq '.hosts."github.com"[0].scopes') -split ", "
}

$diffs = Compare-Object $scopes $Script:_scopes | Where-Object SideIndicator -EQ "=>"
if ($null -ne $diffs) {
	gh auth refresh -h github.com -s ($Script:_scopes -join ",")
	if ($LASTEXITCODE -ne 0) {
		throw "Cannot get needed auth scopes: $diffs"
	}
}

Write-Host "`tAuthenticated" -ForegroundColor Green

#endregion ======= Verify Authentication with needed scopes. ==========================================================

$manualSteps = New-Object System.Collections.Generic.List[string]

#region ========== Verify org secret + GitHub App visibility ==========================================================
if (!$SkipAccessCheck) {
	Write-Host "Checking org-wide secret/App access..." -ForegroundColor Cyan

	# org secret
	$secretAccessVerified = $true
	try {
		$secrets = gh api "orgs/$Organization/actions/secrets" --jq '.secrets[] | select(.name == "WORKFLOW_APP_ID" or .name == "WORKFLOW_APP_PRIVATE_KEY") | "\(.name)`t\(.visibility)"' 2>$null
		if ($LASTEXITCODE -ne 0 -or -not $secrets) { throw "check failed" }
		foreach ($line in $secrets) {
			$name, $visibility = $line -split "``t"
			if ($visibility -ne "all") {
				$manualSteps.Add((
						"Org secret '$name' has visibility '$visibility', not 'all'" +
						" — confirm $($Script:_repos.Target) is in its selected-repos list."
					))
				$secretAccessVerified = $false
			}
		}

		if ($secretAccessVerified) {
			Write-Host "`torg secrets OK (visibility=all)." -ForegroundColor Green
		}
		else {
			throw "Cannot verify secret access"
		}
	}
	catch {
		$manualSteps.Add("Verify WORKFLOW_APP_ID/WORKFLOW_APP_PRIVATE_KEY org secrets are visible to '$($Script:_repos.Target)'. (Requires org owner / admin:org scope).")
	}

	# GitHub App visibility
	$appAccessVerified = $true
	try {
		$appScope = gh api "orgs/$Organization/installations" --jq '.installations[] | select(.app_slug == "dbbuilder-workflow") | .repository_selection' 2>$null
		if ($LASTEXITCODE -ne 0 -or -not $appScope) { throw "check failed" }
		if ($appScope -ne "all") {
			$appAccessVerified = $false
			$manualSteps.Add((
					"The 'dbbuilder-workflow' GitHub App is scoped to 'selected' repos, not 'all'" +
					" — confirm $($Script:_repos.Target) is included." +
					"`nOrg Settings > GitHub Apps: https://github.com/organizations/dbbuilder-org/settings/installations"
				))
			Write-Host "`tThe 'dbbuilder-workflow' GitHub App is scoped to 'selected' repos, not 'all'." -ForegroundColor Yellow
		}
		else {
			Write-Host "`tGitHub App OK (installed on all repos)." -ForegroundColor Green
		}
	}
	catch {
		$appAccessVerified = $false
		$manualSteps.Add("Verify the 'dbbuilder-workflow' GitHub App is installed with access to '$($Script:_repos.Target)'. (Requires org owner / admin:org scope).")
	}

	if (!$secretAccessVerified -or !$appAccessVerified) {
		# TODO: Verify that the the script will still work, if the proper access is set, but the current user can't verify it.
		$manualSteps.Add("If secret/App access is verified externally, use -SkipAccessCheck next time this script is run.")
	}
}

#endregion ======= Verify org secret + GitHub App visibility ==========================================================

#region ========== Gather IDs =========================================================================================

$repoId = gh api "repos/$($Script:_repos.Target)" --jq ".node_id"
if (-not $repoId) { throw "Could not resolve repo node ID for $($Script:_repos.Target). Does it exist?" }

$projectPrBoard = gh project list --owner $Organization --format json --jq ".projects[] | select(.title == `"$Script:_prBoardName`")" |
	ConvertFrom-Json -AsHashtable
$projectPrBoard.fields = @{ }
gh project field-list $projectPrBoard.number --owner $projectPrBoard.owner.login  --format json | 
	ConvertFrom-Json |
	Select-Object -ExpandProperty fields |
	ForEach-Object { 
		$field = $_
		$projectPrBoard.fields."$($field.name)" = @{ 
			id   = $field.id
			type = $field.type
		}
		if ($field.options) {
			$projectPrBoard.fields."$($field.name)".options = @{ }
			$field.options | ForEach-Object {
				$projectPrBoard.fields."$($field.name)".options."$($_.name)" = @{ id = $_.id }
			}
		}
	}

#endregion ======= Gather IDs =========================================================================================

#region ========== Link repo to project "PR Boards" ===================================================================
Write-Host "Linking $($Script:_repos.Target) to project 'PR Boards'..." -ForegroundColor Cyan

$linkedRepos = gh api graphql -f query='
  query($proj: ID!) {
    node(id: $proj) {
      ... on ProjectV2 { repositories(first: 100) { nodes { nameWithOwner } } }
    }
  }' -f proj=$($projectPrBoard.id) --jq '.data.node.repositories.nodes[].nameWithOwner'

if ($linkedRepos -contains $Script:_repos.Target) {
	Write-Host "`talready linked." -ForegroundColor DarkGray
}
else {
	gh api graphql -f query='
      mutation($proj: ID!, $repo: ID!) {
        linkProjectV2ToRepository(input: { projectId: $proj, repositoryId: $repo }) {
          repository { nameWithOwner }
        }
      }' -f proj=$($projectPrBoard.id) -f repo=$repoId | Out-Null
	Write-Host "`tlinked." -ForegroundColor Green
}
#endregion ======= Link repo to project "PR Boards" ===================================================================

#region ========== Install the Repos's version of the PR workflow =====================================================
Write-Host "Adding Workflow to Repo..." -ForegroundColor Cyan

$repoWorkflowFile = Join-Path $RepoClonePath $Script:_repoWorkflowTarget

$mergedOnMain = $false
try {
	$null = gh api "repos/$($Script:_repos.Target)/contents/$($Script:_repoWorkflowTarget)?ref=main" --jq ".sha" 2>$null
	if ($LASTEXITCODE -eq 0) {
		Write-Host "`tconfirmed merged into main — assuming up-to-date." -ForegroundColor Green
		$mergedOnMain = $true
	}
}
catch { }

if (!$mergedOnMain) {
	if (Test-Path $repoWorkflowFile) {
		Write-Host "`t$repoWorkflowFile already exists — leaving it alone." -ForegroundColor Yellow
		$manualSteps.Add("$Repo already has $Script:_repoWorkflowTarget — verify it matches workflow-templates/pr-status-sync.yml (project 'PR Board') rather than pointing at a different/older project.")
	}
	else {
		Read-GitHubRepoFile "workflow-templates/pr-status-sync.yml" | Set-Content $repoWorkflowFile -NoNewline
		$manualSteps.Add("Review and commit/push $repoWorkflowFile to $($Script:_repos.Target)'s default branch")
	}
}

#endregion ======= Install the Repos's version of the PR workflow =====================================================

#region ========== Create Board View ==================================================================================
# NOTE: GitHub intentionally restricts boards from being managed or created via CLI. It has to be done via REST API.
Write-Host "Creating the tab on PR Boards..." -ForegroundColor Cyan

# See if it already exists:
$view = gh api graphql -f query='
	query($owner: String!, $number: Int!) {
		organization(login: $owner) {
			projectV2(number: $number) {
				views(first: 20) {
					nodes {
						id
						name
						number
						layout
						createdAt
						updatedAt
						filter
						fullDatabaseId
					}
				}
			}
		}
	}' -F owner=$Organization -F number=$($projectPrBoard.number) --jq '.data.organization.projectV2.views.nodes' |
	ConvertFrom-Json |
	Where-Object name -EQ $Repo

if ($null -ne $view) {
	Write-Host "`talready exists." -ForegroundColor DarkGray
}
else {
	$params = @{
		Uri     = "https://api.github.com/orgs/$($Organization)/projectsV2/$($projectPrBoard.number)/views"
		Method  = "Post"
		Headers = @{
			Authorization          = "Bearer $(gh auth token)"
			Accept                 = "application/vnd.github+json"
			"X-GitHub-Api-Version" = "2022-11-28"
		}
		Body    = @{
			name   = $Repo
			layout = "board"
		} | ConvertTo-Json
	}
	try {
		$view = Invoke-RestMethod @params
		Write-Host "`tCreated" -ForegroundColor Green
	} 
	catch {
		Write-Host "`t$($_.Exception.Message)" -ForegroundColor Red
		throw
	}
}

#endregion ======= Create Board View ==================================================================================

if ($manualSteps.Count -eq 0) {
	#region ========== One-time closed/merged PR backfill (If all went well) ==========================================
	Write-Host "Backfilling closed/merged PRs for $($Script:_repos.Target)..." -ForegroundColor Cyan
	
	$prs = gh api "repos/$($Script:_repos.Target)/pulls?state=closed&per_page=100" --paginate --jq '.[] | "\(.number)`t\(.node_id)`t\(.merged_at // "")"'
	$count = 0
	foreach ($line in $prs) {
		if (-not $line) { continue }
		$number, $nodeId, $mergedAt = $line -split "``t"
	
		$itemId = gh api graphql -f query='
			  mutation($proj: ID!, $pr: ID!) {
				addProjectV2ItemById(input: { projectId: $proj, contentId: $pr }) {
				  item { id }
				}
			  }' -f proj=$($projectPrBoard.id) -f pr=$nodeId --jq '.data.addProjectV2ItemById.item.id'
	
		if (-not $itemId) {
			Write-Host "`tFAILED to add PR #$number" -ForegroundColor Red
			continue
		}
	
		$opt = if ($mergedAt) { $projectPrBoard.fields.Status.options.Done.id } else { $projectPrBoard.fields.Status.options.Abandoned.id }
		gh api graphql -f query='
			  mutation($proj: ID!, $item: ID!, $field: ID!, $opt: String!) {
				updateProjectV2ItemFieldValue(input: {
				  projectId: $proj, itemId: $item,
				  fieldId: $field, value: { singleSelectOptionId: $opt }
				}) { projectV2Item { id } }
			  }' -f proj=$($projectPrBoard.id) -f item=$itemId -f field=$($projectPrBoard.fields.Status.id) -f opt=$opt | Out-Null
	
		$count++
	}
	Write-Host "`tBackfilled $count closed/merged PR(s)." -ForegroundColor Green
	
	Write-Host "Running Workflow..." -ForegroundColor Cyan
	gh workflow run pr-status-sync.yml --repo $Script:_repos.Target
	
	#endregion ======= One-time closed/merged PR backfill (If all went well) ==========================================
}
else {
	# Output the manual steps that need to be completed.
	Write-Host ""
	Write-Host "=== Manual steps remaining ===" -ForegroundColor Magenta
	foreach ($item in $manualSteps) {
		Write-Host " - $item"
	}
	Write-Host " - Rerun this script: $($PSCmdlet.MyInvocation.Statement)"
}
