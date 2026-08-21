#!/usr/bin/env bash
# Behavior tests for the per-project home layout: bin/fm-project-home.sh and the
# bin/fm-launch.sh entry point that resolves and enters one.
#
# The inverted layout puts an operational home INSIDE each project checkout
# (<project>/.firstmate) and serves every home from one shared tracked clone.
# These cases pin the properties that make that safe:
#   SHAPE       init creates the marker, the shared-surface symlinks, the single
#               projects/<name> back-link, and a seeded registry entry.
#   HOST CONFIG every supported primary harness's host config lands in the home
#               addressing the SHARED clone's bin/, never the home's own.
#   NO BIN LINK a bin/ symlink is never created. Reached through one, a script
#               resolves its code root to the HOME, which would aim the
#               worktree-tangle guard at the project's own branch.
#   INVISIBLE   the project's git never sees the home, and no tracked .gitignore
#               is touched: the entry goes in local .git/info/exclude.
#   CONVERGENT  init is idempotent and repairs a drifted symlink and a stale
#               generated hook config without touching data/, state/, or config/.
#   REFUSALS    a non-git dir, a linked worktree, and the shared clone itself are
#               all refused rather than given a home that cannot work.
#   ENTRY       fm-launch.sh resolves the home from a nested subdir, exports both
#               FM_HOME and FM_ROOT_OVERRIDE, and runs only tracked bin scripts.
# All cases are hermetic over temp git repos; the real clone is used only as the
# read-only code root, which is what these scripts exist to share.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOMESH="$ROOT/bin/fm-project-home.sh"
LAUNCH="$ROOT/bin/fm-launch.sh"
ROOT_ABS=$(cd "$ROOT" && pwd -P)

TMP_ROOT=$(fm_test_tmproot fm-project-home)
fm_git_identity fmtest fmtest@example.invalid

# A fresh project checkout with one commit and a local origin. Echoes its path.
make_project() {
  local dir=$1
  fm_git_init_commit "$dir"
  fm_git_add_origin "$dir" "$dir.origin.git"
  (cd "$dir" && pwd -P)
}

# --- SHAPE ------------------------------------------------------------------

