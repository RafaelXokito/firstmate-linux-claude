#!/usr/bin/env bash
# fm-claude-session-env-lib.sh - the single owner of the Claude Code session
# variables that must not leak out of the session that set them.
#
# Sourced, never executed. Claude Code exports these into every process it
# starts so tools can find their parent session. When firstmate itself runs as
# a Claude Code session and starts a long-lived multiplexer server (herdr,
# zellij, tmux), the server keeps that environment forever and hands it to every
# pane it ever creates. A `claude` later started in such a pane - the captain's
# own `fm` launch or a claude crewmate - sees CLAUDE_CODE_CHILD_SESSION=1, takes
# itself for a sub-session of a long-dead parent, and turns transcript saving
# off ("Transcript saving is off - inherited CLAUDE_CODE_CHILD_SESSION marker").
# The stale CLAUDECODE also outranks a markerless harness in fm-harness.sh's
# environment detection.
#
# Only session-scoped variables are listed. Captain configuration such as
# CLAUDE_CONFIG_DIR or any CLAUDE_CODE_* setting the captain exports on purpose
# is deliberately kept, so this is an explicit list rather than a prefix match.
#
#   fm_claude_session_env_unset_args
#       Prints the `env` arguments that clear every listed variable, as one
#       space-separated line, for composing a command string another shell runs.
#
#   fm_claude_session_env_clear
#       Unsets every listed variable in the CURRENT shell. Call it inside a
#       subshell, `( fm_claude_session_env_clear; start-the-server ... )`, so the
#       caller's own environment is left alone.
set -u

FM_CLAUDE_SESSION_ENV_VARS=(
  CLAUDECODE
  CLAUDE_CODE_CHILD_SESSION
  CLAUDE_CODE_SESSION_ID
  CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_CODE_SESSION_ATTENDED
  CLAUDE_CODE_ENTRYPOINT
  CLAUDE_CODE_EXECPATH
  CLAUDE_CODE_MESSAGING_SOCKET
  CLAUDE_CODE_MESSAGING_TOKEN
  CLAUDE_PID
  CLAUDE_ENV_FILE
  CLAUDE_PROJECT_DIR
  CLAUDE_EFFORT
)

fm_claude_session_env_unset_args() {
  local var out=""
  for var in "${FM_CLAUDE_SESSION_ENV_VARS[@]}"; do
    out="$out -u $var"
  done
  printf '%s\n' "${out# }"
}

fm_claude_session_env_clear() {
  unset "${FM_CLAUDE_SESSION_ENV_VARS[@]}"
}
