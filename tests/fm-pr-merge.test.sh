#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a Bitbucket PR is merged through REST 1.0 with the version read first
#   (j) a Bitbucket PR already merged, declined, or of unreadable version is
#       refused without ever sending the merge
#   (k) a Bitbucket merge that does not report MERGED is a failure, never an
#       assumed success
#   (l) a Bitbucket merge refuses extra args and a missing credential
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# curl mock for the Bitbucket REST path, reproducing the two calls the merge
# makes: a GET that carries the pull request's current version, then a POST to
# the merge endpoint. Each invocation is recorded so the test can assert that no
# merge was sent when one had to be refused.
add_bitbucket_curl_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CURL_LOG"
case " $* " in
  *" -X POST "*)
    [ "${FM_TEST_CURL_POST_FAIL:-0}" = 0 ] || exit 1
    printf '%s' "${FM_TEST_CURL_POST_BODY:-{\"state\":\"MERGED\"\}}"
    ;;
  *)
    [ "${FM_TEST_CURL_GET_FAIL:-0}" = 0 ] || exit 1
    printf '%s' "${FM_TEST_CURL_GET_BODY:-{\"id\":7,\"version\":3,\"state\":\"OPEN\"\}}"
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/curl"
}

run_pr_merge_bitbucket() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_CURL_LOG="$case_dir/curl.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}


BB_URL=https://bb.example/projects/KEY/repos/repo/pull-requests/7

# Build a Bitbucket case: gh mocks for the shared recording step, a curl mock for
# the REST path, and a token in the home's .env. BITBUCKET_PAT is unset for the
# whole family so a real token on the operator's shell cannot make the
# no-credential case vacuous.
make_bitbucket_case() {
  local name=$1 case_dir
  case_dir=$(make_case "$name")
  add_gh_mocks "$case_dir" 0123456789abcdef0123456789abcdef01234567
  add_bitbucket_curl_mock "$case_dir"
  printf 'BITBUCKET_PAT=fixture-token\n' > "$case_dir/.env"
  : > "$case_dir/curl.log"
  printf '%s\n' "$case_dir"
}

test_bitbucket_merges_through_rest_with_version() {
  local case_dir out
  unset BITBUCKET_PAT
  case_dir=$(make_bitbucket_case bitbucket-merge)
  out=$(run_pr_merge_bitbucket "$case_dir" task-x1 "$BB_URL") \
    || fail "a Bitbucket merge that reported MERGED did not succeed"
  assert_contains "$out" "merged $BB_URL" "a successful Bitbucket merge must report the merged PR"

  # Recording still happens before the merge, so teardown has a PR to verify.
  assert_grep "pr=$BB_URL" "$case_dir/state/task-x1.meta" \
    "a Bitbucket merge must record pr= before merging"

  # The version read must precede the merge, and the merge must carry exactly
  # that version: it is Bitbucket's optimistic lock, not decoration.
  assert_grep "https://bb.example/rest/api/1.0/projects/KEY/repos/repo/pull-requests/7" \
    "$case_dir/curl.log" "the merge must address the REST endpoint from the URL"
  assert_grep "pull-requests/7/merge?version=3" "$case_dir/curl.log" \
    "the merge must pass the version read from the pull request"
  [ "$(grep -c 'X POST' "$case_dir/curl.log")" = 1 ] \
    || fail "a Bitbucket merge must send exactly one merge request"

  # The GitHub CLI is never reached for a Bitbucket URL.
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "a Bitbucket merge must not reach the GitHub merge CLI"

  pass "fm-pr-merge: a Bitbucket PR is merged through REST 1.0 with the version read first"
}

test_bitbucket_refuses_without_sending_merge() {
  local case_dir rc row body expect
  unset BITBUCKET_PAT
  while IFS='|' read -r row body expect; do
    [ -n "$row" ] || continue
    case_dir=$(make_bitbucket_case "bitbucket-refuse-$row")
    set +e
    out=$(FM_TEST_CURL_GET_BODY="$body" run_pr_merge_bitbucket "$case_dir" task-x1 "$BB_URL" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "a Bitbucket merge succeeded for the $row case"
    assert_contains "$out" "$expect" "the $row refusal must say why"
    assert_no_grep 'X POST' "$case_dir/curl.log" \
      "the $row case must never send a merge"
  done <<'EOF'
merged|{"id":7,"version":3,"state":"MERGED"}|already merged
declined|{"id":7,"version":3,"state":"DECLINED"}|declined
noversion|{"id":7,"state":"OPEN"}|version
errorpage|<html>500</html>|version
EOF
  pass "fm-pr-merge: an already merged, declined, or unreadable Bitbucket PR is refused before any merge"
}

test_bitbucket_unconfirmed_merge_is_a_failure() {
  local case_dir rc out
  unset BITBUCKET_PAT
  case_dir=$(make_bitbucket_case bitbucket-unconfirmed)
  set +e
  out=$(FM_TEST_CURL_POST_BODY='{"errors":[{"message":"merge conflict"}]}' \
    run_pr_merge_bitbucket "$case_dir" task-x1 "$BB_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a Bitbucket merge that did not report MERGED was treated as success"
  assert_contains "$out" "nothing is assumed merged" \
    "an unconfirmed Bitbucket merge must say nothing is assumed merged"

  case_dir=$(make_bitbucket_case bitbucket-post-fails)
  set +e
  out=$(FM_TEST_CURL_POST_FAIL=1 run_pr_merge_bitbucket "$case_dir" task-x1 "$BB_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed Bitbucket merge transport was treated as success"

  pass "fm-pr-merge: a Bitbucket merge that is not confirmed MERGED fails instead of assuming success"
}

test_bitbucket_refuses_extra_args_and_missing_token() {
  local case_dir rc out
  unset BITBUCKET_PAT
  case_dir=$(make_bitbucket_case bitbucket-extra-args)
  set +e
  out=$(run_pr_merge_bitbucket "$case_dir" task-x1 "$BB_URL" -- --rebase 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a Bitbucket merge accepted extra merge arguments"
  assert_contains "$out" "no extra merge arguments" "the refusal must name the unsupported arguments"

  case_dir=$(make_bitbucket_case bitbucket-no-token)
  rm -f "$case_dir/.env"
  set +e
  out=$(run_pr_merge_bitbucket "$case_dir" task-x1 "$BB_URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a Bitbucket merge succeeded with no credential"
  assert_contains "$out" "Personal Access Token" "the refusal must name the missing token"
  assert_no_grep 'X POST' "$case_dir/curl.log" "a credential-less merge must send nothing"

  pass "fm-pr-merge: a Bitbucket merge refuses extra arguments and a missing credential"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_bitbucket_merges_through_rest_with_version
test_bitbucket_refuses_without_sending_merge
test_bitbucket_unconfirmed_merge_is_a_failure
test_bitbucket_refuses_extra_args_and_missing_token
