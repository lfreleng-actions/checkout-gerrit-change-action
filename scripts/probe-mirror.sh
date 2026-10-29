# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# shellcheck shell=bash
#
# Validate on-unavailable, and ask the GitHub API whether the mirror
# exists.
#
# The probe-mirror step in action.yaml sources this file, so it runs
# in the step's own shell, bash with -e and -o pipefail. Inputs reach
# it through the environment the step sets.

# Check whether the GitHub mirror exists
set -euo pipefail

# Validate on-unavailable here, where every run passes, rather
# than in the fallback, so a typo fails before a mirror goes
# missing rather than after. Trim and case-fold it the way
# actions/checkout reads its inputs.
on_unavailable=$(printf '%s' "$INPUT_ON_UNAVAILABLE" |
  tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
case "$on_unavailable" in
  fail | skip) ;;
  *)
    shown=${INPUT_ON_UNAVAILABLE//'%'/'%25'}
    shown=${shown//$'\r'/'%0D'}
    shown=${shown//$'\n'/'%0A'}
    echo "::error::Invalid on-unavailable input: '$shown' (expected fail or skip)"
    exit 1
    ;;
esac
echo "on-unavailable=$on_unavailable" >> "$GITHUB_OUTPUT"

mirror=present
# The name goes into a URL and the log, so accept only the
# owner/name shape; actions/checkout rejects anything else. A
# '.' or '..' segment would let curl resolve the path to some
# other endpoint, whose 404 would then read as a missing mirror.
if [ -n "$INPUT_GERRIT_URL" ] &&
   [ "$INPUT_REPOSITORY" != "$CALLER_REPOSITORY" ] &&
   [[ "$INPUT_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] &&
   [[ ! "$INPUT_REPOSITORY" =~ (^|/)\.\.?(/|$) ]]
then
  # The token reaches curl on stdin, as configuration, which
  # keeps it out of the process list. A private mirror the
  # token cannot see also answers 404, and Gerrit then serves
  # the change instead. Every caller pays for this request, so
  # bound it tightly: one retry, ten seconds.
  status=$(
    if [ -n "$INPUT_TOKEN" ]
    then
      printf 'header = "Authorization: Bearer %s"\n' "$INPUT_TOKEN"
    fi |
      curl --config - --silent --output /dev/null \
        --write-out '%{http_code}' --retry 1 --max-time 10 \
        --header 'Accept: application/vnd.github+json' \
        -- "$API_URL/repos/$INPUT_REPOSITORY"
  ) || status=000
  if [ "$status" = 404 ]
  then
    mirror=absent
    echo "GitHub repository $INPUT_REPOSITORY not found;" \
      'checking the change out from Gerrit instead'
  fi
fi
echo "mirror=$mirror" >> "$GITHUB_OUTPUT"
