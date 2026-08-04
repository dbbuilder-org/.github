#!/usr/bin/env bash
# Shared Linear helper functions for linear-status-sync workflows.
# Source this file; do not execute it directly.
# Converted to LF line endings.
#
# shellcheck disable=SC2016
# This file is single-quoted `query='...'`/`-f query='...'` GraphQL literals
# throughout. Those `$name` tokens are GraphQL variables (passed separately
# via jq/-f), not bash variables — double-quoting would make bash expand them
# and corrupt the query text, so the single quotes are intentional.

# Call the Linear GraphQL API.
# Args: QUERY  VARS_JSON (a JSON object string, e.g. '{"url":"..."}')
# Requires env var: LINEAR_API_KEY
linear_api() {
  local query="$1" vars="$2"
  [[ -z "$vars" ]] && vars='{}'
  local body
  body=$(jq -n --arg q "$query" --argjson v "$vars" '{query: $q, variables: $v}')
  curl -s https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# Resolve a GitHub issue/PR URL to its linked Linear issue via Linear's own
# GitHub integration attachments (no magic-word parsing needed).
# Args: HTML_URL
# Prints: "ISSUE_ID<TAB>CURRENT_STATE_ID", or nothing if not linked.
linear_lookup() {
  local html_url="$1"
  linear_api \
    'query($url: String!) { attachmentsForURL(url: $url) { nodes { issue { id state { id } } } } }' \
    "$(jq -n --arg url "$html_url" '{url: $url}')" \
    | jq -r '.data.attachmentsForURL.nodes[0] | select(. != null) | "\(.issue.id)\t\(.issue.state.id)"'
}

# Set a Linear issue's workflow state.
# Args: ISSUE_ID  STATE_ID
# Prints the raw GraphQL response (caller checks .data.issueUpdate.success).
linear_set_state() {
  local issue_id="$1" state_id="$2"
  linear_api \
    'mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { identifier state { name } } } }' \
    "$(jq -n --arg id "$issue_id" --arg stateId "$state_id" '{id: $id, stateId: $stateId}')"
}

# Look up the Linear issue linked to HTML_URL and move it to STATE_ID.
# No-ops (logs + returns 0) when the item isn't linked to a Linear issue, when
# STATE_ID is empty, or when it's already at STATE_ID — that last check is
# load-bearing, not just an optimization: without it, this and the GitHub
# Project status write it can trigger in turn (see linear-drag.yml) form an
# unbounded feedback loop the moment either side's webhook fires on a write
# that doesn't actually change anything (confirmed happening 2026-08-03).
# Args: HTML_URL  STATE_ID
sync_linear_status() {
  local html_url="$1" state_id="$2"
  if [[ -z "$state_id" ]]; then
    echo "sync_linear_status: no target state for $html_url — skipping"
    return 0
  fi

  local lookup issue_id current_state_id
  lookup=$(linear_lookup "$html_url")
  issue_id=$(cut -f1 <<< "$lookup")
  current_state_id=$(cut -f2 <<< "$lookup")
  if [[ -z "$issue_id" ]]; then
    echo "sync_linear_status: $html_url has no linked Linear issue — skipping"
    return 0
  fi
  if [[ "$current_state_id" == "$state_id" ]]; then
    echo "sync_linear_status: $issue_id already at target state — skipping"
    return 0
  fi

  local result
  result=$(linear_set_state "$issue_id" "$state_id")
  if [[ "$(jq -r '.data.issueUpdate.success // false' <<< "$result")" != "true" ]]; then
    echo "sync_linear_status: failed to update $issue_id: $result" >&2
    return 1
  fi
  echo "sync_linear_status: $(jq -r '.data.issueUpdate.issue.identifier' <<< "$result") -> $(jq -r '.data.issueUpdate.issue.state.name' <<< "$result")"
}

# Look up the Linear issue linked to HTML_URL and set its priority (an
# integer 0-4: 0=No priority, 1=Urgent, 2=High, 3=Medium, 4=Low). No-ops when
# the item isn't linked, or is already at PRIORITY — same load-bearing
# no-op guard as sync_linear_status, for the same feedback-loop reason.
# Args: HTML_URL  PRIORITY
sync_linear_priority() {
  local html_url="$1" priority="$2"

  local result issue_id current_priority
  result=$(linear_api \
    'query($url: String!) { attachmentsForURL(url: $url) { nodes { issue { id priority } } } }' \
    "$(jq -n --arg url "$html_url" '{url: $url}')")
  issue_id=$(jq -r '.data.attachmentsForURL.nodes[0].issue.id // empty' <<< "$result")
  if [[ -z "$issue_id" ]]; then
    echo "sync_linear_priority: $html_url has no linked Linear issue — skipping"
    return 0
  fi
  current_priority=$(jq -r '.data.attachmentsForURL.nodes[0].issue.priority' <<< "$result")
  if [[ "$current_priority" == "$priority" ]]; then
    echo "sync_linear_priority: $issue_id already at priority $priority — skipping"
    return 0
  fi

  local update
  update=$(linear_api \
    'mutation($id: String!, $priority: Int!) { issueUpdate(id: $id, input: { priority: $priority }) { success issue { identifier priority } } }' \
    "$(jq -n --arg id "$issue_id" --argjson priority "$priority" '{id: $id, priority: $priority}')")
  if [[ "$(jq -r '.data.issueUpdate.success // false' <<< "$update")" != "true" ]]; then
    echo "sync_linear_priority: failed to update $issue_id: $update" >&2
    return 1
  fi
  echo "sync_linear_priority: $(jq -r '.data.issueUpdate.issue.identifier' <<< "$update") -> priority $(jq -r '.data.issueUpdate.issue.priority' <<< "$update")"
}

# Resolve a GitHub issue/PR URL to its linked Linear issue ID (a lighter
# version of linear_lookup for callers that don't need current state).
# Args: HTML_URL
linear_issue_id() {
  local html_url="$1"
  linear_api \
    'query($url: String!) { attachmentsForURL(url: $url) { nodes { issue { id } } } }' \
    "$(jq -n --arg url "$html_url" '{url: $url}')" \
    | jq -r '.data.attachmentsForURL.nodes[0].issue.id // empty'
}

# Create or remove a Linear "blocks" relation (BLOCKING_HTML_URL blocks
# BLOCKED_HTML_URL) to mirror a GitHub issue-dependency change. No-ops when
# either side isn't linked to Linear, or the relation is already in the
# target state — same load-bearing feedback-loop guard as sync_linear_status.
# Args: BLOCKING_HTML_URL  BLOCKED_HTML_URL  ACTION(add|remove)
sync_linear_blocks() {
  local blocking_url="$1" blocked_url="$2" action="$3"
  local blocking_id blocked_id
  blocking_id=$(linear_issue_id "$blocking_url")
  blocked_id=$(linear_issue_id "$blocked_url")
  if [[ -z "$blocking_id" || -z "$blocked_id" ]]; then
    echo "sync_linear_blocks: one or both issues not linked to Linear — skipping"
    return 0
  fi

  local existing_relation_id
  existing_relation_id=$(linear_api \
    'query($id: String!) { issue(id: $id) { relations { nodes { id type relatedIssue { id } } } } }' \
    "$(jq -n --arg id "$blocking_id" '{id: $id}')" \
    | jq -r --arg related "$blocked_id" '[.data.issue.relations.nodes[] | select(.type == "blocks" and .relatedIssue.id == $related)][0].id // empty')

  local result
  if [[ "$action" == "remove" ]]; then
    if [[ -z "$existing_relation_id" ]]; then
      echo "sync_linear_blocks: no existing relation to remove — skipping"
      return 0
    fi
    result=$(linear_api \
      'mutation($id: String!) { issueRelationDelete(id: $id) { success } }' \
      "$(jq -n --arg id "$existing_relation_id" '{id: $id}')")
    if [[ "$(jq -r '.data.issueRelationDelete.success // false' <<< "$result")" != "true" ]]; then
      echo "sync_linear_blocks: failed to remove relation $existing_relation_id: $result" >&2
      return 1
    fi
    echo "sync_linear_blocks: removed relation $existing_relation_id"
    return 0
  fi

  if [[ -n "$existing_relation_id" ]]; then
    echo "sync_linear_blocks: relation already exists — skipping"
    return 0
  fi
  result=$(linear_api \
    'mutation($issueId: String!, $relatedId: String!) { issueRelationCreate(input: { issueId: $issueId, relatedIssueId: $relatedId, type: blocks }) { success } }' \
    "$(jq -n --arg issueId "$blocking_id" --arg relatedId "$blocked_id" '{issueId: $issueId, relatedId: $relatedId}')")
  if [[ "$(jq -r '.data.issueRelationCreate.success // false' <<< "$result")" != "true" ]]; then
    echo "sync_linear_blocks: failed to create relation: $result" >&2
    return 1
  fi
  echo "sync_linear_blocks: created relation $blocking_id blocks $blocked_id"
}

# Map a GitHub "Priority" Issue Field option name to a Linear priority
# integer. Empty NAME (field cleared) maps to 0 (No priority).
# Args: OPTION_NAME
priority_name_to_linear_priority() {
  case "$1" in
    Urgent) echo 1 ;;
    High)   echo 2 ;;
    Medium) echo 3 ;;
    Low)    echo 4 ;;
    "")     echo 0 ;;
    *)      echo "" ;;
  esac
}

