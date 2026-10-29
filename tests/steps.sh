# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# shellcheck shell=bash
#
# Run a step of action.yaml the way the runner does, without a YAML
# parser. Each step that holds logic carries a one-line 'run:' that
# sources its script; this reads that line and the step's 'shell:' out
# of action.yaml, so a suite exercises exactly what the action
# executes, options included.
#
# The stage-scripts step sources scripts/stage-scripts.sh from the
# action's directory and copies the scripts to a directory of their
# own; every later step sources its script from that copy, through
# SCRIPTS_DIR.
#
# Source it from a suite that sets REPO_ROOT and WORK, then call
# stage_scripts once, as the action runs that step first, and
# step_command for each step under test.

# Print the value of key $2 ('shell' or 'run') in the step with id $1:
# the text after 'key: ' on the line at step depth, up to the next step.
step_field() {
  awk -v id="$1" -v key="$2" '
    /^    - / { in_step = ($0 == "    - id: " id) ; next }
    in_step && index($0, "      " key ": ") == 1 {
      print substr($0, length("      " key ": ") + 1)
      exit
    }
  ' "$REPO_ROOT/action.yaml"
}

# Set STEP_CMD to the command line the runner builds for step $1: its
# 'run:' text written to $WORK/$1.run, in place of '{0}' in its shell.
# The runner expands the 'bash' keyword as below; see
# src/Runner.Worker/Handlers/ScriptHandlerHelpers.cs in actions/runner.
step_command() {
  local id="$1" run shell i want
  run="$(step_field "$id" run)"
  if [ "$id" = stage-scripts ]; then
    want="source \"\$GITHUB_ACTION_PATH/scripts/$id.sh\""
  else
    want="source \"\$SCRIPTS_DIR/$id.sh\""
  fi
  if [ "$run" != "$want" ]; then
    echo "Step $id in action.yaml must run: $want" \
      "(found: ${run:-nothing})" >&2
    return 1
  fi
  printf '%s\n' "$run" > "$WORK/$id.run"
  shell="$(step_field "$id" shell)"
  case "$shell" in
    bash) shell='bash --noprofile --norc -e -o pipefail {0}' ;;
    *'{0}'*) ;;
    *)
      echo "Unsupported shell for $id: ${shell:-none}" >&2
      return 1
      ;;
  esac
  read -ra STEP_CMD <<< "$shell"
  for i in "${!STEP_CMD[@]}"; do
    if [ "${STEP_CMD[i]}" = '{0}' ]; then
      STEP_CMD[i]="$WORK/$id.run"
    fi
  done
}

# Run the stage-scripts step as the action runs it first: with
# GITHUB_ACTION_PATH naming the action's directory and RUNNER_TEMP a
# directory of its own. Export SCRIPTS_DIR, the copy it made, for the
# steps that source from it, as action.yaml passes them its output.
stage_scripts() {
  local out="$WORK/stage-scripts.output"
  step_command stage-scripts
  mkdir -p "$WORK/runner-temp"
  : > "$out"
  GITHUB_ACTION_PATH="$REPO_ROOT" RUNNER_TEMP="$WORK/runner-temp" \
    GITHUB_OUTPUT="$out" "${STEP_CMD[@]}"
  SCRIPTS_DIR="$(sed -n 's/^dir=//p' "$out")"
  if [ ! -f "$SCRIPTS_DIR/gerrit-checkout.sh" ]; then
    echo "stage-scripts staged nothing usable (dir=${SCRIPTS_DIR:-none})" >&2
    return 1
  fi
  export SCRIPTS_DIR
}