test_init_shape() {
  local proj home out d
  proj=$(make_project "$TMP_ROOT/shape")
  out=$("$HOMESH" init "$proj" --mode direct-PR --yolo on 2>&1) || fail "init failed: $out"
  home="$proj/.firstmate"

  assert_contains "$out" "home: $home" "init must report the home it created"
  assert_contains "$out" "root: $ROOT_ABS" "init must report the shared code root"

  assert_present "$home/.fm-project-home" "the home marker must exist"
  assert_grep "project=$proj" "$home/.fm-project-home" "the marker must record the project"
  assert_grep "root=$ROOT_ABS" "$home/.fm-project-home" "the marker must record the code root"
  assert_grep "name=shape" "$home/.fm-project-home" "the marker must record the project name"

  for d in data state config projects; do
    [ -d "$home/$d" ] || fail "init must create $d/"
  done

  # THE load-bearing invariant. CLAUDE.md reaches the contract through a memory
  # import, and an import whose target resolves outside the harness project
  # directory is silently skipped: the contract never loads, nothing is reported,
  # and the session looks like an ordinary one that happened to run firstmate's
  # startup digest. So the contract must be a real file INSIDE the home, never a
  # symlink escaping it.
  [ -L "$home/AGENTS.md" ] && fail "AGENTS.md must not be a symlink; an import target outside the home is silently skipped"
  [ -f "$home/AGENTS.md" ] || fail "AGENTS.md must be a real file inside the home"
  case "$(readlink -f "$home/AGENTS.md")" in
    "$home"/*) ;;
    *) fail "the contract must resolve INSIDE the home, got $(readlink -f "$home/AGENTS.md")" ;;
  esac
  assert_grep "You are the first mate" "$home/AGENTS.md" "the generated contract must carry the shared contract's text"
  assert_grep "Generated copy of" "$home/AGENTS.md" "the generated contract must say where to edit it instead"
  [ -L "$home/.claude/skills" ] || fail ".claude/skills must be a symlink to the shared skills"

  # The one projects/ entry is a back-link to the enclosing checkout, so every
  # script that resolves a project through this home lands on the real work tree.
  [ -L "$home/projects/shape" ] || fail "projects/<name> must be a symlink"
  [ "$(cd "$home/projects/shape" && pwd -P)" = "$proj" ] \
    || fail "projects/<name> must resolve to the enclosing project checkout"

  assert_grep "@AGENTS.md" "$home/CLAUDE.md" "CLAUDE.md must import the shared contract"

  # --mode/--yolo seed the registry in the format bin/fm-project-mode.sh parses.
  assert_grep "- shape [direct-PR +yolo]" "$home/data/projects.md" \
    "the seeded registry entry must carry the requested posture"
  assert_grep "(added $(date +%Y-%m-%d))" "$home/data/projects.md" \
    "the seeded registry entry must carry an ISO date"

  pass "fm-project-home: init creates the marker, shared-surface links, back-link, and seeded registry"
}

# --- HOST CONFIGS -----------------------------------------------------------

# Every supported primary harness reaches firstmate through its own host config,
# and in a per-project home the harness project dir is the HOME, not the shared
# clone. A config left addressing that project dir points at a bin/ which does
# not exist there, and every one of these hosts fails SILENTLY in that case: the
# codex and grok entries self-check and exit 0, and the opencode plugin swallows
# its spawn error. The session then runs with no supervision and no diagnostic,
# which is why this is asserted per host rather than trusted.
#
# Rows are "kind|source|dest|forbidden":
#   file  generated from one shared file with the root expression substituted
#   glob  a directory of such files
#   link  a directory the host resolves in EXECUTED code, which reads
#         FM_ROOT_OVERRIDE, so the shared directory is linked rather than copied
# "forbidden" is the root expression that must not survive into the home.
expected_host_configs() {
  cat <<'ROWS'
file|.claude/settings.json|.claude/settings.json|$CLAUDE_PROJECT_DIR
file|.cursor/hooks.json|.cursor/hooks.json|$CURSOR_PROJECT_DIR
file|.codex/hooks.json|.codex/hooks.json|root=$(pwd -P)
glob|.grok/hooks|.grok/hooks|${GROK_WORKSPACE_ROOT:-}/bin/
link|.opencode/plugins|.opencode/plugins|
link|.pi/extensions|.pi/extensions|
ROWS
}

# A generated host config is correct when it names the shared clone and still
# carries its hook scripts. Each host spells the qualified path its own way -
# claude and cursor as "<root>"/bin/..., grok as "<root>/bin/...", codex through
# a root= assignment the entry expands later - so the assertion is the presence
# of the absolute root plus the absence of the project-dir expression, not one
# adjacency pattern that would only fit some of them.
assert_addresses_shared_clone() { # <file> <label>
  local file=$1 label=$2
  assert_grep "$ROOT_ABS" "$file" "$label must address the shared clone by absolute path"
  grep -qF '/bin/fm-' "$file" || fail "$label must still name at least one firstmate hook script"
}

# Overwrite every generated host config with content that could not survive a
# real converge, and point every linked host directory somewhere wrong.
stale_every_host_config() { # <home>
  local home=$1 kind src dest forbidden f
  while IFS='|' read -r kind src dest forbidden; do
    [ -n "$kind" ] || continue
    case "$kind" in
      file)
        [ -f "$ROOT/$src" ] || continue
        mkdir -p "$(dirname "$home/$dest")"
        printf 'stale\n' > "$home/$dest"
        ;;
      glob)
        [ -d "$ROOT/$src" ] || continue
        mkdir -p "$home/$dest"
        for f in "$ROOT/$src"/*.json; do
          [ -f "$f" ] || continue
          printf 'stale\n' > "$home/$dest/$(basename "$f")"
        done
        ;;
      link)
        [ -d "$ROOT/$src" ] || continue
        mkdir -p "$(dirname "$home/$dest")"
        ln -sfn /nonexistent/drifted "$home/$dest"
        ;;
    esac
  done <<EOF
$(expected_host_configs)
EOF
}

assert_every_host_config_converged() { # <home>
  local home=$1 kind src dest forbidden f base
  while IFS='|' read -r kind src dest forbidden; do
    [ -n "$kind" ] || continue
    case "$kind" in
      file)
        [ -f "$ROOT/$src" ] || continue
        assert_no_grep "stale" "$home/$dest" "re-init must regenerate a stale $dest"
        assert_no_grep "$forbidden" "$home/$dest" \
          "the regenerated $dest must not defer to the harness project dir"
        assert_addresses_shared_clone "$home/$dest" "the regenerated $dest"
        ;;
      glob)
        [ -d "$ROOT/$src" ] || continue
        for f in "$ROOT/$src"/*.json; do
          [ -f "$f" ] || continue
          base=$(basename "$f")
          assert_no_grep "stale" "$home/$dest/$base" "re-init must regenerate a stale $base"
          assert_addresses_shared_clone "$home/$dest/$base" "the regenerated $base"
        done
        ;;
      link)
        [ -d "$ROOT/$src" ] || continue
        [ "$(cd "$home/$dest" && pwd -P)" = "$(cd "$ROOT/$src" && pwd -P)" ] \
          || fail "re-init must repair a drifted $dest link"
        ;;
    esac
  done <<EOF
$(expected_host_configs)
EOF
}

test_host_configs_address_the_shared_clone() {
  local proj home kind src dest forbidden f base matched=0
  proj=$(make_project "$TMP_ROOT/hosts")
  "$HOMESH" init "$proj" >/dev/null 2>&1 || fail "init failed"
  home="$proj/.firstmate"

  while IFS='|' read -r kind src dest forbidden; do
    [ -n "$kind" ] || continue
    case "$kind" in
      file)
        [ -f "$ROOT/$src" ] || continue
        matched=1
        assert_present "$home/$dest" "the home must carry a generated $src for its host"
        assert_no_grep "$forbidden" "$home/$dest" \
          "the generated $dest must not defer to the harness project dir"
        assert_addresses_shared_clone "$home/$dest" "the generated $dest"
        ;;
      glob)
        [ -d "$ROOT/$src" ] || continue
        for f in "$ROOT/$src"/*.json; do
          [ -f "$f" ] || continue
          matched=1
          base=$(basename "$f")
          assert_present "$home/$dest/$base" "the home must carry a generated $base"
          assert_no_grep "$forbidden" "$home/$dest/$base" \
            "the generated $base must not defer to the harness project dir"
          assert_addresses_shared_clone "$home/$dest/$base" "the generated $base"
        done
        ;;
      link)
        [ -d "$ROOT/$src" ] || continue
        matched=1
        [ -L "$home/$dest" ] || fail "$dest must be a symlink into the shared clone"
        [ "$(cd "$home/$dest" && pwd -P)" = "$(cd "$ROOT/$src" && pwd -P)" ] \
          || fail "$dest must resolve to the shared clone's $src"
        ;;
    esac
  done <<EOF
$(expected_host_configs)
EOF

  # A matrix that matched nothing would pass every assertion above vacuously.
  [ "$matched" = 1 ] || fail "the host matrix matched no host config in the shared clone"

  pass "fm-project-home: every harness host config in the home addresses the shared clone"
}

# The plugin hosts resolve firstmate's bin/ in executed code, from the project
# directory the harness hands them - which is the HOME. FM_ROOT_OVERRIDE, which
# bin/fm-launch.sh exports, is what redirects them to the shared clone. Prove it
# through the plugin's own public hook, with a stub root whose guard announces
# itself, so the assertion cannot pass on the derived path by accident.
test_opencode_plugins_prefer_root_override() {
  local proj home stub out
  proj=$(make_project "$TMP_ROOT/oc-override")
  "$HOMESH" init "$proj" >/dev/null 2>&1 || fail "init failed"
  home="$proj/.firstmate"

  if ! command -v node >/dev/null 2>&1; then
    pass "fm-project-home: opencode root override (SKIPPED: node absent)"
    return 0
  fi

  stub="$TMP_ROOT/oc-stub-root"
  mkdir -p "$stub/bin"
  cat > "$stub/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
echo "STUB-ROOT-GUARD-RAN" >&2
exit 2
SH
  chmod +x "$stub/bin/fm-cd-pretool-check.sh"

  run_cd_plugin() { # <root-override> <project-dir>
    local override=$1 dir=$2
    NODE_NO_WARNINGS=1 FM_ROOT_OVERRIDE="$override" node --input-type=module -e "
      const { FmPrimaryCdCheck } = await import('$ROOT_ABS/.opencode/plugins/fm-primary-cd-check.js');
      const hooks = await FmPrimaryCdCheck({ directory: '$dir', worktree: '$dir' });
      try {
        await hooks['tool.execute.before']({ tool: 'bash' }, { args: { command: 'cd /tmp' } });
        console.log('NO-THROW');
      } catch (e) { console.log('THREW: ' + e.message); }
    " 2>&1
  }

  # The home is the project dir the harness reports; the override names the root.
  out=$(run_cd_plugin "$stub" "$home") || fail "the plugin harness failed: $out"
  assert_contains "$out" "STUB-ROOT-GUARD-RAN" \
    "the plugin must reach the guard through FM_ROOT_OVERRIDE, not the harness project dir"
  assert_contains "$out" "THREW:" "a denying guard must still block the tool call"

  # With no override the derived project dir must still be honored, or the same
  # plugin would stop working in the shared clone it was written for.
  out=$(env -u FM_ROOT_OVERRIDE NODE_NO_WARNINGS=1 node --input-type=module -e "
    const { FmPrimaryCdCheck } = await import('$ROOT_ABS/.opencode/plugins/fm-primary-cd-check.js');
    const hooks = await FmPrimaryCdCheck({ directory: '$stub', worktree: '$stub' });
    try {
      await hooks['tool.execute.before']({ tool: 'bash' }, { args: { command: 'cd /tmp' } });
      console.log('NO-THROW');
    } catch (e) { console.log('THREW: ' + e.message); }
  " 2>&1) || fail "the plugin harness failed: $out"
  assert_contains "$out" "STUB-ROOT-GUARD-RAN" \
    "with no override the plugin must still resolve the root it was handed"

  pass "fm-project-home: opencode plugins resolve firstmate's bin/ through FM_ROOT_OVERRIDE"
}

# --- NO BIN LINK ------------------------------------------------------------

# A bin/ symlink is the one shortcut that silently breaks the layout: a script
# invoked through it resolves FM_ROOT to the home, so the tangle guard would then
# watch the PROJECT's branch and alarm on every feature branch. Assert the guard
# by its consequence, not just the missing path: with the home as cwd and the
# code root named explicitly, the project's branch must never read as a tangle.
test_no_bin_symlink() {
  local proj home out
  proj=$(make_project "$TMP_ROOT/nobin")
  "$HOMESH" init "$proj" >/dev/null 2>&1 || fail "init failed"
  home="$proj/.firstmate"
  assert_absent "$home/bin" "init must not create a bin/ symlink into the home"

  git -C "$proj" checkout -q -b feature/would-tangle
  out=$(cd "$home" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-guard.sh" 2>&1) || true
  assert_not_contains "$out" "feature/would-tangle" \
    "the guard must never read the project's branch as a tangled code root"

  pass "fm-project-home: no bin/ symlink, and the project's branch never reads as a tangle"
}

# --- INVISIBLE --------------------------------------------------------------

test_home_invisible_to_project_git() {
  local proj home status
  proj=$(make_project "$TMP_ROOT/invisible")
  "$HOMESH" init "$proj" >/dev/null 2>&1 || fail "init failed"
  home="$proj/.firstmate"

  # Real operational content, the state a naive exclude would miss.
  printf 'running: work\n' > "$home/state/t1.status"

  status=$(git -C "$proj" status --porcelain)
  [ -z "$status" ] || fail "the project must stay clean with a home inside it; got: $status"

  # The captain's tracked ignore file is never written; the entry is local only.
  assert_absent "$proj/.gitignore" "init must not create a tracked .gitignore in the project"
  assert_grep "/.firstmate/" "$proj/.git/info/exclude" \
    "the home must be hidden through the local, untracked exclude file"

  pass "fm-project-home: the home is invisible to the project's git and edits no tracked ignore file"
}

# --- CONVERGENT -------------------------------------------------------------

test_init_converges() {
  local proj home before after
  proj=$(make_project "$TMP_ROOT/converge")
  "$HOMESH" init "$proj" >/dev/null 2>&1 || fail "init failed"
  home="$proj/.firstmate"

  # Captain data must survive every converge run.
  printf 'captain note\n' > "$home/data/captain.md"
  printf 'running: work\n' > "$home/state/t1.status"

  # Drift: a legacy symlink where the generated contract belongs - the exact shape
  # a home created before that fix carries - plus a stale generated hook config.
  ln -sfn /nonexistent/AGENTS.md "$home/AGENTS.md"
  stale_every_host_config "$home"

  before=$(cat "$home/data/projects.md")
  "$HOMESH" init "$proj" >/dev/null 2>&1 || fail "re-init failed"

  # Converging a legacy symlinked home must leave a real in-home contract behind.
  [ -L "$home/AGENTS.md" ] && fail "re-init must replace a legacy contract symlink with a real file"
  assert_grep "You are the first mate" "$home/AGENTS.md" "re-init must regenerate the contract copy"
  case "$(readlink -f "$home/AGENTS.md")" in
    "$home"/*) ;;
    *) fail "re-init must leave the contract resolving inside the home" ;;
  esac
  assert_grep "captain note" "$home/data/captain.md" "re-init must never remove captain data"
  assert_grep "running: work" "$home/state/t1.status" "re-init must never remove runtime state"
  after=$(cat "$home/data/projects.md")
  [ "$before" = "$after" ] || fail "re-init must not rewrite an existing registry"

  # A contract copy that fell behind the shared clone must be refreshed, or a home
  # would silently keep running last week's rules.
  printf 'outdated\n' > "$home/AGENTS.md"
  "$HOMESH" init "$proj" >/dev/null 2>&1 || fail "re-init failed"
  assert_grep "You are the first mate" "$home/AGENTS.md" "re-init must refresh a stale contract copy"
  assert_no_grep "outdated" "$home/AGENTS.md" "re-init must not leave stale contract bytes behind"

  # Every host config must come back addressing the shared clone. A home that
  # converged only Claude's would leave the other harnesses silently unsupervised.
  assert_every_host_config_converged "$home"

  pass "fm-project-home: init converges drift and preserves data, state, and the registry"
}

# --- REFUSALS ---------------------------------------------------------------

test_refusals() {
  local out code plain proj wt
  plain="$TMP_ROOT/not-a-repo"
  mkdir -p "$plain"
  out=$("$HOMESH" init "$plain" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "init must refuse a directory that is not a git checkout"
  assert_contains "$out" "not a git checkout" "the refusal must name the missing checkout"
  assert_absent "$plain/.firstmate" "a refused init must create nothing"

  # A linked worktree is disposable; a home created there would vanish with it.
  proj="$TMP_ROOT/refuse-wt"
  wt="$TMP_ROOT/refuse-wt-linked"
  fm_git_worktree "$proj" "$wt" fm/task
  out=$("$HOMESH" init "$wt" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "init must refuse a linked worktree"
  assert_contains "$out" "linked worktree" "the refusal must name the linked worktree"
  assert_absent "$wt/.firstmate" "a refused init must create nothing"

  # The shared clone operates as its own home; a back-link there would let a
  # crewmate's project work land in the code root.
  out=$("$HOMESH" init "$ROOT" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "init must refuse the shared clone itself"
  assert_contains "$out" "shared firstmate clone" "the refusal must name the shared clone"

  pass "fm-project-home: refuses a non-checkout, a linked worktree, and the shared clone"
}

# --- ENTRY ------------------------------------------------------------------

test_launch_resolves_and_exports() {
  local proj home nested out code
  proj=$(make_project "$TMP_ROOT/entry")
  "$HOMESH" init "$proj" --mode local-only >/dev/null 2>&1 || fail "init failed"
  home="$proj/.firstmate"

  # Resolution walks up, so the captain can be anywhere inside the project.
  nested="$proj/a/b/c"
  mkdir -p "$nested"
  out=$("$HOMESH" path "$nested") || fail "path must resolve from a nested subdir"
  [ "$out" = "$home" ] || fail "path must resolve to the enclosing home, got '$out'"

  # Both exports are required; FM_ROOT_OVERRIDE is what keeps the code root right.
  out=$(cd "$nested" && env -u FM_HOME -u FM_ROOT_OVERRIDE "$LAUNCH" env)
  assert_contains "$out" "export FM_HOME=$home" "env must export the resolved home"
  assert_contains "$out" "export FM_ROOT_OVERRIDE=$ROOT_ABS" \
    "env must export the shared clone as the code root"

  # run proves the home is actually in effect: the posture comes from THIS home's
  # registry, not the shared clone's.
  out=$(cd "$nested" && env -u FM_HOME -u FM_ROOT_OVERRIDE "$LAUNCH" run fm-project-mode.sh entry 2>&1) \
    || fail "run must execute a tracked script in the home: $out"
  assert_contains "$out" "local-only" "run must resolve posture from the home's own registry"

  # run is a tracked-namespace door, not a general exec.
  out=$(cd "$nested" && "$LAUNCH" run ../../etc/passwd 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "run must refuse a path"
  assert_contains "$out" "bare script name" "the refusal must name the bare-name requirement"
  out=$(cd "$nested" && "$LAUNCH" run id 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "run must refuse a command outside the fm-*.sh namespace"

  # Outside any home, the entry point refuses with the command to run rather than
  # silently serving some other project's home.
  out=$(cd "$TMP_ROOT" && env -u FM_HOME -u FM_ROOT_OVERRIDE "$LAUNCH" env 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "env must refuse outside any home"
  assert_contains "$out" "fm init" "the refusal must name the init command"

  pass "fm-launch: resolves the home from a subdir, exports both roots, and gates run to tracked scripts"
}

test_launch_alias_shim() {
  local dest out proj
  dest="$TMP_ROOT/alias-bin"
  out=$("$LAUNCH" alias "$dest" 2>&1) || fail "alias failed: $out"
  assert_present "$dest/fm" "alias must install the fm shim"
  [ -x "$dest/fm" ] || fail "the installed shim must be executable"
  assert_grep "$ROOT_ABS/bin/fm-launch.sh" "$dest/fm" "the shim must exec this clone's launcher"

  # The shim is a real entry point, not just a file: it must resolve a home
  # through the launcher it execs.
  proj=$(make_project "$TMP_ROOT/alias-project")
  "$HOMESH" init "$proj" >/dev/null 2>&1 || fail "init failed"
  out=$(env -u FM_HOME -u FM_ROOT_OVERRIDE "$dest/fm" status "$proj" 2>&1) \
    || fail "the installed shim must reach the launcher: $out"
  assert_contains "$out" "home: $proj/.firstmate" "the shim must report the project's own home"
  assert_contains "$out" "root: $ROOT_ABS" "the shim must report the shared clone as the code root"

  pass "fm-launch: alias installs a working fm shim that execs this clone's launcher"
}

test_init_shape
test_host_configs_address_the_shared_clone
test_opencode_plugins_prefer_root_override
test_no_bin_symlink
test_home_invisible_to_project_git
test_init_converges
test_refusals
test_launch_resolves_and_exports
test_launch_alias_shim
