#!/usr/bin/env bash
# check_repos.sh - Core logic for checking upstream repository versions
# Part of the upstream-checker composite action.
set -euo pipefail

#═══════════════════════════════════════════════════════════════
# Helper Functions
#═══════════════════════════════════════════════════════════════

api_get() {
  local url="$1"
  local args=(-s -L -H "Accept: application/vnd.github.v3+json")
  [[ -n "${TOKEN:-}" ]] && args+=(-H "Authorization: Bearer $TOKEN")
  curl "${args[@]}" "$url"
}

get_release_tag() {
  api_get "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name // empty'
}

get_prerelease_tag() {
  api_get "https://api.github.com/repos/$1/releases?per_page=1" | jq -r '.[0].tag_name // empty'
}

get_latest_commit() {
  api_get "https://api.github.com/repos/$1/commits?per_page=1" | jq -r '.[0].sha // empty'
}

resolve_tag_to_sha() {
  local repo="$1" tag="$2"
  local ref_data sha obj_type

  ref_data=$(api_get "https://api.github.com/repos/$repo/git/refs/tags/$tag")
  sha=$(echo "$ref_data" | jq -r '.object.sha // empty')
  obj_type=$(echo "$ref_data" | jq -r '.object.type // empty')

  # Dereference annotated tag
  if [[ "$obj_type" == "tag" ]]; then
    sha=$(api_get "https://api.github.com/repos/$repo/git/tags/$sha" | jq -r '.object.sha // empty')
  fi
  echo "$sha"
}

# Fetch content hash for issue or discussion body
get_issue_hash() {
  local repo="$1" number="$2"
  api_get "https://api.github.com/repos/$repo/issues/$number" \
    | jq -r '(.updated_at // "") + "|" + (.body | length | tostring)' \
    | sha256sum | cut -d' ' -f1
}

get_discussion_hash() {
  local repo="$1" number="$2"
  local owner="${repo%%/*}"
  local name="${repo##*/}"
  local query
  query=$(cat <<-GRAPHQL
    query {
      repository(owner: "$owner", name: "$name") {
        discussion(number: $number) {
          updatedAt
          bodyText
        }
      }
    }
GRAPHQL
  )
  local result
  result=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$query" '{query: $q}')" \
    https://api.github.com/graphql)
  echo "$result" | jq -r '.data.repository.discussion | (.updatedAt // "") + "|" + (.bodyText | length | tostring)' \
    | sha256sum | cut -d' ' -f1
}

#═══════════════════════════════════════════════════════════════
# Input Validation
#═══════════════════════════════════════════════════════════════

if ! echo "$REPOSITORIES" | jq empty 2>/dev/null; then
  echo "::error::Invalid JSON in repositories input"
  exit 1
fi

#═══════════════════════════════════════════════════════════════
# Load Current State
#═══════════════════════════════════════════════════════════════

declare -A current_state  # Format: current_state[key]="sha|tag|check_type"
state_file_existed=false
is_init=false

if [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]]; then
  state_file_existed=true
  echo "📖 Loading state from: $STATE_FILE"
  while IFS=' ' read -r key sha tag check_type; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    current_state["$key"]="${sha}|${tag:--}|${check_type:-auto}"
  done < "$STATE_FILE"
elif [[ -n "$STATE_FILE" ]]; then
  is_init=true
  echo "📝 State file not found, will initialize: $STATE_FILE"
else
  echo "ℹ️  Query-only mode (no state_file specified)"
fi

#═══════════════════════════════════════════════════════════════
# Check Each Repository
#═══════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════"
echo "🔍 Checking upstream repositories"
echo "════════════════════════════════════════"

declare -A new_state
results_json="[]"
has_updates=false
update_summary=""
init_summary=""

