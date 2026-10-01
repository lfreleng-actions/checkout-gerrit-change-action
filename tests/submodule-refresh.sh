#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Checks that the gerrit-checkout step leaves submodules at the commits
# the Gerrit change records, rather than at the branch tip that
# actions/checkout populated them from. Getting this wrong fails
# nothing: a scanner reads the stale submodule content and passes.
#
# The step comes out of action.yaml, its 'shell:' included, and runs the
# way the runner runs it, so the suite cannot drift from what the action
# executes. It needs git and ruby (for the YAML parser in its standard
# library) but no network: every remote is a local bare repository.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${REPO_ROOT}/action.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FETCH_DEPTH=2

# Keep the caller's git configuration (signing, hooks, URL rewrites) out
# of the fixtures, and allow the file:// submodule URLs they rely on;
# git refuses those by default since 2.38.1.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT
export HOME="$WORK/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
git config --global user.name 'Submodule Test'
git config --global user.email 'test@example.invalid'
git config --global init.defaultBranch main
git config --global commit.gpgSign false
git config --global advice.detachedHead false
git config --global protocol.file.allow always

### The step under test ###

ruby -ryaml -e '
  steps = YAML.safe_load(File.read(ARGV[0])).dig("runs", "steps")
  step = steps.find { |s| s["id"] == "gerrit-checkout" }
  abort "No step with id gerrit-checkout in #{ARGV[0]}" unless step
  File.write(ARGV[1], step.fetch("run"))
  File.write(ARGV[2], step.fetch("shell", "bash"))
' "$ACTION" "$WORK/step.sh" "$WORK/step.shell"

# The runner expands the 'bash' keyword to the command below, and puts
# the script path in place of '{0}' in a custom shell like this step's.
# The options matter: this step's shell carries no -e, so a failure
# only reaches the job if the script reports it.
shell="$(cat "$WORK/step.shell")"
case "$shell" in
  bash) shell='bash --noprofile --norc -eo pipefail {0}' ;;
  *'{0}'*) ;;
  *)
    echo "Unsupported shell for gerrit-checkout: $shell" >&2
    exit 1
    ;;
esac
read -ra STEP_CMD <<< "$shell"
for i in "${!STEP_CMD[@]}"; do
  if [ "${STEP_CMD[i]}" = '{0}' ]; then
    STEP_CMD[i]="$WORK/step.sh"
  fi
done

### Fixtures ###

REMOTES="$WORK/remotes"
SRC="$WORK/src"
mkdir -p "$REMOTES" "$SRC"

# A bare "remote", plus a clone to author its commits in
new_repo() {
  git init -q --bare "$REMOTES/$1.git"
  git init -q "$SRC/$1"
  git -C "$SRC/$1" remote add origin "file://$REMOTES/$1.git"
}

# Record, or re-record, a submodule in the next commit of a repository
record() {
  local name="$1" path="$2" url="$3" sha="$4"
  git -C "$SRC/$name" config -f .gitmodules "submodule.$path.path" "$path"
  git -C "$SRC/$name" config -f .gitmodules "submodule.$path.url" "$url"
  git -C "$SRC/$name" add .gitmodules
  git -C "$SRC/$name" update-index --add --cacheinfo "160000,$sha,$path"
}

# Commit what is staged, push it to a ref, and print its SHA. The push
# goes to the repository's origin unless a URL is given.
commit() {
  local name="$1" ref="$2" msg="$3" remote="${4:-origin}"
  printf '%s\n' "$msg" > "$SRC/$name/content.txt"
  git -C "$SRC/$name" add content.txt
  git -C "$SRC/$name" commit -qm "$msg"
  git -C "$SRC/$name" push -q "$remote" "HEAD:$ref"
  git -C "$SRC/$name" rev-parse HEAD
}

