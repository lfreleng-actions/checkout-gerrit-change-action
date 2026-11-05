# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
# shellcheck shell=bash
#
# Remove the credentials actions/checkout persisted into the clone, for
# a Gerrit-mode caller that set persist-credentials: false.
#
# Gerrit mode has actions/checkout persist the token, because fetching
# the change from the mirror needs it. Once that fetch is done, this
# removes what actions/checkout stored, the way its own post step does
# (see git-auth-helper.ts in actions/checkout), from the repository and
# from every submodule:
#
#   - the http.<server>/.extraheader carrying the token;
#   - includeIf.gitdir entries naming a git-credentials-<id>.config
#     file, and the file itself when it lies under RUNNER_TEMP.
#
# The superproject goes first, so nothing in the change under review
# can keep its token in place. Submodules are then found from the git
# directories under .git/modules, never from the checked-out
# .gitmodules, which the change may have broken.
#
# The remove-credentials step in action.yaml sources this file, so it
# runs in the step's own shell, bash with -e and -o pipefail. Inputs
# reach it through the environment the step sets.

set -euo pipefail

# actions/checkout failed before it made a repository: nothing to do
if ! git rev-parse --git-dir > /dev/null 2>&1
then
  exit 0
fi

# actions/checkout keys the header on the server's origin,
# SCHEME://HOST[:PORT], whatever path SERVER_URL carries
origin=$(printf '%s' "$SERVER_URL" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://[^/]*).*#\1#')
header_key="http.$origin/.extraheader"

# Print path $1 with forward slashes and no trailing slash. A Windows
# runner writes native paths (D:\a\_temp\...), and its file system
# ignores letter case, so a path with a drive letter is lowercased too
# when $2 is 'fold'.
normalise_path()
{
  local path=${1//\\//}
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]
  do
    path=${path%/}
  done
  if [ "${2:-}" = fold ] && [[ "$path" =~ ^[A-Za-z]:/ ]]
  then
    path=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
  fi
  printf '%s' "$path"
}

# Succeed when credential file $1 lies inside RUNNER_TEMP
in_runner_temp()
{
  local temp file
  [ -n "${RUNNER_TEMP:-}" ] || return 1
  temp=$(normalise_path "$RUNNER_TEMP" fold)
  file=$(normalise_path "$1" fold)
  [[ "$file" == "$temp"/* && "$file" != */../* ]]
}

# Print $1 as an extended regular expression matching exactly that
# value. 'git config --fixed-value' would do this, but it needs Git
# 2.30, and actions/checkout supports Git 2.18 and later.
exact_value_pattern()
{
  printf '^%s$' "$(printf '%s' "$1" | sed -e 's/[]\.*^$+?(){}|[]/\\&/g')"
}

removed=0

# Strip the credentials from the git configuration file $1
strip_config()
{
  local file=$1 key value keys values
  if git config --file "$file" --get-all "$header_key" > /dev/null
  then
    git config --file "$file" --unset-all "$header_key"
    removed=$((removed + 1))
  fi
  keys=$(git config --file "$file" --name-only \
    --get-regexp '^includeif\.gitdir:' || true)
  while IFS= read -r key
  do
    [ -n "$key" ] || continue
    values=$(git config --file "$file" --get-all "$key" || true)
    while IFS= read -r value
    do
      if [[ "$value" =~ git-credentials-[0-9A-Fa-f-]+\.config$ ]]
      then
        git config --file "$file" --unset-all "$key" \
          "$(exact_value_pattern "$value")"
        removed=$((removed + 1))
        if in_runner_temp "$value"
        then
          rm -f -- "$(normalise_path "$value")"
        fi
      fi
    done <<< "$values"
  done <<< "$keys"
}

git_dir=$(git rev-parse --absolute-git-dir)
strip_config "$git_dir/config"

# Each submodule at every depth: a git directory under modules/, which
# holds HEAD, objects and refs, as git itself requires of one
if [ -d "$git_dir/modules" ]
then
  while IFS= read -r -d '' config
  do
    dir=${config%/config}
    if [ -f "$dir/HEAD" ] && [ -d "$dir/objects" ] && [ -d "$dir/refs" ]
    then
      strip_config "$config"
    fi
  done < <(find "$git_dir/modules" -type f -name config -print0)
fi
if [ "$removed" -gt 0 ]
then
  echo 'Removed the persisted checkout credentials'
else
  echo 'No persisted checkout credentials to remove'
fi
