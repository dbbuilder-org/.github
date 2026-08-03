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
  local query="$1" vars="${2:-{}}"
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
# Prints: "ISSUE_ID<TAB>STATE_NAME", or nothing if not linked.
linear_lookup() {
  local html_url="$1"
  linear_api \
    'query($url: String!) { attachmentsForURL(url: $url) { nodes { issue { id state { name } } } } }' \
    "$(jq -n --arg url "$html_url" '{url: $url}')" \
    | jq -r '.data.attachmentsForURL.nodes[0] | select(. != null) | "\(.issue.id)\t\(.issue.state.name)"'
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
# No-ops (logs + returns 0) when the item isn't linked to a Linear issue, or
# when STATE_ID is empty — most GitHub issues/PRs in a repo won't be linked.
# Args: HTML_URL  STATE_ID
sync_linear_status() {
  local html_url="$1" state_id="$2"
  if [[ -z "$state_id" ]]; then
    echo "sync_linear_status: no target state for $html_url — skipping"
    return 0
  fi

  local lookup issue_id
  lookup=$(linear_lookup "$html_url")
  issue_id=$(cut -f1 <<< "$lookup")
  if [[ -z "$issue_id" ]]; then
    echo "sync_linear_status: $html_url has no linked Linear issue — skipping"
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