# How actions/checkout reads 'submodules': core.getInput trims
# surrounding whitespace, then the value is compared case-insensitively
lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# The branch tip: super -> a (-> c, d), d
new_repo c
C1="$(commit c refs/heads/main c1)"
new_repo d
D1="$(commit d refs/heads/main d1)"
git clone -q --bare "$REMOTES/d.git" "$REMOTES/d-fork.git"
git clone -q "file://$REMOTES/d-fork.git" "$SRC/d-fork"
new_repo a
record a c ../c.git "$C1"
record a d ../d.git "$D1"
A1="$(commit a refs/heads/main a1)"
new_repo b
record b c ../c.git "$C1"
new_repo super
record super a ../a.git "$A1"
record super d ../d.git "$D1"
S0="$(commit super refs/heads/main s0)"

# What actions/checkout leaves behind for each 'submodules' value: a
# shallow fetch of the branch tip, then the same submodule commands and
# options it runs (see git-source-provider.ts and git-command-manager.ts
# in actions/checkout). It trims the input and accepts it in any letter
# case, so padded values populate submodules too.
MODES=(false true TRUE recursive ' TRUE ' ' recursive ')
# The gerrit- changes repeat the first three, published only to the
# Gerrit server, so the step reaches them through its fallback fetch
CHANGES=(bump add retarget add-unreachable nested-unreachable
  gerrit-bump gerrit-add gerrit-retarget)
checkout_tip() {
  local ws="$1" mode="$2" recurse=()
  git init -q "$ws"
  git -C "$ws" remote add origin "file://$REMOTES/super.git"
  git -C "$ws" -c protocol.version=2 fetch -q --no-tags --prune \
    --depth="$FETCH_DEPTH" origin '+refs/heads/main:refs/remotes/origin/main'
  git -C "$ws" checkout -q --force -B main refs/remotes/origin/main
  case "$(lower "$mode")" in
    true) ;;
    recursive) recurse=(--recursive) ;;
    *) return 0 ;;
  esac
  git -C "$ws" submodule -q sync "${recurse[@]}"
  git -C "$ws" -c protocol.version=2 submodule -q update --init --force \
    --depth="$FETCH_DEPTH" "${recurse[@]}"
}
# Workspaces are named by index: 'true' and 'TRUE' are one directory on
# a case-insensitive filesystem.
for m in "${!MODES[@]}"; do
  for c in "${!CHANGES[@]}"; do
    checkout_tip "$WORK/ws-$m-$c" "${MODES[m]}"
  done
done

# The changes under review, each a child of the branch tip, published
# after that checkout so the step has to fetch what they record.
C2="$(commit c refs/heads/main c2)"
DF1="$(commit d-fork refs/heads/main df1)"
# a moves on twice: bumping its nested c on main, then retargeting its
# nested d on a branch of its own, so fetching main for the other
# changes does not bring in a commit that only the retarget accounts for
record a c ../c.git "$C2"
A2="$(commit a refs/heads/main a2)"
record a d ../d-fork.git "$DF1"
A3="$(commit a refs/heads/retarget a3)"
B1="$(commit b refs/heads/main b1)"
# Indexed alongside CHANGES
REFSPECS=(refs/changes/01/1/1 refs/changes/02/2/1 refs/changes/03/3/1
  refs/changes/04/4/1 refs/changes/05/5/1 refs/changes/06/6/1
  refs/changes/07/7/1 refs/changes/08/8/1)
