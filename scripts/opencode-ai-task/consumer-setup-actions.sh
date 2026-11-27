#!/usr/bin/env bash
# Temporarily expose the caller's reviewed local actions at their usual paths.
# The target checkout can be an older PR head without those actions.
set -euo pipefail

mode="${1:?stage or restore is required}"
workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
runner_temp="${RUNNER_TEMP:?RUNNER_TEMP is required}"
source_actions="${workspace}/.consumer-setup/.github/actions"
target_actions="${workspace}/.github/actions"
original_actions="${runner_temp}/consumer-setup-original-actions"
marker="${runner_temp}/consumer-setup-actions-staged"

case "$mode" in
  stage)
    [ -d "$source_actions" ] && [ -f "$source_actions/setup-ai-task/action.yml" ] || {
      echo "::error::The caller revision has no .github/actions/setup-ai-task/action.yml; consumer setup cannot run." >&2
      exit 1
    }
    [ ! -L "${workspace}/.github" ] || {
      echo "::error::Refusing to stage consumer actions through a symlinked .github directory." >&2
      exit 1
    }
    [ ! -e "$marker" ] && [ ! -e "$original_actions" ] || {
      echo "::error::Consumer setup actions were already staged on this runner." >&2
      exit 1
    }
    mkdir -p "${workspace}/.github"
    if [ -e "$target_actions" ] || [ -L "$target_actions" ]; then
      mv "$target_actions" "$original_actions"
    fi
    : >"$marker"
    cp -R "$source_actions" "$target_actions"
    ;;
  restore)
    if [ -f "$marker" ]; then
      [ ! -L "${workspace}/.github" ] || {
        echo "::error::Refusing to restore consumer actions through a symlinked .github directory." >&2
        exit 1
      }
      rm -rf "$target_actions"
      if [ -e "$original_actions" ] || [ -L "$original_actions" ]; then
        mv "$original_actions" "$target_actions"
      fi
      rm "$marker"
    fi
    rm -rf "${workspace}/.consumer-setup"
    ;;
  *) echo "::error::Unknown consumer setup action operation: ${mode}" >&2; exit 1 ;;
esac