# Decide the Blocked/Duplicate override state for an issue/PR from its
# current GitHub labels. Prints nothing if no override label is present,
# meaning the caller should fall back to its own default state.
# Args: REPO  NUMBER
# Requires env vars: GH_TOKEN, BLOCKING_LABELS (comma-separated),
#                     DUPLICATE_LABEL, STATE_BLOCKED, STATE_DUPLICATE
label_override_state() {
  local repo="$1" number="$2"
  local labels
  labels=$(gh api repos/"$repo"/issues/"$number"/labels --jq '[.[].name]')

  if [[ -n "$DUPLICATE_LABEL" ]] && jq -e --arg l "$DUPLICATE_LABEL" 'any(.[]; . == $l)' <<< "$labels" >/dev/null; then
    echo "$STATE_DUPLICATE"
    return
  fi

  local IFS=',' blocking
  for blocking in $BLOCKING_LABELS; do
    if jq -e --arg l "$blocking" 'any(.[]; . == $l)' <<< "$labels" >/dev/null; then
      echo "$STATE_BLOCKED"
      return
    fi
  done
}

# Resolve a GitHub Issue/PR node ID (as sent in a projects_v2_item webhook)
# to its html_url.
# Args: CONTENT_NODE_ID
# Requires env var: GH_TOKEN
resolve_html_url() {
  local content_node_id="$1"
  gh api graphql -f query='
    query($id: ID!) {
      node(id: $id) {
        ... on Issue { url }
        ... on PullRequest { url }
      }
    }' -f id="$content_node_id" \
    --jq '.data.node.url'
}

