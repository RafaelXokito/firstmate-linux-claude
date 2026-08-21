#!/usr/bin/env bash
# Create and converge a PER-PROJECT firstmate home: <project>/.firstmate.
#
# This is the inverted layout. The classic layout puts project clones inside one
# firstmate home ($FM_HOME/projects/<name>); this one puts a firstmate home
# inside each project checkout, so the captain opens a project directory and the
# fleet that serves it is already there. One shared tracked clone (FM_ROOT)
# supplies bin/, AGENTS.md, and the skills to every such home; only the private
# operational directories are per project.
#
# Both layouts use the SAME scripts and the SAME state contracts. Nothing here
# adds a second architecture: a per-project home is an ordinary FM_HOME whose
# projects/ dir holds exactly one entry, a symlink back to the enclosing
# checkout. docs/configuration.md owns the layout and schemas; this header owns
# the created child paths and the convergence mechanics.
#
# Created under <project>/.firstmate:
#   .fm-project-home  marker: "project=<abs>", "root=<abs>", "name=<name>"; the
#                     one file that identifies a per-project home, and the anchor
#                     bin/fm-launch.sh searches upward for
#   AGENTS.md         GENERATED copy of $FM_ROOT/AGENTS.md, refreshed on every
#                     converge. It is a real file and NOT a symlink on purpose:
#                     CLAUDE.md reaches it through a memory import, and an import
#                     whose target resolves OUTSIDE the harness project directory
#                     is silently skipped - the contract never loads, no
#                     diagnostic is printed, and the session behaves like an
#                     ordinary one that merely ran firstmate's startup digest.
#                     Keeping the target inside the home removes that failure
#                     mode entirely; convergence is what keeps the copy honest.
#   CLAUDE.md         "@AGENTS.md" pointer, so a harness whose cwd is this home
#                     loads the shared contract, and still inherits the
#                     project's own CLAUDE.md from the parent directory
#   <host config>     one entry per supported primary harness, each pointed at
#                     the shared clone. The harness project dir here is the HOME,
#                     so a config left as tracked resolves bin/ inside the home,
#                     where there is none - and every one of these hosts then
#                     fails SILENTLY. Two mechanisms, by what the host offers:
#                       SUBSTITUTED, for a declarative config naming its root
#                       through a placeholder or a cwd expression - copied with
#                       that root rewritten to the absolute FM_ROOT:
#                         .claude/settings.json   $CLAUDE_PROJECT_DIR
#                         .cursor/hooks.json      $CURSOR_PROJECT_DIR
#                         .codex/hooks.json       root=$(pwd -P)
#                         .grok/hooks/*.json      ${GROK_WORKSPACE_ROOT:-}
#                       LINKED, for a plugin or extension that resolves its root
#                       in executed code and reads FM_ROOT_OVERRIDE, which
#                       bin/fm-launch.sh exports - the shared directory is
#                       symlinked and the root comes from the runtime:
#                         .opencode/plugins       .pi/extensions
#                     A host the clone does not ship is simply not converged.
#   .claude/skills    symlink to $FM_ROOT/.agents/skills
#   data/ state/ config/   this home's private operational directories
#   projects/<name>   symlink to the enclosing project checkout
#
# Deliberately NOT created: a bin/ symlink. A script invoked through such a
# symlink resolves FM_ROOT to this home instead of the shared clone, which would
# aim the worktree-tangle guard at the project's own branch and alarm on every
# feature branch. Callers reach bin/ through FM_ROOT, and bin/fm-launch.sh
# exports FM_ROOT_OVERRIDE so every child process agrees on the code root.
#
# The project checkout itself is never modified. .firstmate/ is hidden from the
# project's git through .git/info/exclude, which is local and untracked, so
# nothing lands in the captain's repository and no tracked .gitignore is edited.
#
# init is idempotent and convergent: it refreshes the generated contract copy and
# every harness host config, repairs a drifted symlink, restores a missing exclude entry, and
# rewrites the marker's root= when the shared clone moved. bin/fm-launch.sh runs
# it on every start, so a shared-clone update reaches every home without a
# separate step. It never removes data/, state/, or config/.
#
# Usage: fm-project-home.sh init [<project-dir>] [--name <name>] [--mode <mode>] [--yolo on|off]
#        fm-project-home.sh path [<start-dir>]     print the enclosing home, or exit 1
#        fm-project-home.sh status [<start-dir>]   print resolved home, root, project, posture
# <project-dir> defaults to the caller's working directory and must be the top
# level of a git checkout that is not a linked worktree. --name defaults to the
# checkout's directory name. --mode and --yolo seed data/projects.md only when
# the registry has no entry for this project yet; bin/fm-project-mode.sh owns the
# registry format and the posture fallback.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

