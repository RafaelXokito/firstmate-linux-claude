#!/usr/bin/env bash
# tests/fm-claude-session-env.test.sh - a multiplexer server firstmate starts
# must not keep the Claude Code session variables of the session that started
# it (bin/fm-claude-session-env-lib.sh). Every pane such a server creates
# inherits its environment, so a leaked CLAUDE_CODE_CHILD_SESSION=1 makes every
# later `claude` there turn transcript saving off.
#
# herdr and zellij are driven through fakes that record the environment the
# server start actually received; tmux runs for real on a private socket.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-session-env-tests)

# The leaked session as Claude Code exports it, plus captain configuration that
# must survive the scrub so a passing case cannot be a blanket env wipe.
POLLUTED_ENV=(
  CLAUDECODE=1
  CLAUDE_CODE_CHILD_SESSION=1
  CLAUDE_CODE_SESSION_ID=parent-session
  CLAUDE_CODE_MESSAGING_SOCKET=/nonexistent/parent.sock
  CLAUDE_CODE_MESSAGING_TOKEN=parent-token
  CLAUDE_PID=4242
  CLAUDE_ENV_FILE=/nonexistent/parent-env.sh
  CLAUDE_PROJECT_DIR=/nonexistent/parent-project
  CLAUDE_CONFIG_DIR=/opt/test/claude-config
  FM_TEST_KEEP=kept
)

# assert_env_scrubbed <env-dump-file> <label>: the dump is `env` output captured
# by whatever process the server start ran.
assert_env_scrubbed() {
  local dump=$1 label=$2 var
  [ -s "$dump" ] || fail "$label: the server start never ran, so nothing was checked"
  for var in CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID \
    CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_PID \
    CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR; do
    if grep -q "^$var=" "$dump"; then
      fail "$label: the server inherited $var from the parent Claude Code session"
    fi
  done
  grep -qx 'CLAUDE_CONFIG_DIR=/opt/test/claude-config' "$dump" ||
    fail "$label: captain configuration CLAUDE_CONFIG_DIR was dropped"
  grep -qx 'FM_TEST_KEEP=kept' "$dump" || fail "$label: an unrelated variable was dropped"
}

test_lib_keeps_caller_environment() {
  local out
  out=$(env "${POLLUTED_ENV[@]}" bash -c '
    . "$0/bin/fm-claude-session-env-lib.sh"
    ( fm_claude_session_env_clear; printf "inner=%s\n" "${CLAUDE_CODE_CHILD_SESSION:-unset}" )
    printf "outer=%s\n" "${CLAUDE_CODE_CHILD_SESSION:-unset}"
    env $(fm_claude_session_env_unset_args) printenv CLAUDE_CODE_CHILD_SESSION || echo printenv=unset
  ' "$ROOT")
  assert_contains "$out" "inner=unset" "fm_claude_session_env_clear left CLAUDE_CODE_CHILD_SESSION set"
  assert_contains "$out" "outer=1" "fm_claude_session_env_clear inside a subshell changed the caller"
  assert_contains "$out" "printenv=unset" "the env arguments did not clear CLAUDE_CODE_CHILD_SESSION"
  pass "the clear helper and env arguments drop the session marker without touching the caller"
}

test_herdr_server_starts_without_session_env() {
  local dir fb dump status
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; return 0; }
  dir="$TMP_ROOT/herdr"; fb="$dir/fakebin"; dump="$dir/server.env"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    if [ -f "$FM_FAKE_DIR/running" ]; then running=true; else running=false; fi
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":%s}}\n' "$running"
    ;;
  server)
    env > "$FM_FAKE_DIR/server.env"
    : > "$FM_FAKE_DIR/running"
    ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  env -u HERDR_PANE_ID -u HERDR_ENV -u HERDR_SESSION "${POLLUTED_ENV[@]}" \
    PATH="$fb:$PATH" FM_FAKE_DIR="$dir" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure fmtest' "$ROOT"
  status=$?
  [ "$status" -eq 0 ] || fail "herdr server_ensure failed against the fake (exit $status)"
  assert_env_scrubbed "$dump" "herdr server_ensure"
  pass "a herdr server firstmate starts carries no parent Claude Code session variables"
}

test_zellij_session_starts_without_session_env() {
  local dir fb dump status
  dir="$TMP_ROOT/zellij"; fb="$dir/fakebin"; dump="$dir/server.env"
  mkdir -p "$fb"
  cat > "$fb/zellij" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-sessions) [ -f "$FM_FAKE_DIR/sessions" ] && cat "$FM_FAKE_DIR/sessions" ;;
  attach)
    env > "$FM_FAKE_DIR/server.env"
    printf '%s\n' "$3" >> "$FM_FAKE_DIR/sessions"
    ;;
esac
exit 0
SH
  chmod +x "$fb/zellij"
  env -u ZELLIJ -u ZELLIJ_SESSION_NAME "${POLLUTED_ENV[@]}" \
    PATH="$fb:$PATH" FM_FAKE_DIR="$dir" \
    bash -c '. "$0/bin/backends/zellij.sh"; fm_backend_zellij_server_ensure fmtest' "$ROOT"
  status=$?
  [ "$status" -eq 0 ] || fail "zellij server_ensure failed against the fake (exit $status)"
  assert_env_scrubbed "$dump" "zellij server_ensure"
  pass "a zellij session firstmate starts carries no parent Claude Code session variables"
}

test_tmux_server_starts_without_session_env() {
  local real_tmux socket shim dump status
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; return 0; }
  real_tmux=$(command -v tmux)
  socket="fm-claude-session-env-$$"
  shim="$TMP_ROOT/tmux-shim"; dump="$TMP_ROOT/tmux.env"
  mkdir -p "$shim"
  # Route the adapter's bare `tmux` calls to a private socket so the host's
  # own server is never touched.
  cat > "$shim/tmux" <<SH
#!/usr/bin/env bash
exec "$real_tmux" -L "$socket" "\$@"
SH
  chmod +x "$shim/tmux"
  env -u TMUX "${POLLUTED_ENV[@]}" PATH="$shim:$PATH" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux && fm_backend_tmux_container_ensure' "$ROOT" >/dev/null
  status=$?
  # The global environment is what every new pane starts from.
  PATH="$shim:$PATH" tmux show-environment -g > "$dump" 2>/dev/null
  PATH="$shim:$PATH" tmux kill-server >/dev/null 2>&1
  [ "$status" -eq 0 ] || fail "tmux container_ensure failed (exit $status)"
  assert_env_scrubbed "$dump" "tmux container_ensure"
  pass "a tmux server firstmate starts carries no parent Claude Code session variables"
}

test_lib_keeps_caller_environment
test_herdr_server_starts_without_session_env
test_zellij_session_starts_without_session_env
test_tmux_server_starts_without_session_env
