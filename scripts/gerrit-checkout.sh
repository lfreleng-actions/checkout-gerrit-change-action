# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# shellcheck shell=bash
#
# Fetch the Gerrit change and check it out: from the mirror, or from
# Gerrit when the project has no mirror.
#
# The gerrit-checkout step in action.yaml sources this file, so it
# runs in the step's own shell, bash without -e: every failure is
# reported explicitly through report_error_and_exit. Inputs reach it
# through the environment the step sets.

# Fold CR and LF into visible escapes, so a value reaching the
# log cannot start a line the runner reads as a command.
show()
{
  local value=$1
  value=${value//$'\r'/'\r'}
  printf '%s' "${value//$'\n'/'\n'}"
}

report_error_and_exit()
{
  # Silence xtrace first: tracing the redaction below would print
  # the message it is about to redact.
  { set +x; } 2> /dev/null
  local message=${1:-"fatal: couldn't find remote ref $INPUT_GERRIT_REFSPEC"}
  local annotation
  # Redact any embedded URL credentials (user:pass@host) before
  # logging so a gerrit-url carrying userinfo cannot leak via the
  # echoed message or the GitHub error annotation.
  message=$(printf '%s' "$message" | sed -E 's#://[^/@[:space:]]+@#://***@#g')
  printf '%s\n' "$message"
  # Escape workflow-command metacharacters (%, CR, LF) before
  # emitting the annotation so a multi-line or percent-containing
  # git error cannot break the annotation or inject additional
  # workflow commands. Escape '%' first to avoid double-escaping.
  annotation=${message//'%'/'%25'}
  annotation=${annotation//$'\r'/'%0D'}
  annotation=${annotation//$'\n'/'%0A'}
  echo "::error::$annotation"
  exit 1
}

### Gerrit fallback: no mirror, so Gerrit serves the change ###
#
# Runs before xtrace starts: the credentials it handles stay out
# of the trace.
if [ "$MIRROR" = absent ]
then
  # Both values reach curl's configuration on stdin, where a CR
  # or LF would end the line and start a new option, and git's
  # command line. Neither has any use for a control character,
  # so refuse them outright rather than escape them.
  if [[ "$INPUT_GERRIT_URL$INPUT_GERRIT_PROJECT" == *[[:cntrl:]]* ]]
  then
    report_error_and_exit 'gerrit-url and gerrit-project must not contain control characters'
  fi
  project_path=${INPUT_GERRIT_PROJECT#/}
  project=$(show "$project_path")
  refspec=$(show "$INPUT_GERRIT_REFSPEC")
  gerrit_base=${INPUT_GERRIT_URL%/}

  # Keep credentials embedded in gerrit-url out of .git/config,
  # where they would outlive this step for any later one to
  # read: origin stores the URL without them, and git gets them
  # back through this step's environment, as a rewrite of the
  # plain URL.
  #
  # actions/checkout never ran, so none of what it gives
  # submodules hosted on GitHub is in place either: the token,
  # as an HTTP header scoped to the server, and a rewrite of SSH
  # URLs to HTTPS, so a runner with no SSH key can clone them.
  # Supply both the same way. git keeps these variables for the
  # submodule commands it runs, and Gerrit never sees the token.
  plain_base=$(printf '%s' "$gerrit_base" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@#\1#')
  count=${GIT_CONFIG_COUNT:-0}
  add_config()
  {
    export "GIT_CONFIG_KEY_$count=$1" "GIT_CONFIG_VALUE_$count=$2"
    count=$((count + 1))
  }
  if [ "$plain_base" != "$gerrit_base" ]
  then
    add_config "url.$gerrit_base/.insteadOf" "$plain_base/"
  fi
  if [ -n "$SERVER_URL" ]
  then
    server=${SERVER_URL%/}
    host=${server#*://}
    add_config "url.$server/.insteadOf" "git@$host:"
    add_config "url.$server/.insteadOf" "ssh://git@$host/"
    if [ -n "$INPUT_TOKEN" ]
    then
      basic=$(printf 'x-access-token:%s' "$INPUT_TOKEN" | base64 | tr -d '\n')
      echo "::add-mask::$basic"
      add_config "http.$server/.extraheader" "AUTHORIZATION: basic $basic"
    fi
  fi
  export GIT_CONFIG_COUNT=$count
  export GIT_TERMINAL_PROMPT=0

  # Ask Gerrit over HTTP(S) for the project's advertisement and
  # judge the status code, rather than the wording of a git or
  # libcurl error, which varies across versions and locales.
  # Only an anonymous 401 means a project that exists but is
  # closed to this runner, so only that may skip. Gerrit answers
  # 403 or 404 for a hidden project and for a misspelt one
  # alike, and a 401 to supplied credentials means they are
  # wrong: all three fail, since skipping would pass a check on
  # a configuration error. The URL, credentials included,
  # reaches curl on stdin, which keeps it out of the process
  # list, and --anyauth lets curl answer whatever scheme Gerrit
  # asks for, Digest included, as git does. Other schemes have
  # no status to read, so the ls-remote below decides, and any
  # failure fails.
  available=true
  case "$plain_base" in
    http://* | https://*)
      url="$gerrit_base/$project_path/info/refs?service=git-upload-pack"
      url=${url//\\/\\\\}
      url=${url//\"/\\\"}
      curl_error=$(mktemp)
      status=$(printf 'url = "%s"\n' "$url" |
        curl --config - --silent --show-error --location --anyauth \
          --output /dev/null --write-out '%{http_code}' \
          --max-time 30 2> "$curl_error")
      curl_status=$?
      curl_message=$(cat "$curl_error")
      rm -f "$curl_error"
      # Without --fail, curl exits 0 on any HTTP status, so a
      # nonzero exit means the transfer itself broke, perhaps
      # after a status line arrived. Judge no status from it:
      # a 401 whose body never finished is a network error.
      if [ "$curl_status" -ne 0 ]
      then
        report_error_and_exit "Unable to reach Gerrit for project $project: $curl_message"
      fi
      case "$status" in
        2??) ;;
        401)
          if [ "$plain_base" != "$gerrit_base" ]
          then
            report_error_and_exit "Gerrit rejected the credentials in gerrit-url for project $project (HTTP 401)"
          fi
          available=false
          ;;
        403 | 404)
          report_error_and_exit "Gerrit project $project not found, or hidden from this runner (HTTP $status): check gerrit-project and gerrit-url"
          ;;
        *)
          report_error_and_exit "Gerrit answered HTTP $status for project $project"
          ;;
      esac
      ;;
  esac

  if [ "$available" = false ]
  then
    message="Gerrit project $project has no GitHub mirror and is closed to anonymous reads (HTTP 401), so $refspec cannot be checked out"
    if [ "$ON_UNAVAILABLE" != skip ]
    then
      report_error_and_exit "$message"
    fi
    echo "::notice title=Gerrit change not checked out::${message//'%'/'%25'}; skipped (on-unavailable: skip)"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]
    then
      {
        echo '### Gerrit change not checked out'
        echo
        echo "Gerrit project \`$project\` has no GitHub mirror and" \
          'is closed to anonymous reads, so the checkout was' \
          "skipped (\`on-unavailable: skip\`)."
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    echo "checked-out=false" >> "$GITHUB_OUTPUT"
    exit 0
  fi

  # ls-remote takes the source side of the refspec as its
  # pattern; --exit-code returns 2 when the project lacks it.
  pattern=${INPUT_GERRIT_REFSPEC#+}
  pattern=${pattern%%:*}
  error=$(git ls-remote --exit-code -- "$plain_base/$project_path" "$pattern" 2>&1 > /dev/null)
  case $? in
    0) ;;
    2) report_error_and_exit "Gerrit project $project has no $refspec" ;;
    *) report_error_and_exit "$error" ;;
  esac

  # Gerrit serves the change, so the workspace can now become
  # the checkout. Start from an empty one, as actions/checkout
  # does when the one it finds holds anything other than the
  # repository requested. actions/checkout also marks the
  # workspace as a safe directory, without which git refuses a
  # repository owned by another user, as in a container job; do
  # the same, by the physical path git compares against, unless
  # the configuration already trusts it or every directory.
  workspace=$(pwd -P)
  if ! git config --global --get-all safe.directory 2> /dev/null |
       grep -Fx -e "$workspace" -e '*' > /dev/null
  then
    if ! git config --global --add safe.directory "$workspace"
    then
      report_error_and_exit "Unable to mark $(show "$workspace") as a safe directory"
    fi
  fi
  if ! find . -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + ||
     ! git init -q ||
     ! git remote add origin "$plain_base/$project_path"
  then
    report_error_and_exit "Unable to prepare a workspace for Gerrit project $project"
  fi

  # Fetch the base the mirror clone would have held, before the
  # change: actions/checkout fetches every branch and tag for
  # fetch-depth 0, and otherwise the branch 'ref' names, as
  # origin/<branch>. A 'ref' naming no branch (by default, the
  # caller's commit, which Gerrit does not hold) leaves only the
  # change, fetched below.
  fetch=()
  if [ "$INPUT_FETCH_DEPTH" = 0 ]
  then
    fetch=(--tags -- origin '+refs/heads/*:refs/remotes/origin/*')
  else
    case "$INPUT_REF" in
      refs/heads/?*)
        branch=${INPUT_REF#refs/heads/}
        fetch=("--depth=$INPUT_FETCH_DEPTH" -- origin
          "+refs/heads/$branch:refs/remotes/origin/$branch")
        ;;
    esac
  fi
  if [ ${#fetch[@]} -gt 0 ] &&
     ! error=$(git fetch -q --no-recurse-submodules "${fetch[@]}" 2>&1 > /dev/null)
  then
    report_error_and_exit "$error"
  fi
fi

set -x

fetch_from_gerrit()
{
  if [ -z "$INPUT_GERRIT_URL" ]
  then
    report_error_and_exit "$1"
  fi

  # Disable xtrace around the fetch and its failure handling so a
  # URL/refspec (or the resulting error, which git may echo with
  # the full remote URL) carrying embedded credentials is not
  # exposed via the build log.
  set +x
  error=$(git fetch --no-recurse-submodules "${depth_args[@]}" -- "$INPUT_GERRIT_URL/$INPUT_GERRIT_PROJECT" "$INPUT_GERRIT_REFSPEC" 2>&1 > /dev/null)
  exit_code=$?
  if [ $exit_code -ne 0 ]
  then
    report_error_and_exit "$error"
  fi
  set -x
}

# Print '<recorded commit> <path>' for each populated submodule of
# the repository in the current directory. foreach expands $sha1
# and $sm_path itself, so they stay in single quotes here.
populated_submodules()
{
  # shellcheck disable=SC2016
  git submodule foreach -q 'printf "%s %s\n" "$sha1" "$sm_path"'
}

# Deinitialise each populated submodule that commit $1 does not
# record as a submodule: one the change drops, or replaces with
# tracked files. Checking $1 out over it would leave its working
# tree behind, still holding code the change deleted, or abort on
# a file the change tracks at the same path. It has to happen
# before the checkout, while git still knows the path as a
# submodule. 'deinit' keeps the repository in .git/modules, as it
# always does, ready for a later change that restores it.
deinit_dropped()
(
  set -o pipefail
  populated_submodules |
    while IFS= read -r line
    do
      path=${line#* }
      entry=$(git --literal-pathspecs ls-tree "$1" -- "$path") || exit 1
      case "$entry" in
        '160000 '*) ;;
        *)
          git --literal-pathspecs submodule deinit -f -q -- "$path" < /dev/null ||
            exit 1
          ;;
      esac
    done
)

# The same, one level down, for each populated submodule this
# repository now records at a new commit. 'update' fetches that
# commit and checks it out in one go, so fetch it here first the
# way 'update' would: what the remote advertises, then the
# commit by name.
deinit_dropped_nested()
(
  set -o pipefail
  populated_submodules |
    while IFS= read -r line
    do
      commit=${line%% *}
      (
        cd -- "${line#* }" || exit 1
        if [ "$(git rev-parse HEAD)" = "$commit" ]
        then
          exit 0
        fi
        if ! git cat-file -e "$commit^{commit}" 2> /dev/null
        then
          git fetch -q --no-recurse-submodules
          git cat-file -e "$commit^{commit}" 2> /dev/null ||
            git fetch -q --no-recurse-submodules origin "$commit" ||
            exit 1
        fi
        deinit_dropped "$commit"
      ) < /dev/null || exit 1
    done
)

# Move the submodules of the repository in the current directory
# to the commits it records. 'sync' carries a retargeted
# .gitmodules URL into the config before anything fetches, and
# '--init' populates a submodule the change adds.
# fetch.recurseSubmodules=false keeps each level's fetch out of
# the level below until that level has been synced.
update_submodules()
{
  git submodule sync &&
    { [ "$submodules" != recursive ] || deinit_dropped_nested; } &&
    git -c fetch.recurseSubmodules=false submodule update --init
}

# 'recursive' walks one level at a time rather than passing
# --recursive to sync and update: a nested submodule's URL comes
# from its parent's .gitmodules at the parent's NEW commit, which
# only exists once the level above is updated. Each submodule is
# updated before the walk descends into it.
update_nested()
(
  set -o pipefail
  populated_submodules |
    while IFS= read -r line
    do
      ( cd -- "${line#* }" && update_submodules && update_nested ) < /dev/null ||
        exit 1
    done
)

# A fetch into a shallow repository inherits the shallow
# boundary, which can graft away the change commit's parent --
# for example when the change has already merged and the branch
# tip IS the change commit. Apply the requested fetch depth to
# the refspec fetch so the parent stays reachable for consumers
# that diff against HEAD~1. Guarded by --is-shallow-repository
# so a full clone (fetch-depth: 0) is never silently truncated.
# A repository with no commits yet, which is what the Gerrit
# fallback prepares, is not shallow either, so it takes the
# requested depth too, unless that depth asks for everything.
depth_args=()
if [ "$(git rev-parse --is-shallow-repository)" = "true" ] ||
   { ! git rev-parse -q --verify HEAD > /dev/null &&
     [ "$INPUT_FETCH_DEPTH" != 0 ]; }
then
  depth_args=("--depth=$INPUT_FETCH_DEPTH")
fi

# Leave submodules out of the superproject fetch. By default git
# recurses into populated ones on demand, using the URLs the
# branch tip configured, so a change that retargets a submodule
# fails here asking the old remote for a commit only the new one
# holds. The refresh below fetches them once 'sync' has run.
#
# Disable xtrace around the fetch and its failure handling so a
# refspec (or the resulting error, which git may echo with the
# full remote URL) carrying embedded credentials is not exposed
# via the build log.
set +x
error=$(git fetch --no-recurse-submodules "${depth_args[@]}" -- origin "$INPUT_GERRIT_REFSPEC" 2>&1 > /dev/null)
exit_code=$?
if [ $exit_code -ne 0 ]
then
  # On the fallback origin already is Gerrit, with nowhere else
  # to try
  if [ "$MIRROR" = absent ]
  then
    report_error_and_exit "$error"
  fi
  fetch_from_gerrit "$error"
fi
set -x

# actions/checkout populated submodules for the branch tip; move
# them to the commits the change records, and remove the ones it
# drops. Trim and case-fold the input the way actions/checkout
# does (core.getInput trims whitespace), so every value that
# populated submodules there also refreshes them here. 'false'
# leaves submodules alone.
#
# This shell runs without -e, so report failure explicitly rather
# than pass having left the branch-tip content in place.
submodules=$(printf '%s' "$INPUT_SUBMODULES" |
  tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [ "$submodules" = true ] || [ "$submodules" = recursive ]
then
  if ! deinit_dropped FETCH_HEAD
  then
    report_error_and_exit "Unable to remove submodules dropped by $INPUT_GERRIT_REFSPEC"
  fi
fi
if ! git checkout FETCH_HEAD
then
  report_error_and_exit "Unable to check out $INPUT_GERRIT_REFSPEC"
fi

if [ "$submodules" = true ] || [ "$submodules" = recursive ]
then
  if ! update_submodules
  then
    report_error_and_exit "Unable to update submodules for $INPUT_GERRIT_REFSPEC"
  fi
fi
if [ "$submodules" = recursive ]
then
  if ! update_nested
  then
    report_error_and_exit "Unable to update nested submodules for $INPUT_GERRIT_REFSPEC"
  fi
fi
echo "checked-out=true" >> "$GITHUB_OUTPUT"