SHAS=()
# bump: a (and through it, a/c) moves to a newer commit
git -C "$SRC/super" checkout -q --detach "$S0"
record super a ../a.git "$A2"
SHAS[0]="$(commit super "${REFSPECS[0]}" bump)"
# add: b is new, and brings a nested c of its own
git -C "$SRC/super" checkout -q --detach "$S0"
record super b ../b.git "$B1"
SHAS[1]="$(commit super "${REFSPECS[1]}" add)"
# retarget: d moves to a fork, at a commit only the fork carries, and a
# moves to the commit that does the same to a/d
git -C "$SRC/super" checkout -q --detach "$S0"
record super d ../d-fork.git "$DF1"
record super a ../a.git "$A3"
SHAS[2]="$(commit super "${REFSPECS[2]}" retarget)"
# The last two name a repository that does not exist, so the refresh
# fails, each at a different level.
# add-unreachable: the top-level update fails cloning a new e
git -C "$SRC/super" checkout -q --detach "$S0"
record super e ../missing.git "$C1"
SHAS[3]="$(commit super "${REFSPECS[3]}" add-unreachable)"
# nested-unreachable: the top-level update moves a to a commit adding
# a nested e, then the nested refresh fails cloning it
git -C "$SRC/a" checkout -q --detach "$A1"
record a e ../missing.git "$C1"
A4="$(commit a refs/heads/nested-unreachable a4)"
git -C "$SRC/super" checkout -q --detach "$S0"
record super a ../a.git "$A4"
SHAS[4]="$(commit super "${REFSPECS[4]}" nested-unreachable)"

# The Gerrit server the step falls back to when origin, the mirror,
# lacks the change: the URL the step fetches is gerrit-url and
# gerrit-project joined by '/'. It holds the same three changes as
# commits of its own, which never reach the mirror.
GERRIT_URL="file://$WORK/gerrit"
GERRIT_PROJECT='releng/super'
GERRIT_REPO="$GERRIT_URL/$GERRIT_PROJECT"
git init -q --bare "$WORK/gerrit/$GERRIT_PROJECT"
git -C "$SRC/super" checkout -q --detach "$S0"
record super a ../a.git "$A2"
SHAS[5]="$(commit super "${REFSPECS[5]}" gerrit-bump "$GERRIT_REPO")"
git -C "$SRC/super" checkout -q --detach "$S0"
record super b ../b.git "$B1"
SHAS[6]="$(commit super "${REFSPECS[6]}" gerrit-add "$GERRIT_REPO")"
git -C "$SRC/super" checkout -q --detach "$S0"
record super d ../d-fork.git "$DF1"
record super a ../a.git "$A3"
SHAS[7]="$(commit super "${REFSPECS[7]}" gerrit-retarget "$GERRIT_REPO")"

FORK_URL="file://$REMOTES/d-fork.git"

### Checks ###

passed=0
failed=0

check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
    echo "✅ $desc"
  else
    failed=$((failed + 1))
    echo "❌ $desc"
    echo "   got:  $got"
    echo "   want: $want"
  fi
}

# Probe a path only when a repository is rooted there. An unpopulated
# submodule is an empty directory, where git would otherwise report on
# the superproject enclosing it.
head_of() {
  if [ -e "$1/.git" ]; then
    git -C "$1" rev-parse HEAD
  else
    echo 'not populated'
  fi
}

url_of() {
  if [ -e "$1/.git" ]; then
    git -C "$1" config --get remote.origin.url
  else
    echo 'not populated'
  fi
}

# The annotation report_error_and_exit emits when a refresh fails, or
# nothing where the refresh should succeed
expected_error() {
  local mode="$1" change="$2" refspec="$3"
  case "$(lower "$mode"):$change" in
    true:add-unreachable | recursive:add-unreachable)
      echo "::error::Unable to update submodules for $refspec"
      ;;
    recursive:nested-unreachable)
      echo "::error::Unable to update nested submodules for $refspec"
      ;;
  esac
}

