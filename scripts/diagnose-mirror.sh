# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# shellcheck shell=bash
#
# Once the action has failed, say what state the GitHub mirror is in,
# and who can fix it.
#
# The diagnose-mirror step in action.yaml sources this file, so it runs
# in the step's own shell, bash with -e and -o pipefail. Inputs reach
# it through the environment the step sets. The step runs only after a
# failure on the mirror path, so it costs a successful run nothing.
#
# The action has already failed by the time this runs, so nothing here
# may change that: every error leads to "cannot tell", never to a
# nonzero exit. A healthy mirror (populated, not archived, holding the
# change) means the failure lies elsewhere, and the step says nothing.
#
# Nothing the server sends reaches the log but a boolean and the HTTP
# status: every message is fixed text around the validated repository,
# refspec, branch and delay.

# Credentials pass through here; keep them out of any trace
{ set +x; } 2> /dev/null
set +e +o pipefail

# Per-request ceiling, in seconds. At most three requests run, one
# attempt each, so the diagnosis ends within 30 seconds, plus at most
# two seconds for each git command it has to stop.
diagnosis_limit=10

# Print one annotation and one line of the job summary. $1 is the
# annotation command (error or notice), $2 the message. Escape the
# workflow-command metacharacters as report_error_and_exit in
# gerrit-checkout.sh does, '%' first to avoid double-escaping.
diagnosis_report()
{
  local annotation=$2
  annotation=${annotation//'%'/'%25'}
  annotation=${annotation//$'\r'/'%0D'}
  annotation=${annotation//$'\n'/'%0A'}
  echo "::$1 title=GitHub mirror::$annotation"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]
  then
    echo "**GitHub mirror:** $annotation" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# Signal $2 to the command started as $1: to its whole process group
# where it leads one, or else to it and the descendants it has now
diagnosis_signal()
{
  local pid
  if ! kill "-$2" -- "-$1" 2> /dev/null
  then
    for pid in $(diagnosis_descendants "$1") "$1"
    do
      kill "-$2" "$pid" 2> /dev/null
    done
  fi
}

# Print the descendants of process $1, deepest first
diagnosis_descendants()
{
  local child
  command -v pgrep > /dev/null 2>&1 || return 0
  for child in $(pgrep -P "$1" 2> /dev/null)
  do
    diagnosis_descendants "$child"
    echo "$child"
  done
}

# Run a command, stopping it and every process it started after $1
# seconds. git has no overall timeout of its own, and a git killed
# alone leaves its HTTP transport blocked on the network, so the
# command runs in a process group of its own (job control, which bash
# has wherever it runs, unlike setsid) and the whole group goes:
# TERM, a one-second grace, then KILL. The watchdog sends both itself,
# since the wait below returns only once the command has ended, and it
# holds none of the step's output open, so the step can end the moment
# the command does. Return the command's status, or as timeout(1)
# does, 124 for a command stopped and 137 for one that needed KILL.
diagnosis_bounded()
{
  local limit=$1 pid watchdog rc fired tries
  shift
  set -m
  "$@" < /dev/null &
  pid=$!
  set +m
  # The watchdog's status says how far it got: 0 when stopped before
  # the limit, 3 from the moment it sends TERM, 4 from KILL
  (
    state=0
    sleeper=''
    trap 'kill "$sleeper" 2> /dev/null; exit "$state"' TERM
    sleep "$limit" &
    sleeper=$!
    wait "$sleeper" || exit 0
    state=3
    diagnosis_signal "$pid" TERM
    sleep 1 &
    sleeper=$!
    wait "$sleeper" || exit "$state"
    state=4
    diagnosis_signal "$pid" KILL
    exit "$state"
  ) > /dev/null 2>&1 < /dev/null &
  watchdog=$!
  wait "$pid"
  rc=$?
  kill "$watchdog" 2> /dev/null
  wait "$watchdog" 2> /dev/null
  case $? in
    3 | 4) fired=true ;;
    *) fired=false ;;
  esac
  # A command that ended on its own has left nothing in its group, and
  # its group ID may be free for reuse. One stopped by the watchdog may
  # have left a transport that outlived it, which keeps the group alive.
  if [ "$fired" = false ] && [ "$rc" -le 128 ]
  then
    return "$rc"
  fi
  tries=0
  while kill -0 -- "-$pid" 2> /dev/null && [ "$tries" -lt 10 ]
  do
    sleep 0.1
    tries=$((tries + 1))
  done
  if kill -0 -- "-$pid" 2> /dev/null
  then
    kill -KILL -- "-$pid" 2> /dev/null
    tries=0
    while kill -0 -- "-$pid" 2> /dev/null && [ "$tries" -lt 10 ]
    do
      sleep 0.1
      tries=$((tries + 1))
    done
  fi
  if [ "$fired" = false ]
  then
    return "$rc"
  elif [ "$rc" -eq 137 ]
  then
    return 137
  fi
  return 124
}

# List into file $1 the mirror's refs matching pattern $2, or with no
# pattern its branches and tags. The token reaches git as an HTTP
# header through the environment, never on the command line or in the
# URL, and git runs outside the workspace, whose configuration holds
# the header actions/checkout persisted.
diagnosis_ls_remote()
(
  out=$1
  args=(--heads --tags -- "$diagnosis_server/$INPUT_REPOSITORY")
  if [ -n "$2" ]
  then
    args=(-- "$diagnosis_server/$INPUT_REPOSITORY" "$2")
  fi
  count=${GIT_CONFIG_COUNT:-0}
  if [ -n "$INPUT_TOKEN" ]
  then
    basic=$(printf 'x-access-token:%s' "$INPUT_TOKEN" | base64 | tr -d '\n')
    export "GIT_CONFIG_KEY_$count=http.$diagnosis_server/.extraheader" \
      "GIT_CONFIG_VALUE_$count=AUTHORIZATION: basic $basic"
    count=$((count + 1))
  fi
  export GIT_CONFIG_COUNT=$count GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
  export GIT_CEILING_DIRECTORIES=${diagnosis_tmp%/*}
  cd "$diagnosis_tmp" || exit 1
  diagnosis_bounded "$diagnosis_limit" git ls-remote "${args[@]}" \
    > "$out" 2> /dev/null
)

# Print true, false or unknown: the top-level 'archived' field of the
# JSON in file $1. A fork carries its parent's 'archived' too, nested,
# so only a real JSON parser can tell them apart. Only a JSON boolean
# is an answer: Python holds 1 equal to True, so it tests identity.
# Any other output, an empty one from jq on an empty body included,
# becomes unknown, so both parsers make the same promise.
diagnosis_archived()
{
  local filter='if .archived == true then "true" elif .archived == false then "false" else "unknown" end'
  local value=unknown
  if command -v jq > /dev/null 2>&1
  then
    # jq prints each value as it parses and fails only on reaching bad
    # bytes, so its output alone does not prove the body parsed. Slurp
    # the body, require exactly one value, and treat any failure as
    # unknown, as Python's json.load does.
    if ! value=$(jq -r -s "if length == 1 then .[0] | $filter else \"unknown\" end" \
      < "$1" 2> /dev/null)
    then
      value=unknown
    fi
  elif command -v python3 > /dev/null 2>&1
  then
    value=$(python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get("archived")
except Exception:
    value = None
if value is True:
    print("true")
elif value is False:
    print("false")
else:
    print("unknown")
' < "$1" 2> /dev/null)
  fi
  case "$value" in
    true | false) echo "$value" ;;
    *) echo unknown ;;
  esac
}

diagnose_mirror()
{
  local mirror=$INPUT_REPOSITORY status archived body refspec='' branch=''
  local branch_or_tag=false
  local delay='' pattern

  # The name goes into a URL and the log, so accept only the
  # owner/name shape, as probe-mirror does. Any other value failed
  # actions/checkout for reasons of its own, and names no mirror.
  if [[ ! "$mirror" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
     [[ "$mirror" =~ (^|/)\.\.?(/|$) ]]
  then
    return 0
  fi

  # Caller-supplied values appear in a message only in a shape that
  # cannot carry a workflow command
  pattern=${INPUT_GERRIT_REFSPEC#+}
  pattern=${pattern%%:*}
  if [[ "$pattern" =~ ^refs/[A-Za-z0-9._/-]+$ ]]
  then
    refspec=$pattern
  fi
  # actions/checkout reads a full SHA as a commit, refs/heads/<name>
  # as a branch, and any other bare name as a branch or a tag
  case "$INPUT_REF" in
    refs/heads/?*) branch=${INPUT_REF#refs/heads/} ;;
    refs/* | '') ;;
    *)
      if [[ ! "$INPUT_REF" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]
      then
        branch=$INPUT_REF
        branch_or_tag=true
      fi
      ;;
  esac
  # A name the message cannot show safely is not checked at all: with
  # no name to give, there is no claim to make
  if [[ ! "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]
  then
    branch=''
    branch_or_tag=false
  fi
  if [[ "${INPUT_DELAY:-}" =~ ^[0-9]+(\.[0-9]+)?[smhd]?$ ]]
  then
    delay=$INPUT_DELAY
  fi

  diagnosis_tmp=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/diagnose-mirror.XXXXXX") ||
    return 0
  diagnosis_server=${SERVER_URL%/}
  body="$diagnosis_tmp/repository.json"

  # One attempt, bounded, with the token on stdin as configuration,
  # as probe-mirror sends it
  status=$(
    if [ -n "$INPUT_TOKEN" ]
    then
      printf 'header = "Authorization: Bearer %s"\n' "$INPUT_TOKEN"
    fi |
      curl --config - --silent --output "$body" \
        --write-out '%{http_code}' --max-time "$diagnosis_limit" \
        --max-filesize 1048576 \
        --header 'Accept: application/vnd.github+json' \
        -- "${API_URL%/}/repos/$mirror"
  ) || status=''
  if [[ ! "$status" =~ ^[0-9]{3}$ ]] || [ "$status" = 000 ]
  then
    diagnosis_report notice "Cannot tell the state of GitHub mirror $mirror: the GitHub API did not answer. No cause is identified."
    return 0
  fi
  case "$status" in
    404)
      if [ -z "$INPUT_GERRIT_URL" ]
      then
        diagnosis_report error "GitHub repository $mirror was not found, or is private and not visible to this token, and no gerrit-url was given, so the change cannot be fetched from Gerrit. For the caller to fix: set gerrit-url, check the repository input, or pass a token that can read $mirror."
      else
        diagnosis_report error "GitHub repository $mirror was not found, or is private and not visible to this token. For the caller to fix: check the repository input, or pass a token that can read $mirror."
      fi
      return 0
      ;;
    200) ;;
    *)
      diagnosis_report notice "Cannot tell the state of GitHub mirror $mirror: the GitHub API answered HTTP $status. No cause is identified."
      return 0
      ;;
  esac

  archived=$(diagnosis_archived "$body")
  case "$archived" in
    true | false) ;;
    *) archived=unknown ;;
  esac
  if [ "$archived" = true ]
  then
    diagnosis_report error "GitHub mirror $mirror is archived, so Gerrit replication cannot update it and the change will never arrive. This is not a fault in the change or the workflow: LF Releng or the project's administrators must unarchive the mirror."
    return 0
  fi

  if ! diagnosis_ls_remote "$diagnosis_tmp/heads" ''
  then
    diagnosis_report notice "Cannot tell the state of GitHub mirror $mirror: git ls-remote failed. No cause is identified."
    return 0
  fi
  if ! grep -q $'\trefs/heads/' "$diagnosis_tmp/heads"
  then
    diagnosis_report error "GitHub mirror $mirror has no branches: Gerrit replication has not populated it. This is not a fault in the change or the workflow: LF Releng must repair replication, including the project's read grant for the GitHub Replication group."
    return 0
  fi
  if [ "$branch_or_tag" = true ] && [ -n "$branch" ] &&
     ! cut -f2 "$diagnosis_tmp/heads" |
       grep -qFx -e "refs/heads/$branch" -e "refs/tags/$branch"
  then
    diagnosis_report error "GitHub mirror $mirror has no branch or tag $branch. For the caller to fix: check the ref input; if $branch is new in Gerrit, the project must replicate it."
    return 0
  fi
  if [ "$branch_or_tag" = false ] && [ -n "$branch" ] &&
     ! cut -f2 "$diagnosis_tmp/heads" | grep -qFx -e "refs/heads/$branch"
  then
    diagnosis_report error "GitHub mirror $mirror has no branch $branch. For the caller to fix: check the ref input; if $branch is new in Gerrit, the project must replicate it."
    return 0
  fi

  if [ -n "$refspec" ]
  then
    if ! diagnosis_ls_remote "$diagnosis_tmp/change" "$refspec"
    then
      diagnosis_report notice "Cannot tell the state of GitHub mirror $mirror: git ls-remote of $refspec failed. No cause is identified."
      return 0
    fi
    if ! cut -f2 "$diagnosis_tmp/change" | grep -qFx -e "$refspec"
    then
      diagnosis_report error "GitHub mirror $mirror has branches but not $refspec: replication may be lagging${delay:+ (delay is $delay)}, may have stalled, or the change may be private; private change refs are not replicated. Retry; if it persists, ask LF Releng. Nothing replicates a private change to the mirror."
      return 0
    fi
  fi
  # The refs look healthy, but with no readable archive state the mirror
  # may be archived all the same
  if [ "$archived" = unknown ]
  then
    diagnosis_report notice "Cannot tell whether GitHub mirror $mirror is archived: the GitHub API answer could not be read. No cause is identified."
  fi
  # Otherwise the mirror is healthy: the failure lies elsewhere
  return 0
}

diagnose_mirror
rm -rf -- "${diagnosis_tmp:-}"
exit 0
