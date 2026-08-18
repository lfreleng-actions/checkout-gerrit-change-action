<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Gerrit Change Checkout Action

Checkout a mirrored Gerrit change.

## checkout-gerrit-change-action

[![pre-commit.ci status](https://results.pre-commit.ci/badge/github/lfit/checkout-gerrit-change-action/main.svg)](https://results.pre-commit.ci/latest/github/lfit/checkout-gerrit-change-action/main)

## Inputs

<!-- markdownlint-disable MD013 -->

| Name           | Required | Default                  | Description                                                                                                                                                |
| -------------- | -------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| gerrit-refspec | True     | N/A                      | The Gerrit refspec for the change, eg: refs/changes/YY/NNYY/Z                                                                                              |
| gerrit-project | True     | N/A                      | The project in Gerrit                                                                                                                                      |
| delay          | False    | 10s                      | Delay in seconds to wait to make sure replication has finished                                                                                             |
| fetch-depth    | False    | 1                        | Number of commits to fetch. 0 indicates all history for all branches and tags                                                                              |
| repository     | False    | ${{ github.repository }} | Repository name with owner. For example actions/checkout. Inside a reusable workflow the default names the caller; see [Checkout target](#checkout-target) |
| ref            | False    | ${{ github.sha }}        | The branch, tag or SHA to checkout. When checking out the repository that triggered a workflow, defaults to the reference/SHA for that event               |
| token          | False    | ${{ github.token }}      | Personal Access token (PAT) used to fetch the repository                                                                                                   |
| gerrit-url     | False    | ""                       | The base URL for the gerrit server; used when ref not found in the GitHub repository                                                                       |
| submodules     | False    | false                    | Whether to checkout submodules: `true` to checkout submodules or `recursive` to recursively checkout submodules                                            |

<!-- markdownlint-enable MD013 -->

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

## Usage

```yaml
- uses: lfit/checkout-gerrit-change-action@v0.5
  with:
      # The Gerrit refspec for the change, eg: refs/changes/YY/NNYY/Z
      gerrit-refspec: "refs/changes/40/11540/1"

      # Delay in seconds to wait to make sure replication has finished
      #
      # Default: 10s
      delay: "10s"

      # Number of commits to fetch. 0 indicates all history for all branches
      # and tags.
      #
      # Default: 1
      fetch-depth: "1"

      # Repository name with owner. For example, lfit/checkout-gerrit-change-action
      #
      # Default: ${{ github.repository }}
      repository: ${{ github.repository }}

      # The branch, tag or SHA to checkout. When Checking out the repository
      # that triggered a workflow, this defaults to the reference or SHA for that
      # event. Otherwise, uses the default branch.
      ref: ${{ github.sha }}

      # Personal Access token (PAT) used to fetch the repository. The PAT is
      # configured with the local git config, which enables your scripts to run
      # authenticated git commands. The post-job step removes the PAT.
      #
      # We recommend using a service account with the least permissions necessary.
      # Also, when generating a new PAT, select the least scopes necessary.
      #
      # Default:
      token: ${{ github.token }}

      # The base URL for the gerrit server. Used if the ref can't be
      # found in the GitHub repository
      gerrit-url: ${{ vars.GERRIT_URL }}

      # Whether to checkout submodules: `true` to checkout submodules or
      # `recursive` to recursively checkout submodules.
      #
      # Default: false
      submodules: "false"
```