for m in "${!MODES[@]}"; do
  for c in "${!CHANGES[@]}"; do
    mode="${MODES[m]}"
    change="${CHANGES[c]}"
    ws="$WORK/ws-$m-$c"
    log="$WORK/step-$m-$c.log"
    tag="$mode/$change"
    # What the change does, wherever it is published
    kind="${change#gerrit-}"
    gerrit_url=''
    if [ "$kind" != "$change" ]; then
      gerrit_url="$GERRIT_URL"
    fi
    echo
    echo "### submodules: $mode, change: $change"

    rc=0
    (
      cd "$ws"
      INPUT_GERRIT_REFSPEC="${REFSPECS[c]}" \
        INPUT_GERRIT_URL="$gerrit_url" \
        INPUT_GERRIT_PROJECT="$GERRIT_PROJECT" \
        INPUT_FETCH_DEPTH="$FETCH_DEPTH" \
        INPUT_SUBMODULES="$mode" \
        "${STEP_CMD[@]}"
    ) > "$log" 2>&1 || rc=$?
    failed_before=$failed

    want_error="$(expected_error "$mode" "$kind" "${REFSPECS[c]}")"
    if [ -z "$want_error" ]; then
      check "$tag: step succeeds" "$rc" 0
    else
      # The step's shell has no -e: only the explicit report stops it
      # passing on a stale tree, so require both the failure and the
      # annotation naming the level that failed.
      if [ "$rc" -eq 0 ]; then
        outcome='succeeded'
      else
        outcome='failed'
      fi
      check "$tag: step fails" "$outcome" 'failed'
      check "$tag: step reports the failed refresh" \
        "$(grep '^::error::' "$log" || true)" "$want_error"
    fi
    check "$tag: superproject is at the change" \
      "$(head_of "$ws")" "${SHAS[c]}"

    case "$(lower "$mode"):$kind" in
      false:*)
        for path in a b d; do
          check "$tag: $path is left alone" \
            "$(head_of "$ws/$path")" 'not populated'
        done
        ;;
      *:bump)
        check "$tag: a follows the change" "$(head_of "$ws/a")" "$A2"
        ;;
      *:add)
        check "$tag: b, which the change adds, is populated" \
          "$(head_of "$ws/b")" "$B1"
        ;;
      *:retarget)
        check "$tag: d follows the change" "$(head_of "$ws/d")" "$DF1"
        check "$tag: d fetches from its new URL" \
          "$(url_of "$ws/d")" "$FORK_URL"
        ;;
      *:nested-unreachable)
        # So the failure reported under 'recursive' is the nested one
        check "$tag: a follows the change" "$(head_of "$ws/a")" "$A4"
        ;;
    esac

    case "$(lower "$mode"):$kind" in
      true:add)
        check "$tag: nested b/c is left alone" \
          "$(head_of "$ws/b/c")" 'not populated'
        ;;
      true:*)
        for path in a/c a/d; do
          check "$tag: nested $path is left alone" \
            "$(head_of "$ws/$path")" 'not populated'
        done
        ;;
      recursive:bump)
        check "$tag: nested a/c follows a" "$(head_of "$ws/a/c")" "$C2"
        ;;
      recursive:add)
        check "$tag: nested b/c, under the added b, is populated" \
          "$(head_of "$ws/b/c")" "$C1"
        ;;
      recursive:retarget)
        check "$tag: nested a/d follows a" "$(head_of "$ws/a/d")" "$DF1"
        check "$tag: nested a/d fetches from its new URL" \
          "$(url_of "$ws/a/d")" "$FORK_URL"
        ;;
    esac

    # Where the change came from. The step fetches with xtrace off and
    # logs nothing on success, so read git's record: FETCH_HEAD ends
    # with ' of <url>' for the fetch the checkout used.
    fetched_from="$(sed -n 's/.* of //p' "$ws/.git/FETCH_HEAD" 2> /dev/null)"
    if [ -n "$gerrit_url" ]; then
      check "$tag: origin lacks the change" \
        "$(git -C "$ws" ls-remote origin "${REFSPECS[c]}")" ''
      check "$tag: change fetched from Gerrit" \
        "$fetched_from" "$GERRIT_REPO"
    else
      # git drops '.git' when it records a named remote's URL, so check
      # only that the fallback was not taken
      if [ "$fetched_from" = "$GERRIT_REPO" ]; then
        fetched_from='Gerrit'
      else
        fetched_from='origin'
      fi
      check "$tag: change fetched from origin" "$fetched_from" 'origin'
    fi

    if [ "$failed" -ne "$failed_before" ]; then
      echo "--- step output ($tag) ---"
      cat "$log"
      echo '---'
    fi
  done
done

echo
echo "Passed: $passed, failed: $failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
