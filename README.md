<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# Gerrit Change Checkout Action

Checkout a mirrored Gerrit change.

## checkout-gerrit-change-action

[![pre-commit.ci status](https://results.pre-commit.ci/badge/github/lfit/checkout-gerrit-change-action/main.svg)](https://results.pre-commit.ci/latest/github/lfit/checkout-gerrit-change-action/main)

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
