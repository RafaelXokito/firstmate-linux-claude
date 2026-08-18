#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits exactly one merged line for a merged PR or MR and stays silent
# otherwise, including on every error, so a failed lookup can never be read as
# a merge. The provider-tagged identity is data in the sidecar and is never
# interpolated into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
# Bitbucket Server and Data Center ship no CLI, so that provider is read with
# curl against REST API 1.0. Its credential is never interpolated into these
# bytes either: it is read at run time from BITBUCKET_PAT, or from the home's
# .env, and the instance comes from the validated host rather than any
# configured base URL, so a doctored record cannot redirect the request or the
# token to another server.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
    [ "$state" = MERGED ] && printf '%s\n' merged
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  bitbucket)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    # A Bitbucket Server repository is exactly a project key and a repository
    # slug, so the path has one separator and no nesting.
    key=${path%%/*}
    slug=${path#*/}
    case "$path" in
      */*/*|/*|*/) exit 0 ;;
    esac
    [ "$key" != "$path" ] || exit 0
    case "$key" in
      '~') exit 0 ;;
      '~'*) bare=${key#'~'} ;;
      *) bare=$key ;;
    esac
    [ "${#key}" -le 128 ] || exit 0
    case "$bare" in
      ''|.|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "${#slug}" -ge 1 ] && [ "${#slug}" -le 128 ] || exit 0
    case "$slug" in
      .|..|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://$host/projects/$key/repos/$slug/pull-requests/$number" ] || exit 0
    command -v curl >/dev/null 2>&1 || exit 0
    # The token comes from the environment first, then from the home's .env, the
    # same gitignored file the relay pairing token lives in. It is read with sed
    # rather than sourced, so nothing in that file is ever executed.
    token=${BITBUCKET_PAT:-}
    if [ -z "$token" ]; then
      env_file=
      if [ -n "${FM_HOME:-}" ]; then
        env_file=$FM_HOME/.env
      else
        case "$0" in
          */state/*.check.sh) env_file=${0%/state/*}/.env ;;
        esac
      fi
      if [ -n "$env_file" ] && [ -f "$env_file" ] && [ ! -L "$env_file" ]; then
        token=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}BITBUCKET_PAT=//p' "$env_file" | head -1) || token=
        token=${token%\"}
        token=${token#\"}
        token=${token%\'}
        token=${token#\'}
      fi
    fi
    [ -n "$token" ] || exit 0
    body=$(curl -sS --max-time 20 -H "Authorization: Bearer $token" \
      -H 'Accept: application/json' \
      "https://$host/rest/api/1.0/projects/$key/repos/$slug/pull-requests/$number" 2>/dev/null) || exit 0
    # Whitespace is stripped so the test is one exact token regardless of how the
    # instance formats its JSON. Only that exact state wakes firstmate, so an
    # error page, an auth failure, or a changed field stays silent rather than
    # reporting a merge that did not happen.
    compact=$(printf '%s' "$body" | tr -d '[:space:]') || exit 0
    case "$compact" in
      *'"state":"MERGED"'*) printf '%s\n' merged ;;
    esac
    ;;
  *) exit 0 ;;
esac
exit 0