HOME_DIR_NAME=.firstmate
MARKER_NAME=.fm-project-home

usage() {
  sed -n '/^# Usage:/,/^# registry format/p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "error: $*" >&2; exit 1; }

# Echo the absolute top level of the git checkout at <dir>, refusing a linked
# worktree: a per-project home belongs to the primary checkout, and one created
# inside a disposable task worktree would vanish with it.
project_top_level() {
  local dir=$1 top git_dir common_dir
  [ -d "$dir" ] || { echo "error: no such directory: $dir" >&2; return 1; }
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || {
    echo "error: not a git checkout: $dir" >&2
    return 1
  }
  git_dir=$(git -C "$dir" rev-parse --absolute-git-dir) || return 1
  common_dir=$(cd "$dir" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || return 1
  if [ "$git_dir" != "$common_dir" ]; then
    echo "error: $top is a linked worktree; create the home in the primary checkout instead" >&2
    return 1
  fi
  (cd "$top" && pwd -P)
}

# Walk up from <dir> and echo the first directory holding a valid per-project
# home marker. Returns 1 when there is none, so a caller can fall back to the
# classic whole-repo layout rather than guessing one.
find_home_upward() {
  local dir=$1 marker
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  while :; do
    marker="$dir/$HOME_DIR_NAME/$MARKER_NAME"
    if [ -f "$marker" ] && ! [ -L "$marker" ] && grep -q '^project=' "$marker" 2>/dev/null; then
      printf '%s\n' "$dir/$HOME_DIR_NAME"
      return 0
    fi
    [ "$dir" != / ] || return 1
    dir=$(dirname "$dir")
  done
}

marker_field() { # <marker> <key>
  local marker=$1 key=$2 line
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s\n' "${line#"$key="}"; return 0 ;;
    esac
  done < "$marker"
  return 1
}

# Point <link> at <target>, replacing a wrong or non-symlink entry. A real
# directory at that path is never removed: it may hold the captain's data.
converge_symlink() { # <link> <target>
  local link=$1 target=$2 current
  if [ -L "$link" ]; then
    current=$(readlink "$link")
    [ "$current" = "$target" ] || ln -sfn "$target" "$link"
    return 0
  fi
  if [ -e "$link" ]; then
    echo "error: $link exists and is not a symlink; move it aside and rerun" >&2
    return 1
  fi
  ln -s "$target" "$link"
}

# Write stdin to <dest> only when the content differs, so an unchanged converge
# run does not churn mtimes that other guards read. A pre-existing symlink at
# <dest> is replaced, which is how a home created before the generated-contract
# fix converges forward.
write_if_changed() { # <dest> <<content
  local dest=$1 tmp
  [ -L "$dest" ] && rm -f "$dest"
  tmp=$(mktemp "$dest.XXXXXX") || return 1
  cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$dest"
}

# Replace every LITERAL occurrence of <find> with <repl> on stdin. Literal and
# not regex on purpose: the root expressions being rewritten contain $, (, ), {,
# } and :-, and the replacement is a filesystem path that may carry regex or sed
# delimiter characters of its own. ENVIRON avoids awk -v's escape processing.
substitute_literal() { # <find> <repl>
  FM_FIND=$1 FM_REPL=$2 awk '
    BEGIN { find = ENVIRON["FM_FIND"]; repl = ENVIRON["FM_REPL"]; n = length(find) }
    {
      out = ""
      while ((i = index($0, find)) > 0) {
        out = out substr($0, 1, i - 1) repl
        $0 = substr($0, i + n)
      }
      print out $0
    }
  '
}

# Generate <dest> from <src> with the host's own root expression rewritten to the
# shared clone. A missing <src> is not an error: a clone that does not ship that
# host's config has nothing to converge.
generate_host_config() { # <src> <dest> <find> <repl>
  local src=$1 dest=$2 find=$3 repl=$4
  [ -f "$src" ] || return 0
  mkdir -p "$(dirname "$dest")"
  substitute_literal "$find" "$repl" < "$src" | write_if_changed "$dest"
}

# Point every supported primary harness's host config at the shared clone. See
# this script's header for the two mechanisms and the full per-host table.
#
# Why every host and not just the one in use: each of these fails SILENTLY when
# its config resolves bin/ inside the home. The codex and grok entries guard
# themselves and exit 0, and the opencode plugin swallows its spawn error, so a
# home converged for one harness only would hand any other harness a session
# with no supervision and no diagnostic at all.
# The find arguments below are the hosts' OWN literal root expressions, quoted so
# this shell does not expand what the host is meant to see.
# shellcheck disable=SC2016
converge_host_configs() { # <home> <root-abs>
  local home=$1 root=$2 f
  generate_host_config "$root/.claude/settings.json" "$home/.claude/settings.json" \
    '$CLAUDE_PROJECT_DIR' "$root"
  generate_host_config "$root/.cursor/hooks.json" "$home/.cursor/hooks.json" \
    '$CURSOR_PROJECT_DIR' "$root"
  # codex takes its root from the harness cwd and then self-checks that the same
  # directory holds bin/, AGENTS.md, and .codex/hooks.json. Rewriting only the
  # assignment leaves those checks intact, now aimed at the shared clone.
  generate_host_config "$root/.codex/hooks.json" "$home/.codex/hooks.json" \
    'root=$(pwd -P)' "root=$root"
  # grok's entries gate on GROK_WORKSPACE_ROOT being set before using it as the
  # root. Only the path use is rewritten, so the "am I under grok?" gate stands.
  if [ -d "$root/.grok/hooks" ]; then
    for f in "$root"/.grok/hooks/*.json; do
      [ -f "$f" ] || continue
      generate_host_config "$f" "$home/.grok/hooks/$(basename "$f")" \
        '${GROK_WORKSPACE_ROOT:-}/bin/' "$root/bin/"
    done
  fi
  if [ -d "$root/.opencode/plugins" ]; then
    mkdir -p "$home/.opencode"
    converge_symlink "$home/.opencode/plugins" "$FM_ROOT/.opencode/plugins" || return 1
  fi
  if [ -d "$root/.pi/extensions" ]; then
    mkdir -p "$home/.pi"
    converge_symlink "$home/.pi/extensions" "$FM_ROOT/.pi/extensions" || return 1
  fi
}

# Hide the home from the enclosing project's git through .git/info/exclude. That
# file is local and untracked, so the captain's repository is never modified.
exclude_home_from_project() { # <project-top>
  local top=$1 excl
  excl=$(cd "$top" && git rev-parse --git-path info/exclude) || return 1
  case "$excl" in
    /*) ;;
    *) excl="$top/$excl" ;;
  esac
  mkdir -p "$(dirname "$excl")"
  grep -qxF "/$HOME_DIR_NAME/" "$excl" 2>/dev/null && return 0
  printf '/%s/\n' "$HOME_DIR_NAME" >> "$excl"
}

cmd_init() {
  local target=$PWD name='' mode='' yolo='' annotation=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) shift; name=${1:?--name needs a value} ;;
      --mode) shift; mode=${1:?--mode needs a value} ;;
      --yolo) shift; yolo=${1:?--yolo needs a value} ;;
      -h|--help) usage; return 0 ;;
      -*) die "unknown option: $1" ;;
      *) target=$1 ;;
    esac
    shift
  done

  local top home root_abs
  top=$(project_top_level "$target") || exit 1
  home="$top/$HOME_DIR_NAME"
  root_abs=$(cd "$FM_ROOT" && pwd -P)
  [ -n "$name" ] || name=$(basename "$top")
  case "$name" in
    ''|.*|*[!A-Za-z0-9._-]*) die "project name '$name' must be a plain [A-Za-z0-9._-] name; pass --name" ;;
  esac
  case "$mode" in
    ''|no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
    *) die "--mode must be no-mistakes, direct-PR, local-only, or no-mistakes-prod-only" ;;
  esac
  case "$yolo" in
    ''|on|off) ;;
    *) die "--yolo must be on or off" ;;
  esac

  # A shared clone that is itself the project would make projects/<name> a
  # symlink to FM_ROOT and let a crewmate's project work land in the code root.
  if [ "$top" = "$root_abs" ]; then
    die "$top is the shared firstmate clone itself; it operates as its own home and needs no per-project home"
  fi

  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/.claude"

  # The contract is COPIED, not linked: see the header. CLAUDE.md imports it, and
  # an import target outside the harness project directory is silently skipped.
  [ -f "$root_abs/AGENTS.md" ] || die "the shared clone has no AGENTS.md: $root_abs"
  {
    printf '%s\n' "<!-- Generated copy of $root_abs/AGENTS.md - edit that file, not this one."
    printf '%s\n' "     Refreshed on every 'fm init' and every 'fm' launch. -->"
    cat "$root_abs/AGENTS.md"
  } | write_if_changed "$home/AGENTS.md"
  converge_symlink "$home/.claude/skills" "$FM_ROOT/.agents/skills" || exit 1
  converge_symlink "$home/projects/$name" "../.." || exit 1

  write_if_changed "$home/CLAUDE.md" <<'EOF'
<!-- Points the harness at the shared firstmate AGENTS.md; edit that, not this file. -->
@AGENTS.md
EOF

  # Regenerated on every converge, so an upstream hook change reaches this home
  # through a plain re-init.
  converge_host_configs "$home" "$root_abs" || exit 1

  write_if_changed "$home/$MARKER_NAME" <<EOF
project=$top
root=$root_abs
name=$name
EOF

  exclude_home_from_project "$top" || exit 1

  if [ ! -f "$home/data/projects.md" ]; then
    if [ -n "$mode" ]; then
      annotation=" [$mode"
      [ "$yolo" = on ] && annotation="$annotation +yolo"
      annotation="$annotation]"
    fi
    write_if_changed "$home/data/projects.md" <<EOF
# Projects

- $name$annotation - the project this home serves (added $(date +%Y-%m-%d))
EOF
  fi

  echo "home: $home"
  echo "root: $root_abs"
  echo "project: $top"
}

cmd_path() {
  local start=${1:-$PWD} home
  home=$(find_home_upward "$start") || {
    echo "error: no per-project firstmate home at or above $start; run fm-project-home.sh init" >&2
    exit 1
  }
  printf '%s\n' "$home"
}

cmd_status() {
  local start=${1:-$PWD} home marker name project root posture
  home=$(cmd_path "$start")
  marker="$home/$MARKER_NAME"
  project=$(marker_field "$marker" project) || project=
  root=$(marker_field "$marker" root) || root=
  name=$(marker_field "$marker" name) || name=
  echo "home: $home"
  echo "root: $root"
  echo "project: $project"
  echo "name: $name"
  if [ -n "$root" ] && [ -x "$root/bin/fm-project-mode.sh" ] && [ -n "$name" ]; then
    posture=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-project-mode.sh" --raw "$name" 2>/dev/null) || posture=
    [ -n "$posture" ] && echo "posture: $posture"
  fi
  if [ -z "$root" ] || [ ! -d "$root/bin" ]; then
    echo "warning: shared clone '$root' is missing bin/; rerun init from the current clone" >&2
  fi
}

case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  path) shift; cmd_path "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h|--help|'') usage ;;
  *) die "unknown subcommand: $1" ;;
esac