# Resolve a GitHub issue/PR html_url to its GraphQL node ID.
# Args: HTML_URL
# Requires env var: GH_TOKEN
resolve_node_id() {
  local html_url="$1"
  local owner repo number
  owner=$(sed -E 's#https://github.com/([^/]+)/([^/]+)/(issues|pull)/([0-9]+).*#\1#' <<< "$html_url")
  repo=$(sed -E 's#https://github.com/([^/]+)/([^/]+)/(issues|pull)/([0-9]+).*#\2#' <<< "$html_url")
  number=$(sed -E 's#https://github.com/([^/]+)/([^/]+)/(issues|pull)/([0-9]+).*#\4#' <<< "$html_url")
  gh api repos/"$owner"/"$repo"/issues/"$number" --jq '.node_id'
}

# Create or remove a GitHub issue-dependency (BLOCKING_HTML_URL blocks
# BLOCKED_HTML_URL) to mirror a Linear "blocks" relation change. No-ops when
# it's already in the target state — same load-bearing feedback-loop guard
# as sync_linear_status.
# Args: BLOCKED_HTML_URL  BLOCKING_HTML_URL  ACTION(add|remove)
# Requires env var: GH_TOKEN
sync_github_blocked_by() {
  local blocked_html_url="$1" blocking_html_url="$2" action="$3"
  local blocked_node blocking_node
  blocked_node=$(resolve_node_id "$blocked_html_url")
  blocking_node=$(resolve_node_id "$blocking_html_url")
  if [[ -z "$blocked_node" || -z "$blocking_node" ]]; then
    echo "sync_github_blocked_by: could not resolve node IDs — skipping"
    return 0
  fi

  local already_blocked
  already_blocked=$(gh api graphql -f query='
    query($id: ID!) { node(id: $id) { ... on Issue { blockedBy(first: 100) { nodes { id } } } } }' \
    -f id="$blocked_node" \
    | jq -r --arg n "$blocking_node" '[.data.node.blockedBy.nodes[]?.id] | any(. == $n)')

  if [[ "$action" == "add" ]]; then
    if [[ "$already_blocked" == "true" ]]; then
      echo "sync_github_blocked_by: already blocked — skipping"
      return 0
    fi
    jq -n --arg issueId "$blocked_node" --arg blockingId "$blocking_node" '{
      query: "mutation($input: AddBlockedByInput!) { addBlockedBy(input: $input) { issue { id } } }",
      variables: { input: { issueId: $issueId, blockingIssueId: $blockingId } }
    }' | gh api graphql --input -
  else
    if [[ "$already_blocked" != "true" ]]; then
      echo "sync_github_blocked_by: not currently blocked — skipping"
      return 0
    fi
    jq -n --arg issueId "$blocked_node" --arg blockingId "$blocking_node" '{
      query: "mutation($input: RemoveBlockedByInput!) { removeBlockedBy(input: $input) { issue { id } } }",
      variables: { input: { issueId: $issueId, blockingIssueId: $blockingId } }
    }' | gh api graphql --input -
  fi
}

# Map a GitHub Projects "Status" option name to a Linear state ID.
# Args: STATUS_NAME
# Requires env vars: STATE_BACKLOG, STATE_TODO, STATE_IN_PROGRESS,
#                     STATE_BLOCKED, STATE_IN_REVIEW, STATE_DONE, STATE_CANCELED
status_name_to_state_id() {
  case "$1" in
    Backlog)       echo "$STATE_BACKLOG" ;;
    Todo)          echo "$STATE_TODO" ;;
    "In Progress") echo "$STATE_IN_PROGRESS" ;;
    Blocked)       echo "$STATE_BLOCKED" ;;
    "In Review")   echo "$STATE_IN_REVIEW" ;;
    Done)          echo "$STATE_DONE" ;;
    Canceled)      echo "$STATE_CANCELED" ;;
    *)             echo "" ;;
  esac
}
