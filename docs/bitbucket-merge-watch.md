# Bitbucket merge watch and merge verification

Empirical record for the Bitbucket Server and Data Center merge watch and merge, alongside the existing GitHub and GitLab paths.
Every command below was run on 2026-08-18 and its output is reproduced exactly.

Bitbucket **Cloud** is out of scope, and the parser refuses it rather than arming a watch against an endpoint that does not exist.
A cloud pull request URL carries no `projects/<key>/repos/<slug>` pair, and Bitbucket Cloud's API is a different version with a different credential.

## Versions

```
$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)

$ curl --version | head -1
curl 8.14.1 (x86_64-conda-linux-gnu) libcurl/8.14.1 OpenSSL/3.5.1 zlib/1.3.1
```

## Why the host is data rather than a constant

Bitbucket Server and Data Center are self-hosted only, so a pull request can live under any host.
The stored record therefore carries `provider`, `url`, `host`, `path`, and `number`, exactly as the GitLab record does, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct the stored URL.
Unlike GitLab, the path is always exactly two components, a project key and a repository slug, because that pair is how Bitbucket Server addresses a repository.
A personal project is spelled `~<user>`, so the leading tilde is accepted for the key and only there.

## URL parsing and canonicalization

The web UI appends a view segment to the URL a captain copies, so the parser accepts and drops it.
`FM_PR_URL` is the canonical form, and `bin/fm-pr-check.sh` records that rather than the raw input.

```
$ . bin/fm-pr-lib.sh
$ fm_pr_url_parse 'https://bitbucket.example/projects/DCC/repos/tools/pull-requests/193/overview' \
  && printf '%s | %s | %s | %s\n%s\n' \
     "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$FM_PR_URL"
bitbucket | bitbucket.example | DCC/tools | 193
https://bitbucket.example/projects/DCC/repos/tools/pull-requests/193

$ fm_pr_url_parse 'https://bitbucket.example/projects/~rpereira/repos/spike/pull-requests/7/diff' \
  && printf '%s | %s\n' "$FM_PR_PATH" "$FM_PR_URL"
~rpereira/spike
https://bitbucket.example/projects/~rpereira/repos/spike/pull-requests/7
```

Refused, each returning non-zero and setting no identity:

```
$ for u in \
  'https://bitbucket.org/team/repo/pull-requests/42' \
  'https://github.com/projects/K/repos/R/pull-requests/1' \
  'https://bitbucket.example/projects/K/repos/R/pull-requests/1?x=1' \
  'https://bitbucket.example/projects/K/repos/A/B/pull-requests/1' \
  'https://bitbucket.example/projects/K/repos/R.git/pull-requests/1'; do
    fm_pr_url_parse "$u" || printf 'REFUSED %s\n' "$u"
  done
REFUSED https://bitbucket.org/team/repo/pull-requests/42
REFUSED https://github.com/projects/K/repos/R/pull-requests/1
REFUSED https://bitbucket.example/projects/K/repos/R/pull-requests/1?x=1
REFUSED https://bitbucket.example/projects/K/repos/A/B/pull-requests/1
REFUSED https://bitbucket.example/projects/K/repos/R.git/pull-requests/1
```

The first row is the load-bearing one: `bitbucket.org` is a real host a captain could plausibly paste, and arming it as a Server watch would poll an endpoint that can never answer.

## How the state is read, and why without a JSON processor

`gh` reads one field with `--json state -q .state` and plain `glab` exposes a field-formatted `state:` line.
Bitbucket Server ships no CLI at all, so the state is read from REST API 1.0 with `curl`:

```
GET https://<host>/rest/api/1.0/projects/<key>/repos/<slug>/pull-requests/<number>
Authorization: Bearer <BITBUCKET_PAT>
```

`jq` is not one of firstmate's universally required tools, so the verdict does not parse JSON.
The response has its whitespace stripped and is then tested for the single exact token `"state":"MERGED"`.
Only that exact token wakes firstmate, so an error page, an authentication failure, a declined pull request, or a changed field produces no wake rather than a false merge.