while read -r entry; do
  repo=$(echo "$entry" | jq -r '.repo // empty')
  check_type=$(echo "$entry" | jq -r '.check_type // "auto"')
  number=$(echo "$entry" | jq -r '.number // empty')

  [[ -z "$repo" ]] && continue

  # Build a state key: for issue/discussion include the number
  state_key="$repo"
  if [[ "$check_type" == "issue" || "$check_type" == "discussion" ]]; then
    [[ -z "$number" ]] && { echo "   ⚠️ $repo: 'number' is required for check_type=$check_type"; continue; }
    state_key="${repo}#${check_type}${number}"
  fi

  echo ""
  echo "📦 $repo (mode: $check_type${number:+ #$number})"

  tag="" sha="" actual_type=""

  # Determine version based on check_type
  case "$check_type" in
    release)
      tag=$(get_release_tag "$repo")
      [[ -z "$tag" ]] && { echo "   ⚠️ No stable release found"; continue; }
      actual_type="release"
      ;;
    prerelease)
      tag=$(get_prerelease_tag "$repo")
      [[ -z "$tag" ]] && { echo "   ⚠️ No releases found"; continue; }
      actual_type="prerelease"
      ;;
    commit)
      sha=$(get_latest_commit "$repo")
      [[ -z "$sha" ]] && { echo "   ⚠️ Could not fetch commits"; continue; }
      tag="-"
      actual_type="commit"
      ;;
    issue)
      sha=$(get_issue_hash "$repo" "$number")
      [[ -z "$sha" ]] && { echo "   ⚠️ Could not fetch issue #$number"; continue; }
      tag="issue#$number"
      actual_type="issue"
      ;;
    discussion)
      sha=$(get_discussion_hash "$repo" "$number")
      [[ -z "$sha" ]] && { echo "   ⚠️ Could not fetch discussion #$number"; continue; }
      tag="discussion#$number"
      actual_type="discussion"
      ;;
    auto)
      if tag=$(get_release_tag "$repo") && [[ -n "$tag" ]]; then
        actual_type="release"
      elif tag=$(get_prerelease_tag "$repo") && [[ -n "$tag" ]]; then
        actual_type="prerelease"
      elif sha=$(get_latest_commit "$repo") && [[ -n "$sha" ]]; then
        tag="-"
        actual_type="commit"
      else
        echo "   ⚠️ Could not fetch any version"
        continue
      fi
      ;;
    *)
      echo "   ⚠️ Invalid check_type: $check_type"
      continue
      ;;
  esac

  # Resolve tag to SHA if needed (only for release/prerelease types)
  if [[ "$actual_type" == "release" || "$actual_type" == "prerelease" ]] && [[ -n "$tag" ]]; then
    sha=$(resolve_tag_to_sha "$repo" "$tag")
    [[ -z "$sha" ]] && { echo "   ⚠️ Could not resolve tag to SHA"; continue; }
  fi

  echo "   ✓ ${tag:--} (${sha:0:12}) [$actual_type]"

  # Store new state
  new_state["$state_key"]="${sha}|${tag}|${actual_type}"

  # Check for updates (only if state_file existed)
  is_updated=false
  if [[ -n "${current_state[$state_key]:-}" ]]; then
    IFS='|' read -r old_sha old_tag old_type <<< "${current_state[$state_key]}"
    if [[ "$sha" != "$old_sha" ]]; then
      is_updated=true
      if $state_file_existed; then
        has_updates=true
        if [[ "$tag" != "-" && "$old_tag" != "-" ]]; then
          update_summary+="- **$repo**: \`$old_tag\` → \`$tag\`\n"
        else
          update_summary+="- **$repo**: \`${old_sha:0:7}\` → \`${sha:0:7}\`\n"
        fi
        echo "   ✅ UPDATE DETECTED"
      fi
    fi
  elif $state_file_existed; then
    is_updated=true
    has_updates=true
    update_summary+="- **$repo**: Added at \`${tag:--}\` [$actual_type]\n"
    echo "   ℹ️ New entry added"
  elif $is_init; then
    init_summary+="- **$repo**: \`${tag:--}\` [$actual_type]\n"
  fi

  # Build results JSON
  results_json=$(echo "$results_json" | jq \
    --arg repo "$repo" \
    --arg sha "$sha" \
    --arg tag "$tag" \
    --arg type "$actual_type" \
    --argjson updated "$is_updated" \
    --arg number "${number:-}" \
    '. + [{repo: $repo, sha: $sha, tag: $tag, check_type: $type, is_updated: $updated, number: $number}]')

done < <(echo "$REPOSITORIES" | jq -c '.[]')

#═══════════════════════════════════════════════════════════════
# Write State File (if specified)
#═══════════════════════════════════════════════════════════════

if [[ -n "$STATE_FILE" && ${#new_state[@]} -gt 0 ]]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  {
    echo "# Upstream dependency versions"
    echo "# Format: key sha tag check_type"
    echo "# Updated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo ""
    for key in $(printf '%s\n' "${!new_state[@]}" | sort); do
      IFS='|' read -r sha tag type <<< "${new_state[$key]}"
      echo "$key $sha $tag $type"
    done
  } > "$STATE_FILE"
  echo ""
  echo "📝 State written to: $STATE_FILE"
fi

#═══════════════════════════════════════════════════════════════
# Output Summary
#═══════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════"
echo "📊 Summary"
echo "════════════════════════════════════════"
echo "$results_json" | jq -r '.[] | "  \(.repo): \(.tag) [\(.check_type)]\(if .is_updated then " ✅" else "" end)"'
echo ""
echo "has_updates: $has_updates"
$is_init && echo "is_init: true (first run)"

# Set outputs
{
  echo "results<<EOF"
  echo "$results_json"
  echo "EOF"
  echo "has_updates=$has_updates"
  echo "is_init=$is_init"
  echo "update_summary<<EOF"
  echo -e "$update_summary"
  echo "EOF"
  echo "init_summary<<EOF"
  echo -e "$init_summary"
  echo "EOF"
} >> "$GITHUB_OUTPUT"
