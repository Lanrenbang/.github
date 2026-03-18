#!/usr/bin/env bash
# update_go_deps.sh - Updates Go module dependencies based on checker results
# Part of the upstream-checker composite action.
# Called by the reusable workflow before PR creation.
set -euo pipefail

# Inputs via env: RESULTS, GO_MOD_DEPS

if [[ -z "${GO_MOD_DEPS:-}" || "$GO_MOD_DEPS" == "[]" ]]; then
  echo "ℹ️  No go_mod_deps configured, skipping"
  exit 0
fi

if [[ ! -f "go.mod" ]]; then
  echo "ℹ️  No go.mod found, skipping"
  exit 0
fi

echo "🔧 Checking Go module dependencies for updates..."

updated_any=false

while read -r dep_entry; do
  dep_repo=$(echo "$dep_entry" | jq -r '.repo')
  dep_module=$(echo "$dep_entry" | jq -r '.module')

  # Check if this repo was updated
  tag=$(echo "$RESULTS" | jq -r --arg r "$dep_repo" '.[] | select(.repo == $r and .is_updated == true) | .tag')
  sha=$(echo "$RESULTS" | jq -r --arg r "$dep_repo" '.[] | select(.repo == $r and .is_updated == true) | .sha')

  if [[ -z "$tag" || "$tag" == "null" ]]; then
    continue
  fi

  if [[ "$tag" != "-" ]]; then
    echo "   📦 $dep_module: updating to $tag"
    go get "${dep_module}@${tag}" || {
      echo "   ⚠️ Failed to update $dep_module to $tag, trying @latest"
      go get "${dep_module}@latest" || echo "   ❌ Failed to update $dep_module"
    }
    updated_any=true
  else
    echo "   📦 $dep_module: updating to commit ${sha:0:12}"
    go get "${dep_module}@${sha}" || echo "   ❌ Failed to update $dep_module to $sha"
    updated_any=true
  fi
done < <(echo "$GO_MOD_DEPS" | jq -c '.[]')

if $updated_any; then
  echo ""
  echo "🔄 Running go mod tidy..."
  go mod tidy
  echo "✅ Go dependencies updated"
else
  echo "ℹ️  No Go dependency updates needed"
fi
