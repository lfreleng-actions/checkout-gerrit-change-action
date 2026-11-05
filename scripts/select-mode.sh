# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# shellcheck shell=bash
#
# Choose between Gerrit mode and plain mode, and settle the inputs the
# later steps share.
#
# An empty gerrit-refspec selects plain mode: the action checks out
# 'repository' at 'ref' as actions/checkout does, and every Gerrit-only
# step skips. Any other value selects Gerrit mode, gerrit-project or
# not: only the steps that fetch the change from Gerrit itself need it,
# and they say so when they do. Outputs:
#
#   mode                 gerrit or plain
#   ref                  what actions/checkout checks out: in Gerrit
#                        mode refs/heads/<gerrit-branch> when that is
#                        set, otherwise 'ref', or DEFAULT_REF (the
#                        triggering commit) when 'ref' is empty; in
#                        plain mode 'ref' as given, empty included, so
#                        actions/checkout picks the event's ref for
#                        the calling repository and the default branch
#                        for another. Either way 'ref' is first trimmed
#                        of surrounding ASCII whitespace, as
#                        actions/checkout trims it, so a YAML folded
#                        scalar's trailing newline passes
#   persist-credentials  true or false, read as actions/checkout reads
#                        it: trimmed, and true in any letter case
#
# The select-mode step in action.yaml sources this file, so it runs in
# the step's own shell, bash with -e and -o pipefail. Inputs reach it
# through the environment the step sets.

set -euo pipefail

# Strip leading and trailing ASCII whitespace, line breaks included,
# and keep any inside the value
trim()
{
  local ws=$' \t\n\v\f\r' value=$1
  value=${value#"${value%%[!"$ws"]*}"}
  printf '%s' "${value%"${value##*[!"$ws"]}"}"
}

# Escape workflow-command metacharacters, '%' first to avoid
# double-escaping, so a value cannot break or inject an annotation.
escape()
{
  local value=${1//'%'/'%25'}
  value=${value//$'\r'/'%0D'}
  printf '%s' "${value//$'\n'/'%0A'}"
}

persist=$(trim "$INPUT_PERSIST_CREDENTIALS" | tr '[:upper:]' '[:lower:]')
if [ "$persist" != true ]
then
  persist=false
fi

ref=$(trim "$INPUT_REF")
if [ -z "$(trim "$INPUT_GERRIT_REFSPEC")" ]
then
  mode=plain
else
  mode=gerrit
  branch=$(trim "$INPUT_GERRIT_BRANCH")
  if [ -n "$branch" ]
  then
    ref="refs/heads/$branch"
  elif [ -z "$ref" ]
  then
    ref=$DEFAULT_REF
  fi
fi

# The ref goes into GITHUB_OUTPUT one line per key, where a CR or LF
# would end the value and start a key of its own. No git ref holds one,
# and trimming has removed any around the value, so one left is inside.
if [[ "$ref" == *[$'\r\n']* ]]
then
  echo "::error::Invalid ref: '$(escape "$ref")' (contains a line break)"
  exit 1
fi

echo "Checkout mode: $mode"
{
  echo "mode=$mode"
  echo "ref=$ref"
  echo "persist-credentials=$persist"
} >> "$GITHUB_OUTPUT"
