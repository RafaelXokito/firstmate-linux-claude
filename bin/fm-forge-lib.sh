# shellcheck shell=bash
# Which forges does THIS home actually work with?
# Usage: . bin/fm-forge-lib.sh
#
# Firstmate required gh and gh-axi of every home unconditionally, and probed
# `gh auth status` on every session start. That is wrong for a home whose
# projects live on GitLab or Bitbucket: it reports a missing tool and an
# unauthenticated GitHub for work that never touches GitHub, and the auth
# diagnostic blocks dispatch on a machine that has no GitHub login at all.
#
# This library answers the narrower question the gate should have asked: which
# providers do this home's registered project origins resolve to? A home with no
# GitHub project needs no gh, and a home with one still does.
#
# CLASSIFICATION IS PER HOST, and it is deliberately conservative. Nothing here
# is a security boundary - bin/fm-project-origin-lib.sh owns clone-URL safety and
# must never gain a forge allowlist. This file only decides which CLI a home
# needs and which auth probe is worth running.
#
# Resolution order for a host:
#   1. config/forge-map, an operator-owned "<host> <provider>" table. This is the
#      authority, because a self-hosted instance is free to be named anything:
#      GitHub Enterprise at git.corp.example says nothing about GitHub in its
#      name, and a hostname heuristic would silently drop its gh requirement.
#   2. a hostname heuristic for the three names that are self-evident.
#   3. "unknown" - reported, never silently treated as "no forge". Fail loud:
#      guessing "no provider" for an unmapped host is exactly the fail-open that
#      would drop a real gate.
# Providers: github, gitlab, bitbucket (Server/Data Center and Cloud), unknown.
# A local or file: origin, or no origin at all, is "none": a local-only project
# needs no forge CLI.

# Echo the host of an origin URL, or nothing for a local/file origin. Mirrors the
# forms bin/fm-project-origin-lib.sh accepts, minus the safety judgement.
fm_forge_origin_host() { # <origin-url>
  local url=${1-} rest authority host
  case $url in
    ''|/*|file://*) return 0 ;;
    https://*|http://*|ssh://*|git://*)
      rest=${url#*://}
      authority=${rest%%/*}
      ;;
    *://*) return 0 ;;
    *)
      # scp-like [user@]host:path
      rest=$url
      case $url in
        *@*)
          case ${url%%@*} in
            *:*) ;;
            *) rest=${url#*@} ;;
          esac
          ;;
      esac
      case $rest in
        *:*) authority=${rest%%:*} ;;
        *) return 0 ;;
      esac
      ;;
  esac
  case $authority in
    *@*) authority=${authority##*@} ;;
  esac
  case $authority in
    '['*) host=${authority%%']'*}']' ;;
    *) host=${authority%%:*} ;;
  esac
  printf '%s\n' "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
}

# Echo the provider for <host>, consulting <config-dir>/forge-map first.
fm_forge_for_host() { # <host> <config-dir>
  local host=${1-} config=${2-} map mapped_host mapped_provider
  [ -n "$host" ] || { printf 'none\n'; return 0; }
  map="$config/forge-map"
  if [ -n "$config" ] && [ -f "$map" ]; then
    while read -r mapped_host mapped_provider _; do
      case $mapped_host in ''|'#'*) continue ;; esac
      [ "$(printf '%s' "$mapped_host" | tr '[:upper:]' '[:lower:]')" = "$host" ] || continue
      case $mapped_provider in
        github|gitlab|bitbucket|none) printf '%s\n' "$mapped_provider"; return 0 ;;
        *) break ;;
      esac
    done < "$map"
  fi
  case $host in
    *github*) printf 'github\n' ;;
    *gitlab*) printf 'gitlab\n' ;;
    *bitbucket*) printf 'bitbucket\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# Echo the provider a project checkout's origin resolves to.
fm_forge_of_project() { # <project-dir> <config-dir>
  local dir=${1-} config=${2-} url host
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || { printf 'none\n'; return 0; }
  host=$(fm_forge_origin_host "$url")
  fm_forge_for_host "$host" "$config"
}

# Echo each distinct provider this home's projects use, one per line, sorted.
# A projects dir that does not exist yields nothing, so a home with no projects
# yet requires no forge CLI and is told nothing about one.
fm_forge_providers_in_use() { # <projects-dir> <config-dir>
  local projects=${1-} config=${2-} entry
  [ -n "$projects" ] && [ -d "$projects" ] || return 0
  for entry in "$projects"/*; do
    [ -d "$entry" ] || continue
    git -C "$entry" rev-parse --git-dir >/dev/null 2>&1 || continue
    fm_forge_of_project "$entry" "$config"
  done | sort -u
}

# Echo the CLI tools a provider's delivery path needs, or nothing.
# github    gh for the merge watch, gh-axi for pushing and opening a PR
# gitlab    glab for the merge watch
# bitbucket curl for the REST merge watch and merge; Bitbucket ships no CLI
fm_forge_required_tools() { # <provider>
  case ${1-} in
    github) printf 'gh gh-axi\n' ;;
    gitlab) printf 'glab\n' ;;
    bitbucket) printf 'curl\n' ;;
    *) : ;;
  esac
}