The credential is never interpolated into the poll's bytes.
It is read at run time from `BITBUCKET_PAT`, or from the home's gitignored `.env` with `sed` rather than by sourcing it, so nothing in that file is ever executed.
The instance comes from the validated host in the stored record and never from a configured base URL, so a doctored record cannot redirect either the request or the token to another server.

## Behavior pinned by the regression suites

The watch, its refusals, and the merge are covered hermetically, with `curl` shimmed to reproduce the REST contract.

```
$ bash tests/fm-pr-check-security.test.sh 2>&1 | grep '^ok - Bitbucket'
ok - Bitbucket pull requests are followed on any instance and never wake falsely

$ bash tests/fm-pr-merge.test.sh 2>&1 | grep '^ok - fm-pr-merge: a\{0,1\}[n]\{0,1\} \{0,1\}[aB]'
ok - fm-pr-merge: a Bitbucket PR is merged through REST 1.0 with the version read first
ok - fm-pr-merge: an already merged, declined, or unreadable Bitbucket PR is refused before any merge
ok - fm-pr-merge: a Bitbucket merge that is not confirmed MERGED fails instead of assuming success
ok - fm-pr-merge: a Bitbucket merge refuses extra arguments and a missing credential
```

Those cases pin, in the watch: exact sidecar bytes, a single `merged` line for an exact merged state, silence for open, declined, lowercase `merged`, an authentication error body, an HTML error page, and an empty body, silence after a transport failure, the REST endpoint derived from the stored record, silence for a sidecar whose host or repository was swapped, the credential read from both the environment and the home's `.env`, silence with no credential at all, silence with `curl` absent from the whole search path, and the arming refusals for absent `curl` and absent token.

In the merge they pin: the version read before the merge, the merge carrying exactly that version, exactly one merge request sent, `pr=` recorded before merging, the GitHub CLI never reached, and a refusal with no merge sent for an already merged, declined, or unreadable-version pull request.

The credential cases deliberately `unset BITBUCKET_PAT` first.
A real token exported in a maintainer's shell would otherwise satisfy the environment lookup and make every no-credential case pass while asserting nothing.

## Why the merge reads the version first

REST API 1.0 requires the pull request's current `version` on the merge call:

```
POST https://<host>/rest/api/1.0/projects/<key>/repos/<slug>/pull-requests/<number>/merge?version=<n>
```

That value is Bitbucket's optimistic-lock token, so it is read immediately before the merge and passed straight back.
If the pull request changed between the read and the merge, the instance refuses the merge rather than merging a pull request that is no longer the one that was inspected.
It is taken as the first `"version"` in the response because Bitbucket serialises the pull request's own fields ahead of every nested object.

A merge is reported successful only when the response itself reports `"state":"MERGED"`.
Any other response, including a transport failure or a conflict body, is an error, so nothing is ever assumed merged.

## What this does not cover

A Bitbucket task records no `pr_head=`.
`gh` exposes the head commit as a selectable field, while Bitbucket Server exposes it only inside nested JSON, which would need the JSON processor firstmate does not require.
This is the same gap GitLab has, and both consumers already treat the field as optional: `bin/fm-teardown.sh` reads the head from the forge at teardown and falls back to its provider-agnostic content check, and `bin/fm-review-diff.sh` resolves the head from the remote when none is recorded.

## Live run against a real Bitbucket Server instance

Run on 2026-08-18 against a real Bitbucket Server instance over REST API 1.0 with a Personal Access Token.
The host, project key, and repository slug are redacted to `bb.example`, `KEY`, and `repo` because they name a private instance; the pull request numbers, field names, values, and orderings are reproduced exactly as returned.

The response confirms every shape this implementation depends on.
`state` is a top-level field carrying an uppercase value, and `version` is the SECOND key, ahead of every nested object, which is what makes taking the first `"version"` match correct:

