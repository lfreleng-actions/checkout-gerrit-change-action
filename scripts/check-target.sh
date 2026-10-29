# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# shellcheck shell=bash
#
# Warn when the checkout target contradicts the Gerrit project.
#
# The check-target step in action.yaml sources this file, so it runs
# in the step's own shell, bash with -e and -o pipefail. Inputs reach
# it through the environment the step sets.

# Warn when the checkout target contradicts the Gerrit project
set -eu

# Nothing to compare against, or the caller named a repository
# deliberately, so say nothing.
if [ -z "$INPUT_REPOSITORY" ] || [ -z "$INPUT_GERRIT_PROJECT" ] ||
   [ "$INPUT_REPOSITORY" != "$CALLER_REPOSITORY" ]
then
  exit 0
fi

# Mirrors flatten the Gerrit path and sometimes gain an
# 'archive-' prefix: aai/aai-common -> onap/aai-aai-common,
# aaf/inno -> onap/archive-aaf-inno. Match on that shape.
project=$(printf '%s' "$INPUT_GERRIT_PROJECT" \
  | tr '/' '-' | tr '[:upper:]' '[:lower:]')
name=$(printf '%s' "${INPUT_REPOSITORY#*/}" | tr '[:upper:]' '[:lower:]')

case "$name" in
  "$project" | *"-$project") exit 0 ;;
esac

# Rebuild the expression hint from a variable, so the literal text
# of a workflow expression never appears in this file or the action.
d='$'
fix="repository: ${d}{{ inputs.repository || github.repository }}"

# Fold CR and LF into visible escapes before either value
# reaches the log. A raw newline would otherwise start a fresh
# log line, and the runner reads a line beginning '::' as a
# workflow command, so escaping the annotation alone leaves the
# console output as an injection path.
show_repository=$INPUT_REPOSITORY
show_repository=${show_repository//$'\r'/'\r'}
show_repository=${show_repository//$'\n'/'\n'}
show_project=$INPUT_GERRIT_PROJECT
show_project=${show_project//$'\r'/'\r'}
show_project=${show_project//$'\n'/'\n'}

printf '%s\n' \
  'Gerrit checkout target mismatch' \
  '' \
  "  repository:     $show_repository (defaulted to the caller)" \
  "  gerrit-project: $show_project" \
  '' \
  "'github.repository' names the calling workflow, not the project" \
  'under review. Name the target on the step calling this action:' \
  '' \
  "    $fix"

# Escape workflow-command metacharacters before emitting the
# annotation. The folding above removes CR and LF, so this
# mainly guards '%', but keep all three to match the error path
# below. Escape '%' first to avoid double-escaping.
annotation="Checking out '$show_repository' for Gerrit project"
annotation="$annotation '$show_project'."
annotation="$annotation Add '$fix' to the step calling this action."
annotation=${annotation//'%'/'%25'}
annotation=${annotation//$'\r'/'%0D'}
annotation=${annotation//$'\n'/'%0A'}
echo "::warning title=Gerrit checkout target mismatch::$annotation"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]
then
  {
    echo '### Gerrit checkout target mismatch'
    echo
    echo "Checking out \`$show_repository\` (defaulted to the" \
      "calling workflow) for Gerrit project" \
      "\`$show_project\`."
    echo
    # The backticks open a Markdown code span in the job summary; they
    # are not command substitution.
    # shellcheck disable=SC2016
    echo '`github.repository` names the calling workflow, not the'
    echo 'project under review. Name the target on the step calling'
    echo 'this action:'
    echo
    echo '```yaml'
    echo "  $fix"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi
