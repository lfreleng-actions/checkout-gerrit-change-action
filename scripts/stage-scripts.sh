# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# shellcheck shell=bash
#
# Copy the step scripts out of the action's directory, before any step
# can replace the workspace.
#
# A workflow that runs this action from its own checkout (uses: ./)
# finds the action, scripts included, inside the workspace, which
# actions/checkout clears when it checks out another repository. The
# runner reads an inline 'run:' before the job starts, but a sourced
# script only when its step runs, so a step after the checkout would
# find its script gone. Every later step sources the copy made here, in
# a directory of its own under RUNNER_TEMP, which the runner empties
# after each job.
#
# The stage-scripts step in action.yaml sources this file, so it runs
# in the step's own shell, bash with -e and -o pipefail.

staged=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/checkout-gerrit-change.XXXXXX")
cp -- "$GITHUB_ACTION_PATH"/scripts/*.sh "$staged"/
echo "dir=$staged" >> "$GITHUB_OUTPUT"