```
$ curl -sS -H "Authorization: Bearer $BITBUCKET_PAT" -H 'Accept: application/json' \
    "https://bb.example/rest/api/1.0/projects/KEY/repos/repo/pull-requests/212" | head -c 160
{"id":212,"version":2,"title":"...","state":"OPEN","open":true,"closed":false,"draft":false,

top-level keys, in order:
['id', 'version', 'title', 'state', 'open', 'closed', 'draft', 'createdDate',
 'updatedDate', 'fromRef', 'toRef', 'locked', 'author', 'reviewers',
 'participants', 'links']
nested objects also containing a "version" key: []
```

Arming a real pull request records the canonical URL and the exact sidecar, and publishes a poll byte-identical to the shared program:

```
$ FM_HOME=$H env -u BITBUCKET_PAT bin/fm-pr-check.sh live1 \
    'https://bb.example/projects/KEY/repos/repo/pull-requests/212/overview'
armed: state/live1.check.sh

$ grep '^pr=' $H/state/live1.meta
pr=https://bb.example/projects/KEY/repos/repo/pull-requests/212

$ cat $H/state/live1.pr-poll
bitbucket
https://bb.example/projects/KEY/repos/repo/pull-requests/212
bb.example
KEY/repo
212

$ cmp -s bin/fm-pr-poll.sh $H/state/live1.check.sh && echo identical
identical
```

The credential lived only in `$H/.env`, and `BITBUCKET_PAT` was removed from the environment for every invocation below, so each one proves the `.env` read rather than an ambient token.

An open pull request produces no wake, and a genuinely merged one produces exactly one `merged` line:

```
$ env -u BITBUCKET_PAT bash $H/state/live1.check.sh      # PR 212, state OPEN
$ env -u BITBUCKET_PAT bash $H/state/live2.check.sh      # PR 211, state MERGED
merged
```

A sidecar whose host is swapped cannot redirect the live request, even with a real credential present:

```
$ printf 'bitbucket\n%s\nevil.example\nKEY/repo\n211\n' \
    'https://bb.example/projects/KEY/repos/repo/pull-requests/211' > $H/state/live2.pr-poll
$ env -u BITBUCKET_PAT bash $H/state/live2.check.sh
```

### The bug this live run found

The watcher does not run the published check by path.
It runs the shared program's `--validated` form (`bin/fm-watch.sh`), where there is no `state/<id>.check.sh` path for the poll to infer its home from, so the credential has to come from `FM_HOME`.
`bin/fm-watch.sh` assigned `FM_HOME` without exporting it, so that child saw no home, found no credential, and stayed silent - indistinguishable from a pull request that is never merged, with nothing reporting why.

Hermetic coverage missed it because those cases invoke the poll by its state path or with the variable already in the environment.
The live run exposed it immediately:

```
$ FM_HOME=$H env -u BITBUCKET_PAT bin/fm-pr-poll.sh --validated \
    bitbucket https://bb.example/projects/KEY/repos/repo/pull-requests/211 bb.example KEY/repo 211
merged
$ env -u BITBUCKET_PAT -u FM_HOME bin/fm-pr-poll.sh --validated \
    bitbucket https://bb.example/projects/KEY/repos/repo/pull-requests/211 bb.example KEY/repo 211
```

`bin/fm-watch.sh` now exports `FM_HOME`, and `tests/fm-pr-check-security.test.sh` pins the `--validated` form resolving its credential through `FM_HOME` in both the merged and open directions.

## What this does not cover

No merge has been executed against a live instance.
The merge path's inputs are verified live - the `version` field's presence, value, and position all come from the real response above - but the `POST .../merge?version=<n>` call itself has only hermetic coverage, because sending a real merge is not something a verification run may do.
Treat the merge response echoing `"state":"MERGED"` as the one remaining assumption, and refresh this record the first time a real Bitbucket task is merged through `bin/fm-pr-merge.sh`.
