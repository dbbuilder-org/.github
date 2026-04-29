#!/usr/bin/env bash
# Shared PR helper functions for pr-status-sync workflows.
# Source this file; do not execute it directly.

# Derive the canonical Simple Name for an org member.
# Args: LOGIN  NAME (name may be empty string)
#   Has a name  → first word of name          ("John Smith"   → "John")
#   No name     → login stripped at first "-"  ("Joe-Tester"  → "Joe")
#               → if result has lowercase, truncate at first uppercase
#                 after the first lowercase    ("fredV2"       → "fred")
#               → first char uppercased        ("jake"         → "Jake")
compute_simple_name() {
  local LOGIN="$1" NAME="$2" LABEL_NAME FOUND_LOWER RESULT CHAR i
  if [[ -n "$NAME" ]]; then
    LABEL_NAME="${NAME%% *}"
  else
    LABEL_NAME="${LOGIN%%-*}"
    if [[ "$LABEL_NAME" =~ [a-z] ]]; then
      FOUND_LOWER=false; RESULT=""
      for (( i=0; i<${#LABEL_NAME}; i++ )); do
        CHAR="${LABEL_NAME:$i:1}"
        if [[ "$FOUND_LOWER" == false ]]; then
          [[ "$CHAR" =~ [a-z] ]] && FOUND_LOWER=true
          RESULT+="$CHAR"
        else
          [[ "$CHAR" =~ [A-Z] ]] && break
          RESULT+="$CHAR"
        fi
      done
      LABEL_NAME="$RESULT"
    fi
  fi
  echo "${LABEL_NAME^}"
}

# Fetch all org members and build bidirectional maps:
#   LOGIN_TO_LABEL["login"]  → Simple Name
#   LABEL_TO_LOGIN["name"]   → "login"  (lowercase simple name as key)
# Requires env var: ORG
build_member_maps() {
  declare -g -A LOGIN_TO_LABEL LABEL_TO_LOGIN
  local org_data m_login m_name m_simple
  org_data=$(gh api graphql \
    -F org="$ORG" \
    -f query='query($org: String!) {
      organization(login: $org) {
        membersWithRole(first: 100) {
          nodes { login name }
        } } }' \
    --jq '.data.organization.membersWithRole.nodes[] | "\(.login)\t\(.name // "")"')
  while IFS=$'\t' read -r m_login m_name; do
    [[ -z "$m_login" ]] && continue
    m_simple=$(compute_simple_name "$m_login" "$m_name")
    LOGIN_TO_LABEL["$m_login"]="$m_simple"
    LABEL_TO_LOGIN["${m_simple,,}"]="$m_login"
  done <<< "$org_data"
}

# Add PR to project (idempotent) and return the project item ID.
# Args: PR_NODE_ID
# Requires env var: PROJECT_ID
get_item_id() {
  local pr_node_id="$1"
  gh api graphql -f query='
    mutation($proj: ID!, $pr: ID!) {
      addProjectV2ItemById(input: { projectId: $proj, contentId: $pr }) {
        item { id }
      }
    }' \
    -f proj="$PROJECT_ID" -f pr="$pr_node_id" \
    --jq '.data.addProjectV2ItemById.item.id'
}

# Assign the current sprint iteration to a project item, if not already set.
# Discovers ITERATION_FIELD_ID from the project when not set externally.
# Args: ITEM_ID
# Requires env var: PROJECT_ID
assign_iteration() {
  local item_id="$1"

  local existing
  existing=$(gh api graphql -f query='
    query($item: ID!) {
      node(id: $item) {
        ... on ProjectV2Item {
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldIterationValue { iterationId }
            }
          }
        }
      }
    }' \
    -f item="$item_id" \
    --jq '.data.node.fieldValues.nodes[] | select(.iterationId != null) | .iterationId' \
    | head -1)
  [[ -n "$existing" ]] && return 0

  local today raw field_id current_iter
  today=$(date -u +%s)
  raw=$(gh api graphql -f query='
    query($proj: ID!) {
      node(id: $proj) {
        ... on ProjectV2 {
          fields(first: 20) {
            nodes {
              ... on ProjectV2IterationField {
                id
                configuration {
                  iterations { id startDate duration }
                }
              }
            }
          }
        }
      }
    }' \
    -f proj="$PROJECT_ID" \
    --jq "
      ([.data.node.fields.nodes[] | select(.configuration != null)] | .[0]) as \$f |
      if \$f != null then {
        field_id: \$f.id,
        iter_id: (
          [\$f.configuration.iterations[] |
           {id, start: (.startDate | strptime(\"%Y-%m-%d\") | mktime),
            end:  ((.startDate | strptime(\"%Y-%m-%d\") | mktime) + (.duration * 86400))}] as \$iters |
          (
            (\$iters | map(select(.start <= $today and .end > $today)) | .[0])
            // (\$iters | map(select(.start > $today)) | sort_by(.start) | .[0])
          ) | .id // empty
        )
      } else {field_id: null, iter_id: null} end")
  field_id=$(echo "$raw" | jq -r '.field_id // empty')
  current_iter=$(echo "$raw" | jq -r '.iter_id // empty')
  [[ -z "$field_id" || -z "$current_iter" ]] && return 0

  [[ -z "$ITERATION_FIELD_ID" ]] && ITERATION_FIELD_ID="$field_id"

  gh api graphql -f query='
    mutation($proj: ID!, $item: ID!, $field: ID!, $iter: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $proj, itemId: $item,
        fieldId: $field, value: { iterationId: $iter }
      }) { projectV2Item { id } }
    }' \
    -f proj="$PROJECT_ID" -f item="$item_id" \
    -f field="$field_id" -f iter="$current_iter"
}

# Determine the correct PR status and update the project board.
# Args: PR_NODE_ID  PR_NUMBER  REPO
# Requires env vars: GH_TOKEN, PROJECT_ID, PR_STATUS_FIELD_ID,
#                    OPT_MERGED, OPT_CLOSED, OPT_BLOCKED, OPT_ON_HOLD, OPT_IN_QUEUE, OPT_UNASSIGNED
set_pr_status() {
  local pr_node_id="$1" pr_number="$2" repo="$3"
  local item_id pr_data merged closed reviewer_count labels on_hold needs_changes opt

  item_id=$(get_item_id "$pr_node_id")
  if [[ -z "$item_id" ]]; then
    echo "set_pr_status: failed to get item ID for PR #$pr_number" >&2
    return 1
  fi

  pr_data=$(gh api repos/"$repo"/pulls/"$pr_number" \
    --jq '{merged: .merged, state: .state, reviewer_count: (.requested_reviewers | length)}')
  merged=$(echo "$pr_data" | jq -r '.merged')
  closed=$(echo "$pr_data" | jq -r '.state == "closed"')
  reviewer_count=$(echo "$pr_data" | jq -r '.reviewer_count')
  labels=$(gh api repos/"$repo"/issues/"$pr_number"/labels --jq '[.[].name]')
  on_hold=$(echo "$labels"        | jq 'any(.[]; . == ".hold")')
  needs_changes=$(echo "$labels"  | jq 'any(.[]; . == ".needs-changes" or . == ".needs-decision" or . == ".question")')
  has_reviewer_label=$(echo "$labels" | jq 'any(.[]; startswith("reviewer:"))')

  if   [[ "$merged"         == "true" ]]; then opt="$OPT_MERGED"
  elif [[ "$closed"         == "true" ]]; then opt="$OPT_CLOSED"
  elif [[ "$on_hold" == "true" && -n "$OPT_ON_HOLD" ]]; then opt="$OPT_ON_HOLD"
  elif [[ "$needs_changes"  == "true" ]]; then opt="$OPT_BLOCKED"
  elif [[ "$reviewer_count" -gt 0 || "$has_reviewer_label" == "true" ]]; then opt="$OPT_IN_QUEUE"
  else                                          opt="$OPT_UNASSIGNED"
  fi

  gh api graphql -f query='
    mutation($proj: ID!, $item: ID!, $field: ID!, $opt: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $proj, itemId: $item,
        fieldId: $field, value: { singleSelectOptionId: $opt }
      }) { projectV2Item { id } }
    }' \
    -f proj="$PROJECT_ID" -f item="$item_id" \
    -f field="$PR_STATUS_FIELD_ID" -f opt="$opt"
}
