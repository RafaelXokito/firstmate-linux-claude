#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical PR URL is parsed by bin/fm-pr-lib.sh and the derived
# identity is passed to the provider's own merge path.
#
# GITHUB is merged through gh-axi by owner/repository and PR number.
#
# BITBUCKET Server and Data Center ship no CLI, so it is merged with curl against
# REST API 1.0. That API requires the pull request's current version, which is
# read immediately before the merge: the version is Bitbucket's optimistic-lock
# token, so a stale one makes the instance refuse the merge rather than merge a
# pull request that changed under us. Extra args are refused for this provider,
# because there is no argument surface to forward them to.
#
# GITLAB is still refused rather than merged; teaching the merge path GitLab is a
# separate change, and refusing beats sending a merge to the wrong forge.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path has no GitLab merge, so that provider is still refused here
# rather than sent to the wrong forge.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
case "$FM_PR_PROVIDER" in
  github|bitbucket) ;;
  *)
    echo "error: invalid PR merge request" >&2
    exit 2
    ;;
esac
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
PR_HOST=$FM_PR_HOST
PR_PATH=$FM_PR_PATH
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

if [ "$PROVIDER" = bitbucket ]; then
  if [ "$#" -gt 0 ]; then
    echo "error: a Bitbucket merge takes no extra merge arguments" >&2
    exit 2
  fi
  command -v curl >/dev/null 2>&1 || {
    echo "error: merging a Bitbucket pull request requires curl on PATH" >&2
    exit 1
  }
  BB_TOKEN=$(fm_pr_bitbucket_token "$FM_HOME") || {
    echo "error: merging a Bitbucket pull request requires a Personal Access Token in BITBUCKET_PAT or $FM_HOME/.env" >&2
    exit 1
  }
  BB_KEY=${PR_PATH%%/*}
  BB_SLUG=${PR_PATH#*/}
  BB_API="https://$PR_HOST/rest/api/1.0/projects/$BB_KEY/repos/$BB_SLUG/pull-requests/$PR_NUMBER"

  # The version is read immediately before the merge and passed straight back.
  # It is Bitbucket's optimistic-lock token: if the pull request changed since
  # this read, the instance refuses the merge instead of merging something else.
  # It is the FIRST "version" in the response because Bitbucket serialises the
  # pull request's own fields ahead of every nested object.
  BB_PR=$(curl -sS --max-time 30 -H "Authorization: Bearer $BB_TOKEN" \
    -H 'Accept: application/json' "$BB_API" 2>/dev/null) || {
    echo "error: could not read the Bitbucket pull request before merging" >&2
    exit 1
  }
  BB_COMPACT=$(printf '%s' "$BB_PR" | tr -d '[:space:]')
  case "$BB_COMPACT" in
    *'"state":"MERGED"'*)
      echo "error: that Bitbucket pull request is already merged" >&2
      exit 1
      ;;
    *'"state":"DECLINED"'*)
      echo "error: that Bitbucket pull request is declined and cannot be merged" >&2
      exit 1
      ;;
  esac
  BB_VERSION=$(printf '%s' "$BB_COMPACT" | sed -n 's/.*"version":\([0-9]\{1,\}\).*/\1/p' | head -1)
  case "$BB_VERSION" in
    ''|*[!0-9]*)
      echo "error: could not read the Bitbucket pull request version; refusing to merge without it" >&2
      exit 1
      ;;
  esac
  BB_RESULT=$(curl -sS --max-time 60 -X POST \
    -H "Authorization: Bearer $BB_TOKEN" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -H 'X-Atlassian-Token: no-check' \
    "$BB_API/merge?version=$BB_VERSION" 2>/dev/null) || {
    echo "error: the Bitbucket merge request failed" >&2
    exit 1
  }
  case "$(printf '%s' "$BB_RESULT" | tr -d '[:space:]')" in
    *'"state":"MERGED"'*)
      printf 'merged %s\n' "$URL"
      exit 0
      ;;
  esac
  echo "error: the Bitbucket merge did not report a merged pull request; nothing is assumed merged" >&2
  exit 1
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
