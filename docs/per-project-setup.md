# Per-project setup

How to give one project its own first mate, in the layout where the home lives inside the project checkout rather than the project living inside the home.

This page is the procedure.
It does not restate the contracts it depends on: [`docs/configuration.md`](configuration.md) owns the home layout, the forge map, and the toolchain list, and each script's own `--help` and header own its exact flags and mechanics.

## When to use this layout

Use it when you want to open a project directory and have the fleet that serves it already be there.
Use the classic layout instead, where projects are cloned into one home's `projects/` directory, when you would rather run a single first mate across several projects at once.
Both layouts run the same scripts and the same state contracts, and one shared tracked clone can serve any number of per-project homes.

## Once per machine

Clone the shared code root and install the launcher.

```sh
git clone <your-firstmate-remote> ~/tools/firstmate
~/tools/firstmate/bin/fm-launch.sh alias
```

`alias` writes an `fm` shim into `~/.local/bin` by default, or into a directory you name.
It warns when that directory is not on `PATH`.

Then install the toolchain.
`docs/configuration.md`'s "Toolchain" section is the single owner of what is required; run a session start and let bootstrap tell you what is missing rather than installing from memory.
Two things about that list matter here.

Forge tooling is not universal.
A machine whose projects live only on Bitbucket or GitLab needs neither the GitHub CLI nor a GitHub login, and is never asked for one.

The runtime backend is resolved per home.
Only the backend a home actually uses is required, so a Herdr or Orca machine is never told to install tmux for the fleet to run.
Installing tmux is still worthwhile on a machine where you intend to run this repo's own test suite, because much of that suite exercises the tmux reference backend regardless of which backend you dispatch on.

## Once per project

```sh
cd <project>
fm init --mode <delivery-mode>
fm
```

`fm init` may be run from anywhere inside the checkout, including a nested subdirectory: it resolves the checkout's top level itself.
It refuses a directory that is not a git checkout, a linked worktree, and the shared clone itself, because a home in any of those cannot work.
It is idempotent, so rerunning it repairs a drifted home rather than complaining.

`fm` then starts the harness in that home.
Set `FM_LAUNCH_CMD` when the harness is not `claude`.

### Always pass an explicit mode

Omitting `--mode` seeds an entry that resolves to `no-mistakes`, the most rigorous path, which also expects the validation pipeline to be initialized in that project.
That is rarely what you want by accident, so state the mode you intend.

| mode | what a worker produces | fits |
| --- | --- | --- |
| `local-only` | a clean local branch, landed by the guarded local merge after your word | a project with no remote, or scratch work |
| `direct-PR` | a pushed branch and an open pull request, no validation pipeline | most day-to-day delivery |
| `no-mistakes` | the full validation pipeline, then a pull request | code you want gated before it lands |
| `no-mistakes-prod-only` | a per-task classification: product-facing work takes the pipeline, internal tooling takes the direct pull request | a repository that mixes both |

`--yolo on` additionally grants standing authority for routine approval decisions inside the request you already made.
It never grants merge authority, and never covers destructive, irreversible, or security-sensitive choices.
`AGENTS.md` section 7 owns those boundaries.

The posture lands as one line in the home's `data/projects.md`, in the format owned by `bin/fm-project-mode.sh`.
Change the posture later by editing that line.

### A credential, when the forge needs one

A project whose pull requests live on Bitbucket Server needs a Personal Access Token to follow and merge them.
Put it in the home's gitignored `.env`, which is also where the Relay pairing token lives.

```sh
printf 'BITBUCKET_PAT=%s\n' "$YOUR_TOKEN" > <project>/.firstmate/.env
chmod 600 <project>/.firstmate/.env
```

The environment is read first, so an exported token works for an interactive session.
Prefer the `.env` copy anyway: it is what keeps the merge watch working when a watcher runs outside the shell that exported the variable.

### A forge the host name does not identify

A self-hosted instance can be named anything, so an origin host that resolves to no known forge is reported as `FORGE_UNKNOWN` rather than guessed at.
Resolve it with one line in the home's `config/forge-map`.

```sh
echo 'git.example github' >> <project>/.firstmate/config/forge-map
```

`docs/configuration.md`'s "Forge map" section owns that file's format and resolution order.

## Confirm the setup took

Two checks, both worth running the first time.

```sh
fm status
```

It prints the resolved home, code root, project, name, and registered posture.
A wrong code root here means the home was created from a different clone; rerun `fm init` from the clone you intend to use.

Then confirm the first mate's own instructions actually loaded, by checking that its first reply addresses you as captain.
This check exists because the failure it catches is silent: the tracked hooks and the session-start digest can run correctly while the instruction surface fails to load, which produces a session that looks like a first mate and behaves like an ordinary agent.

Finally, confirm the project is untouched.

```sh
git -C <project> status --porcelain | grep firstmate
```

That must print nothing.
The home is hidden through the checkout's local `.git/info/exclude`, so no tracked ignore file is edited and nothing lands in the repository.

## Keeping homes current

One shared clone serves every home, so updating that clone updates all of them; `/updatefirstmate` performs the guarded update.
Each `fm` launch reconverges the home it enters, which is what refreshes the material copied into it from the shared clone.
There is no separate per-project update step.

## Retiring a home

Check first for worker branches that have not landed, because the home holds those task records.
Then remove the home directory and drop the `.firstmate/` line from the checkout's `.git/info/exclude`.
Removing a home does not touch the project's history or its branches.
