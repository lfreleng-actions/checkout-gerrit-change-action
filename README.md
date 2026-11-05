<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Gerrit Change Checkout Action

Checkout a Gerrit change, from its GitHub mirror or, when the project has
no mirror, directly from Gerrit. With no change to check out, the action
checks out the repository as `actions/checkout` does, so one step serves
Gerrit and GitHub-native runs alike; see [Modes](#modes).

## checkout-gerrit-change-action

[![pre-commit.ci status](https://results.pre-commit.ci/badge/github/lfit/checkout-gerrit-change-action/main.svg)](https://results.pre-commit.ci/latest/github/lfit/checkout-gerrit-change-action/main)

## Inputs

<!-- markdownlint-disable MD013 -->

| Name                | Required | Default                  | Description                                                                                                                                                                                    |
| ------------------- | -------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| gerrit-refspec      | False    | ""                       | The Gerrit refspec for the change, eg: refs/changes/YY/NNYY/Z. Empty selects plain mode; see [Modes](#modes)                                                                                   |
| gerrit-project      | False    | ""                       | The project in Gerrit. Recommended in Gerrit mode, and required when Gerrit serves the change; see [Modes](#modes). Plain mode ignores it                                                      |
| gerrit-branch       | False    | ""                       | In Gerrit mode, when set, the action checks out `refs/heads/<gerrit-branch>` before fetching the change, in place of `ref`. Ignored in plain mode                                              |
| delay               | False    | 10s                      | Delay to wait for replication to the GitHub mirror; not applied in plain mode, nor when the change comes from Gerrit because the project has no mirror                                         |
| fetch-depth         | False    | 2                        | Number of commits to fetch, in both modes. 0 indicates all history for all branches and tags                                                                                                   |
| fetch-tags          | False    | false                    | Whether to fetch tags, even when `fetch-depth` > 0. Passed to `actions/checkout`; the [Gerrit fallback](#projects-without-a-mirror) ignores it                                                 |
| filter              | False    | ""                       | Partially clone against a given filter, eg: `blob:none`. Passed to `actions/checkout`; the [Gerrit fallback](#projects-without-a-mirror) ignores it                                            |
| repository          | False    | ${{ github.repository }} | Repository name with owner. For example actions/checkout. Inside a reusable workflow the default names the caller; see [Checkout target](#checkout-target)                                     |
| ref                 | False    | ""                       | The branch, tag or SHA to checkout. Empty: `actions/checkout` chooses, except Gerrit mode uses `github.sha` for the calling repository. See [Modes](#modes). With no mirror, SHAs do not apply |
| token               | False    | ${{ github.token }}      | Personal Access token (PAT) used to fetch the repository                                                                                                                                       |
| persist-credentials | False    | true                     | Whether to leave `token` in the local git config. See [Credentials](#credentials)                                                                                                              |
| gerrit-url          | False    | ""                       | The base URL for the gerrit server; used when ref not found in the GitHub repository, or the repository does not exist. See [Projects without a mirror](#projects-without-a-mirror)            |
| on-unavailable      | False    | fail                     | With no mirror, when Gerrit answers an anonymous request with HTTP 401: `fail`, or `skip` the checkout. See [Projects without a mirror](#projects-without-a-mirror)                            |
| submodules          | False    | false                    | Whether to checkout submodules: `true` to checkout submodules or `recursive` to recursively checkout submodules. See [Submodules](#submodules)                                                 |

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Name        | Description                                                                                                                                                                                   |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| checked-out | `true` once the action checks out the change, or in plain mode the repository; otherwise `false`: when `on-unavailable: skip` skipped it, or when the action failed under `continue-on-error` |
| mode        | `gerrit` when `gerrit-refspec` holds a refspec, `plain` when empty                                                                                                                            |

<!-- markdownlint-enable MD013 -->

## Modes

The action runs in one of two modes, chosen by `gerrit-refspec`:

- **Gerrit mode**, with `gerrit-refspec` set: the action checks out
  the change, as the rest of this document describes. Pass
  `gerrit-project` always: a change the mirror serves needs none, but
  when Gerrit has to serve it, because the project has no mirror or the
  mirror lacks the change and the action falls back to `gerrit-url`,
  the action fails naming the input without it.
- **Plain mode**, with `gerrit-refspec` empty: the action runs
  `actions/checkout` once, checking out `repository` at `ref` with
  `token`, `fetch-depth`, `fetch-tags`, `filter`, `submodules` and
  `persist-credentials`. It skips each step that serves Gerrit (the target
  check, the mirror probe, the `delay`, the Gerrit fetch and the mirror
  diagnosis) and ignores `gerrit-project`, `gerrit-branch`, `gerrit-url`,
  `delay` and `on-unavailable`, so a workflow can pass them whatever
  the mode.

`fetch-depth` defaults to 2 in both modes: one commit more than
`actions/checkout` fetches, which keeps the parent of HEAD reachable.

The `mode` output names the mode the action ran in.

A job that checks out source for Gerrit and GitHub-native runs alike
then needs one step, where it would otherwise pair this action and
`actions/checkout` under opposite conditions:

<!-- markdownlint-disable MD013 -->

```yaml
- name: 'Checkout'
  uses: lfreleng-actions/checkout-gerrit-change-action@<sha>
  with:
    gerrit-refspec: ${{ inputs.gerrit_refspec }}
    gerrit-project: ${{ inputs.gerrit_project }}
    gerrit-branch: ${{ inputs.gerrit_branch }}
    gerrit-url: ${{ inputs.gerrit_url != '' && inputs.gerrit_url || vars.GERRIT_URL }}
    delay: '0s'
    repository: ${{ inputs.repository || github.repository }}
    ref: ${{ inputs.ref }}
    persist-credentials: false
```

<!-- markdownlint-enable MD013 -->

`gerrit-branch` lets the step pass the caller's `ref` unchanged: in
Gerrit mode the action checks out `refs/heads/<gerrit-branch>` before
fetching the change, in place of `ref`, and in plain mode it checks out
`ref`. With `gerrit-branch` empty, Gerrit mode uses `ref`.

An empty `ref` behaves as `actions/checkout` does in plain mode: the
action passes it on empty, and `actions/checkout` checks out the
triggering commit for the calling repository and the default branch
for any other. Gerrit mode, with `ref` and `gerrit-branch` both empty,
uses `github.sha` when `repository` names the calling repository (in
any letter case), as it always has. For any other repository it passes
`ref` on empty, as plain mode does, so `actions/checkout` checks out
that repository's default branch and the action fetches the change on
top: an explicit `ref: ''` there behaves as it did in v1.3.0.

One case differs from v1.3.0, which defaulted `ref` to `github.sha`
whatever the `repository`: a Gerrit-mode call naming another repository
and omitting `ref` asked that repository for a commit it does not hold,
and failed. It now succeeds, from the default branch.

## Credentials

`persist-credentials` defaults to `true`, as in `actions/checkout`.

- Plain mode passes it to `actions/checkout`.
- Gerrit mode persists the `token` while it fetches the change, which
  needs it. With `persist-credentials: false`, the action then removes
  what `actions/checkout` stored, from the repository and every
  submodule, once the checkout has started, even if it or the fetch
  fails or someone cancels the run, leaving no credential in the clone.
  A job needs no separate step to remove them. The
  action clears the repository first and finds submodules from the
  clone's git directory, not from `.gitmodules`, so a change that
  breaks that file cannot keep a credential in place. It recognises
  Windows paths under `RUNNER_TEMP` in either slash style and any
  letter case, and needs no Git newer than the 2.18 that
  `actions/checkout` itself requires.

The [Gerrit fallback](#projects-without-a-mirror) never writes the
`token` to the git config, whatever this input says.

## Checkout target

The `repository` input defaults to `github.repository`, which names the
repository hosting the workflow run. Inside a reusable workflow that is the
caller, not the project under review. A central `.github` repository running
checks for another project must name the target:

```yaml
- uses: lfreleng-actions/checkout-gerrit-change-action@v1.0.2
  with:
      gerrit-refspec: ${{ inputs.gerrit_refspec }}
      gerrit-project: ${{ inputs.gerrit_project }}
      gerrit-url: ${{ vars.GERRIT_URL }}
      repository: ${{ inputs.repository || github.repository }}
      ref: refs/heads/${{ inputs.gerrit_branch }}
```

Omitting `repository` while passing `ref` points the checkout at a branch the
caller may not carry, which fails with `couldn't find remote ref`. Where the
branch names happen to match, the checkout succeeds against the wrong code.

When the checkout repository disagrees with `gerrit-project`, this action
writes a warning to the log and the job summary before it checks anything out.

## Projects without a mirror

Not every Gerrit project replicates to GitHub. Before checking anything
out, the action asks the GitHub API whether `repository` exists, unless
`repository` is the repository running the workflow. When the API
answers 404 and the caller supplies `gerrit-url`, the action skips the
mirror and checks the change out from `gerrit-url`/`gerrit-project`
instead. Any other answer from the API, an outage included, keeps the
mirror path.

The action asks Gerrit for the project and the change before touching
the workspace. Once Gerrit serves the change, and not before, it clears
the workspace and checks the change out, leaving what the mirror path
would:

- `fetch-depth: 0` fetches every branch and tag, as `origin/<branch>`
  and `refs/tags/*`, then the change with its full history.
- Otherwise, a `ref` naming a branch (`refs/heads/<branch>`) fetches
  that branch as `origin/<branch>` at `fetch-depth`, then the change at
  the same depth. A `ref` naming a commit, such as the `github.sha`
  default, fetches the change alone, since Gerrit does not hold the
  caller's commits.
- `submodules` behaves as before, and the action marks the workspace
  as a git `safe.directory`, as `actions/checkout` does. For submodules
  hosted on GitHub it supplies what `actions/checkout` would: SSH URLs
  rewritten to HTTPS, and `token` as a header scoped to the GitHub
  server. Both live in the step's environment alone, so neither
  reaches `.git/config` nor outlives the step, and Gerrit never sees
  the token.
- `fetch-tags` and `filter` do not apply: the fallback fetches tags
  for `fetch-depth: 0` alone, and fetches complete objects.
- Credentials embedded in `gerrit-url` (`https://user:pass@host/`)
  authenticate the requests to Gerrit but stay out of `.git/config`:
  `origin` holds the URL without them.

The `delay` for replication does not apply.

Without credentials in `gerrit-url`, the action reaches Gerrit
anonymously. Gerrit answers HTTP 401 for a project that refuses
anonymous reads, and `on-unavailable` decides the outcome there:

- `fail` (the default) fails the step, naming the project.
- `skip` leaves the workspace as it found it, sets the `checked-out`
  output to `false`, and explains the skip in a notice and the job
  summary.

Everything else Gerrit refuses fails the step whatever `on-unavailable`
says, because skipping would pass a check on a configuration error:

- HTTP 403 or 404. Gerrit answers these for a hidden project and for a
  misspelt `gerrit-project` alike.
- HTTP 401 to credentials in `gerrit-url`, which means they are wrong.
- A network error, or a change the project does not hold.

In every case where Gerrit does not serve the change, the workspace
keeps whatever earlier steps put there.

With `skip`, gate the steps that need the tree on the output:

```yaml
- id: checkout
  uses: lfreleng-actions/checkout-gerrit-change-action@<sha>
  with:
      gerrit-refspec: ${{ inputs.gerrit_refspec }}
      gerrit-project: ${{ inputs.gerrit_project }}
      gerrit-url: ${{ vars.GERRIT_URL }}
      repository: ${{ inputs.repository }}
      ref: refs/heads/${{ inputs.gerrit_branch }}
      on-unavailable: skip
- name: Run the checks
  if: steps.checkout.outputs.checked-out == 'true'
  run: make verify
```

A private mirror that `token` cannot see also answers 404, so the action
fetches from Gerrit in that case too.

### Limitations

- `skip` applies to HTTP(S) Gerrit URLs alone: other schemes report no
  status to tell a closed project from a misconfigured one, so any
  failure there fails the step.
- On the fallback, `gerrit-url` and `gerrit-project` must not contain
  control characters; the step fails on them.
- Unless `gerrit-url` carries credentials, a hosted runner reaches the
  projects that Gerrit serves anonymously and no others.
- The fallback costs Gerrit round-trips the mirror path does not: one
  to read the project's status, one to find the change, then the
  fetches. `fetch-depth: 0` clones the project's full history from
  Gerrit.
- A composite action has no post step, so the `safe.directory` entry the
  fallback adds to the global git configuration stays after the job,
  where `actions/checkout` removes its own. On a self-hosted runner,
  that leaves one entry per workspace path.
- Callers gain the fallback when they move their pin to a release
  carrying it, and must set `on-unavailable: skip` to skip.
- Gerrit does not replicate private change refs, so a mirror never
  holds a private change and the mirror path cannot check one out. See
  [When the mirror is the problem](#when-the-mirror-is-the-problem).

## When the mirror is the problem

git reports a change or branch the mirror lacks as `couldn't find remote
ref`, whatever the reason. Once the action has failed on the mirror
path, a last step reads the state of the mirror, through the GitHub API
and `git ls-remote`, and explains it in one annotation and one line of
the job summary:

<!-- markdownlint-disable MD013 -->

| State                                         | Message                                                                                                                  | Who acts                                                                              |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| Not found, or not visible, with no gerrit-url | The repository was not found, or is private and not visible to `token`, and with no `gerrit-url` Gerrit cannot serve it  | The caller: set `gerrit-url`, check `repository`, or pass a `token` that can read it  |
| Archived                                      | Replication cannot update an archived mirror, so the change will never arrive                                            | LF Releng or the project's administrators                                             |
| Empty                                         | The mirror has no branches: replication has not populated it                                                             | LF Releng: replication, and the project's read grant for the GitHub Replication group |
| Branch missing                                | The mirror has no branch, or for a bare name no tag either, named by `ref`                                               | The caller, through `ref`; or the project, for a new branch                           |
| Change ref missing                            | The mirror has branches but not the change: replication may lag behind `delay` or have stalled, or the change is private | Retry; if it persists, LF Releng. Nothing replicates a private change                 |
| Cannot tell                                   | The step could not read the state, and names the HTTP status, the failed command, or the unread archive state            | Nobody: the step claims no cause without evidence                                     |

<!-- markdownlint-enable MD013 -->

With `gerrit-url` set, the probe sends a missing mirror to Gerrit. The
step reports one there when the probe could not tell, or when
`repository` names the calling repository, and asks the caller to check
`repository` and `token`.

Gerrit does not replicate private change refs, so a private change never
reaches the mirror, whatever the `delay`.

A mirror that is empty or archived is not the fault of the change or of
the workflow calling the action. The step:

- runs after a failure and never otherwise, so a successful run makes
  no extra request;
- does not run where the change came from Gerrit because the mirror
  does not exist, since that path explains its own failures;
- says nothing when the mirror looks healthy, populated and holding the
  change, since the failure then lies elsewhere; when the GitHub API's
  answer leaves the archive state unreadable, anything but a body
  holding one JSON object whose `archived` is `true` or `false`, it
  says it cannot tell rather than fall silent;
- never changes the outcome, and makes one attempt of at most 10 seconds
  per request, three requests at most; a git command still running then
  gets TERM, along with its HTTP transport and anything else it started,
  and any of them still running a second later gets KILL;
- checks the branch when `ref` names it in letters, digits, `.`, `_`,
  `-` and `/`, so that the message can show it, and makes no claim
  about a branch with any other name;
- builds every message from fixed text and the inputs, never from what
  the server sends, and keeps `token` off the command line.

## Parent commit guarantee

The action guarantees that the checked-out change commit's parent is
reachable, so parent-relative operations such as `git diff HEAD~1` are
safe for consumers. Two mechanisms enforce this invariant:

- `fetch-depth` defaults to `2`, covering the change commit and its
  parent.
- When the working repository is shallow, the action applies the
  requested `fetch-depth` to the change refspec fetch as well. Without
  this, the fetch inherits the shallow boundary and can graft away the
  parent — for example when the change has already merged and the
  branch tip is the change commit itself.

A full clone (`fetch-depth: 0`) is never truncated. Setting
`fetch-depth: 1` restores the old behavior and breaks the guarantee.

## Submodules

With `submodules: true` or `recursive`, the action moves submodules to the
commits the Gerrit change records, not the branch tip:

- a submodule the change moves checks out at its new commit;
- a submodule the change adds gets populated;
- a submodule URL the change edits in `.gitmodules` becomes the URL git
  fetches from;
- a submodule the change removes, or replaces with tracked files, leaves
  no working tree behind for later steps to scan;
- `recursive` does the same for nested submodules, one level at a time.

The action deinitialises a removed submodule rather than deleting its
repository, which stays under `.git/modules`, as `git submodule deinit`
leaves it. With `submodules: false` the action leaves submodules alone,
including any that an earlier step populated.

`actions/checkout` stores the `token` credentials in each submodule it
populates from the branch tip. A submodule that the change adds did not
exist then, so git clones it without those credentials. When it names a
private repository, the clone fails and the action reports the failure
rather than leaving the submodule empty.

## Usage

```yaml
- uses: lfit/checkout-gerrit-change-action@v0.5
  with:
      # The Gerrit refspec for the change, eg: refs/changes/YY/NNYY/Z.
      # Empty selects plain mode, a checkout of `repository` at `ref`.
      #
      # Default: ""
      gerrit-refspec: "refs/changes/40/11540/1"

      # The project in Gerrit; recommended in Gerrit mode, and required
      # when Gerrit, not the mirror, serves the change
      #
      # Default: ""
      gerrit-project: "releng/builder"

      # In Gerrit mode, when set, check out refs/heads/<gerrit-branch>
      # before fetching the change, in place of `ref`
      #
      # Default: ""
      gerrit-branch: "master"

      # Delay in seconds to wait to make sure replication has finished
      #
      # Default: 10s
      delay: "10s"

      # Number of commits to fetch. 0 indicates all history for all branches
      # and tags. The default of 2 keeps the change commit's parent
      # reachable for parent-relative diffs.
      #
      # Default: 2
      fetch-depth: "2"

      # Whether to fetch tags, even when fetch-depth > 0
      #
      # Default: false
      fetch-tags: "false"

      # Partially clone against a given filter, eg: blob:none
      #
      # Default: ""
      filter: ""

      # Repository name with owner. For example, lfit/checkout-gerrit-change-action
      #
      # Default: ${{ github.repository }}
      repository: ${{ github.repository }}

      # The branch, tag or SHA to checkout. Empty, plain mode checks out the
      # reference or SHA for the event when checking out the repository that
      # triggered a workflow, otherwise the default branch; Gerrit mode, with
      # no gerrit-branch, checks out github.sha for the repository that
      # triggered the workflow, and behaves as plain mode for any other.
      #
      # Default: ""
      ref: ""

      # Personal Access token (PAT) used to fetch the repository. The PAT is
      # configured with the local git config, which enables your scripts to run
      # authenticated git commands. The post-job step removes the PAT.
      #
      # We recommend using a service account with the least permissions necessary.
      # Also, when generating a new PAT, select the least scopes necessary.
      #
      # Default:
      token: ${{ github.token }}

      # Whether to leave the token in the local git config. With false,
      # Gerrit mode removes it once it has fetched the change.
      #
      # Default: true
      persist-credentials: "true"

      # The base URL for the gerrit server. Used if the ref can't be
      # found in the GitHub repository, or the repository does not exist
      gerrit-url: ${{ vars.GERRIT_URL }}

      # With no GitHub mirror and no anonymous access to the Gerrit
      # project: `fail`, or `skip` the checkout and set the
      # `checked-out` output to `false`
      #
      # Default: fail
      on-unavailable: "fail"

      # Whether to checkout submodules: `true` to checkout submodules or
      # `recursive` to recursively checkout submodules.
      #
      # Default: false
      submodules: "false"
```

## Development

The logic of each step lives in `scripts/`. The first step copies the
scripts to `RUNNER_TEMP`, because a caller running the action from its
own checkout (`uses: ./`) has it inside the workspace, which
`actions/checkout` clears. Each later step sources its script from that
copy, in the step's own shell, so each script keeps the options the
runner gives that step. The test suites read each step's `shell:` and
`run:` from `action.yaml` and run them as the runner would, against
local repositories and a loopback stub server, so they need no network
access:

```sh
bash tests/submodule-refresh.sh
bash tests/gerrit-fallback.sh
bash tests/mirror-diagnosis.sh
bash tests/plain-mode.sh
```

They need `git`, with `git http-backend`, and `python3`.
