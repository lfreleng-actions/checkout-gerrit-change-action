#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Checks plain mode, where an empty gerrit-refspec makes the action a
# plain actions/checkout, and the Gerrit-mode inputs that came with it:
# gerrit-branch and persist-credentials.
#
# - The select-mode step picks the mode, the ref and the credential
#   setting, and selects Gerrit mode by gerrit-refspec alone, with or
#   without a gerrit-project.
# - The step conditions in action.yaml skip every Gerrit-only step in
#   plain mode, and pass the new inputs to actions/checkout.
# - The remove-credentials step takes out what actions/checkout
#   persisted, from the repository and every submodule, and nothing
#   else, even when the change breaks .gitmodules, the runner writes
#   Windows paths, or git predates 'git config --fixed-value'.
#
# Each step runs as the runner runs it, read out of action.yaml with its
# 'shell:', so the suite cannot drift from what the action executes. It
# needs git but no network: every remote is a local bare repository.
# testing.yaml runs the action itself in both modes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Keep the caller's git configuration (signing, hooks, URL rewrites) out
# of the fixtures, and allow the file:// submodule URLs they rely on.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT
export HOME="$WORK/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
git config --global user.name 'Plain Mode Test'
git config --global user.email 'test@example.invalid'
git config --global init.defaultBranch main
git config --global commit.gpgSign false
git config --global protocol.file.allow always

### The steps under test ###

# shellcheck source=tests/steps.sh disable=SC1091
source "$REPO_ROOT/tests/steps.sh"
stage_scripts

for id in select-mode remove-credentials; do
  step_command "$id"
  printf '%s\n' "${STEP_CMD[@]}" > "$WORK/$id.cmd"
done

# Run step $1 in directory $2 with the environment that follows, the
# way the runner does: a fresh GITHUB_OUTPUT file, output and exit
# status captured for the checks.
run_step() {
  local id="$1" dir="$2" cmd=()
  shift 2
  mapfile -t cmd < "$WORK/$id.cmd"
  : > "$WORK/output"
  rc=0
  (
    cd "$dir"
    env GITHUB_OUTPUT="$WORK/output" "$@" "${cmd[@]}"
  ) > "$WORK/log" 2>&1 || rc=$?
}

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
    echo '--- step output ---'
    cat "$WORK/log"
    echo '---'
  fi
}

outcome() {
  if [ "$rc" -eq 0 ]; then echo 'succeeded'; else echo 'failed'; fi
}

# The value step output $1 was set to, or nothing
output() {
  sed -n "s/^$1=//p" "$WORK/output"
}

errors() {
  grep '^::error::' "$WORK/log" || true
}

# Print key $2 of the step with id $1, as one line: its value, or for a
# folded block ('>-') its lines joined by single spaces.
step_value() {
  awk -v id="$1" -v key="$2" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    /^    - / { if (found) exit; in_step = ($0 == "    - id: " id); next }
    !in_step { next }
    found {
      if (indent($0) <= depth) exit
      line = $0; sub(/^ +/, "", line)
      value = (value == "" ? line : value " " line)
      next
    }
    {
      line = $0; sub(/^ +/, "", line)
      if (index(line, key ": ") != 1) next
      value = substr(line, length(key ": ") + 1)
      if (value != ">-") { print value; exit }
      value = ""; depth = indent($0); found = 1
    }
    END { if (found) print value }
  ' "$REPO_ROOT/action.yaml"
}

# Run select-mode with the inputs the variables below name
select_mode() {
  run_step select-mode "$WORK" \
    INPUT_GERRIT_REFSPEC="${REFSPEC-}" \
    INPUT_GERRIT_PROJECT="${PROJECT-}" \
    INPUT_GERRIT_BRANCH="${BRANCH-}" \
    INPUT_REF="${REF-caller-sha}" \
    INPUT_REPOSITORY="${REPOSITORY-org/caller}" \
    CALLER_REPOSITORY='org/caller' \
    DEFAULT_REF='trigger-sha' \
    INPUT_PERSIST_CREDENTIALS="${PERSIST-true}"
}

echo '### The steps in action.yaml'

GERRIT_ONLY="steps.select-mode.outputs.mode == 'gerrit'"
for id in check-target probe-mirror gerrit-checkout; do
  check "$id: runs in Gerrit mode alone" "$(step_value "$id" if)" \
    "$GERRIT_ONLY"
done
check 'delay-checkout: runs in Gerrit mode alone, with a mirror' \
  "$(step_value delay-checkout if)" \
  "$GERRIT_ONLY && steps.probe-mirror.outputs.mirror != 'absent'"
check 'diagnose-mirror: runs after a failure in Gerrit mode alone' \
  "$(step_value diagnose-mirror if)" \
  "failure() && $GERRIT_ONLY && steps.probe-mirror.outputs.mirror != 'absent'"
check 'checkout: runs in plain mode, and in Gerrit mode with a mirror' \
  "$(step_value checkout if)" \
  "steps.select-mode.outputs.mode == 'plain' || steps.probe-mirror.outputs.mirror != 'absent'"
# A workflow expression, matched as text
# shellcheck disable=SC2016
SELECTED_REF='${{ steps.select-mode.outputs.ref }}'
check 'checkout: ref chosen by select-mode' \
  "$(step_value checkout ref)" "$SELECTED_REF"
check 'checkout: credentials persist in Gerrit mode, else as asked' \
  "$(step_value checkout persist-credentials)" \
  "\${{ $GERRIT_ONLY || steps.select-mode.outputs.persist-credentials == 'true' }}"
for input in fetch-depth fetch-tags filter repository token submodules; do
  check "checkout: passes $input" "$(step_value checkout "$input")" \
    "\${{ inputs.$input }}"
done
# An empty default lets actions/checkout choose the ref in plain mode;
# select-mode applies github.sha in Gerrit mode alone
check "inputs: ref defaults to empty" \
  "$(awk '/^  ref:$/ { r = 1; next } r && /^  [a-z]/ { exit }
    r && /^    default:/ { print; exit }' "$REPO_ROOT/action.yaml")" \
  '    default: ""'
# A workflow expression, matched as text
# shellcheck disable=SC2016
check 'select-mode: the Gerrit-mode fallback is github.sha' \
  "$(step_value select-mode DEFAULT_REF)" '${{ github.sha }}'
# Workflow expressions, matched as text
# shellcheck disable=SC2016
check 'select-mode: compares repository with github.repository' \
  "$(step_value select-mode INPUT_REPOSITORY) $(step_value select-mode CALLER_REPOSITORY)" \
  '${{ inputs.repository }} ${{ github.repository }}'
check 'plain-checkout: runs in plain mode alone' \
  "$(step_value plain-checkout if)" "steps.select-mode.outputs.mode == 'plain'"
check 'gerrit-checkout: ref chosen by select-mode' \
  "$(step_value gerrit-checkout INPUT_REF)" "$SELECTED_REF"
check 'remove-credentials: whenever the checkout started, in Gerrit mode, when asked' \
  "$(step_value remove-credentials if)" \
  "always() && $GERRIT_ONLY && steps.select-mode.outputs.persist-credentials == 'false' && steps.checkout.outcome != 'skipped' && steps.checkout.outcome != ''"

echo
echo '### Mode selection'

REFSPEC='' select_mode
check 'no refspec: succeeds' "$(outcome)" 'succeeded'
check 'no refspec: plain mode' "$(output mode)" 'plain'
check 'no refspec: ref as given' "$(output ref)" 'caller-sha'
check 'no refspec: credentials persist by default' \
  "$(output persist-credentials)" 'true'

REFSPEC=' ' select_mode
check 'blank refspec: plain mode' "$(output mode)" 'plain'

REFSPEC='' REF='' select_mode
check 'plain mode, empty ref: passed on empty' "$(output ref)" ''

REFSPEC='' PROJECT='' BRANCH='main' REF='' select_mode
check 'plain mode: no gerrit-project needed' "$(outcome)" 'succeeded'
check 'plain mode: gerrit-branch ignored' "$(output ref)" ''

REFSPEC='refs/changes/40/11540/1' PROJECT='releng/x' select_mode
check 'refspec: succeeds' "$(outcome)" 'succeeded'
check 'refspec: Gerrit mode' "$(output mode)" 'gerrit'
check 'Gerrit mode, no gerrit-branch: ref as given' \
  "$(output ref)" 'caller-sha'

REFSPEC='refs/changes/40/11540/1' PROJECT='releng/x' BRANCH='stable/x' \
  select_mode
check 'Gerrit mode, gerrit-branch: its branch in place of ref' \
  "$(output ref)" 'refs/heads/stable/x'

REFSPEC='refs/changes/40/11540/1' PROJECT='releng/x' BRANCH=' ' \
  select_mode
check 'Gerrit mode, blank gerrit-branch: ref as given' \
  "$(output ref)" 'caller-sha'

for ref in '' ' '; do
  REFSPEC='refs/changes/40/11540/1' PROJECT='releng/x' REF="$ref" \
    select_mode
  check "Gerrit mode, ref '$ref': the triggering commit" \
    "$(output ref)" 'trigger-sha'
done

REFSPEC='refs/changes/40/11540/1' PROJECT='releng/x' BRANCH='stable/x' \
  REF='' select_mode
check 'Gerrit mode, empty ref, gerrit-branch: its branch' \
  "$(output ref)" 'refs/heads/stable/x'

# github.sha exists only in the calling repository, which
# actions/checkout also reads an empty 'repository' as
for repository in 'Org/Caller' ' ORG/CALLER ' ''; do
  REFSPEC='refs/changes/40/11540/1' REPOSITORY="$repository" REF='' \
    select_mode
  check "Gerrit mode, empty ref, repository '$repository': the triggering commit" \
    "$(output ref)" 'trigger-sha'
done

# Another repository, as in plain mode, leaves the choice to
# actions/checkout: its default branch
REFSPEC='refs/changes/40/11540/1' REPOSITORY='org/other' REF='' select_mode
check 'Gerrit mode, empty ref, another repository: succeeds' \
  "$(outcome)" 'succeeded'
check 'Gerrit mode, empty ref, another repository: passed on empty' \
  "$(output ref)" ''

REFSPEC='refs/changes/40/11540/1' REPOSITORY='org/other' REF='main' \
  select_mode
check 'Gerrit mode, another repository: ref as given' "$(output ref)" 'main'

REFSPEC='refs/changes/40/11540/1' REPOSITORY='org/other' BRANCH='stable/x' \
  REF='' select_mode
check 'Gerrit mode, another repository, gerrit-branch: its branch' \
  "$(output ref)" 'refs/heads/stable/x'

# As in v1.3.0, gerrit-refspec alone selects Gerrit mode: a mirror
# serves the change without gerrit-project, so only gerrit-checkout,
# where Gerrit serves it, requires the input
check 'select-mode: gerrit-project not passed' \
  "$(step_value select-mode INPUT_GERRIT_PROJECT)" ''
for project in '' ' '; do
  REFSPEC='refs/changes/40/11540/1' PROJECT="$project" select_mode
  check "Gerrit mode, gerrit-project '$project': succeeds" \
    "$(outcome)" 'succeeded'
  check "Gerrit mode, gerrit-project '$project': Gerrit mode" \
    "$(output mode)" 'gerrit'
  check "Gerrit mode, gerrit-project '$project': no error" "$(errors)" ''
done

REF=$'main\n::warning::x' select_mode
check 'ref with a line break: fails' "$(outcome)" 'failed'
check 'ref with a line break: no outputs written' "$(cat "$WORK/output")" ''
check 'ref with a line break: annotation escaped' "$(errors)" \
  "::error::Invalid ref: 'main%0A::warning::x' (contains a line break)"

REF=$' main\n\tx \r\n' select_mode
check 'ref with a line break inside, whitespace around: fails' \
  "$(outcome)" 'failed'

# actions/checkout trims 'ref', so a YAML folded scalar's trailing
# newline, or whitespace around the value, must pass and be passed on
# trimmed, in either mode
for ref in $'main\n' $'main\r\n' $' \tmain \n' $'\nmain'; do
  label=$(printf '%q' "$ref")
  REF="$ref" select_mode
  check "plain mode, ref $label: succeeds" "$(outcome)" 'succeeded'
  check "plain mode, ref $label: trimmed" "$(output ref)" 'main'
  check "plain mode, ref $label: three outputs, no stray line" \
    "$(wc -l < "$WORK/output")" '3'
  REFSPEC='refs/changes/40/11540/1' PROJECT='releng/x' REF="$ref" \
    select_mode
  check "Gerrit mode, ref $label: trimmed" "$(output ref)" 'main'
done

REFSPEC='' REF=$'\n' select_mode
check 'plain mode, ref of a line break alone: passed on empty' \
  "$(output ref)" ''

# actions/checkout trims the input and reads 'true' in any letter case
# as true, and anything else as false
for case in 'true:true' 'TRUE:true' ' True :true' 'false:false' \
  ' FALSE :false' ':false' 'no:false'; do
  PERSIST="${case%:*}" select_mode
  check "persist-credentials '${case%:*}': ${case##*:}" \
    "$(output persist-credentials)" "${case##*:}"
done

echo
echo '### Credential removal'

# A repository with a nested submodule, as actions/checkout leaves it
# with persist-credentials: true, plus configuration it never writes.
REMOTES="$WORK/remotes"
mkdir -p "$REMOTES" "$WORK/runner-temp"
for name in leaf sub super; do
  git init -q "$WORK/src-$name"
  printf '%s\n' "$name" > "$WORK/src-$name/content.txt"
  case "$name" in
    sub) git -C "$WORK/src-$name" -c protocol.file.allow=always \
           submodule add -q "$REMOTES/leaf.git" leaf ;;
    super) git -C "$WORK/src-$name" -c protocol.file.allow=always \
             submodule add -q "$REMOTES/sub.git" sub ;;
  esac
  git -C "$WORK/src-$name" add -A
  git -C "$WORK/src-$name" commit -qm "$name"
  git clone -q --bare "$WORK/src-$name" "$REMOTES/$name.git"
done
git clone -q --recurse-submodules "$REMOTES/super.git" "$WORK/ws"

SERVER=https://github.example
KEY="http.$SERVER/.extraheader"
persist() {
  local gitdir="$1" file="$WORK/runner-temp/git-credentials-$2.config"
  printf '[http "%s/"]\n\textraheader = AUTHORIZATION: basic secret\n' \
    "$SERVER" > "$file"
  git --git-dir="$gitdir" config --local "$KEY" 'AUTHORIZATION: basic secret'
  git --git-dir="$gitdir" config --local --add \
    "includeIf.gitdir:$gitdir.path" "$file"
  git --git-dir="$gitdir" config --local --add \
    "includeIf.gitdir:/github/workspace/.git.path" \
    "/github/runner_temp/git-credentials-$2.config"
}
SUPER_DIR="$WORK/ws/.git"
SUB_DIR="$WORK/ws/.git/modules/sub"
LEAF_DIR="$WORK/ws/.git/modules/sub/modules/leaf"
persist "$SUPER_DIR" 0a1b2c3d-0000-4000-8000-000000000001
persist "$SUB_DIR" 0a1b2c3d-0000-4000-8000-000000000002
persist "$LEAF_DIR" 0a1b2c3d-0000-4000-8000-000000000003
git -C "$WORK/ws" config --local includeIf.gitdir:/elsewhere/.path "$WORK/own.config"
git -C "$WORK/ws" config --local http.https://other.example/.extraheader 'X-Other: kept'

# Every credential setting left in the git config at $1
credentials() {
  { git --git-dir="$1" config --local --get-all "$KEY" || true
    git --git-dir="$1" config --local --get-regexp '^includeif\.' |
      grep 'git-credentials-' || true
  } 2> /dev/null
}

run_step remove-credentials "$WORK/ws" \
  SERVER_URL="$SERVER/" RUNNER_TEMP="$WORK/runner-temp"
check 'removal: succeeds' "$(outcome)" 'succeeded'
check 'removal: none left in the repository' "$(credentials "$SUPER_DIR")" ''
check 'removal: none left in the submodule' "$(credentials "$SUB_DIR")" ''
check 'removal: none left in the nested submodule' \
  "$(credentials "$LEAF_DIR")" ''
check 'removal: credential files under RUNNER_TEMP deleted' \
  "$(find "$WORK/runner-temp" -name 'git-credentials-*' | wc -l)" 0
check 'removal: other includeIf entries kept' \
  "$(git -C "$WORK/ws" config --local --get includeIf.gitdir:/elsewhere/.path)" \
  "$WORK/own.config"
check 'removal: headers for other servers kept' \
  "$(git -C "$WORK/ws" config --local --get http.https://other.example/.extraheader)" \
  'X-Other: kept'
check 'removal: the token appears nowhere in the clone' \
  "$(grep -rl 'basic secret' "$WORK/ws/.git" | wc -l)" 0

run_step remove-credentials "$WORK/ws" \
  SERVER_URL="$SERVER" RUNNER_TEMP="$WORK/runner-temp"
check 'removal again: nothing to remove, succeeds' "$(outcome)" 'succeeded'
check 'removal again: says there was nothing to remove' \
  "$(tail -n 1 "$WORK/log")" 'No persisted checkout credentials to remove'

# actions/checkout supports Git 2.18 and later; 'git config
# --fixed-value' needs 2.30. This git rejects that option, as an older
# one does, so removal must not depend on it.
OLD_GIT="$WORK/old-git"
mkdir -p "$OLD_GIT"
cat > "$OLD_GIT/git" << EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = --fixed-value ]; then
    echo "error: unknown option \\\`fixed-value'" >&2
    exit 129
  fi
done
exec $(command -v git) "\$@"
EOF
chmod +x "$OLD_GIT/git"
persist "$SUPER_DIR" 0a1b2c3d-0000-4000-8000-000000000008
persist "$SUB_DIR" 0a1b2c3d-0000-4000-8000-000000000009
rc=0
PATH="$OLD_GIT:$PATH" git config --fixed-value --get-all "$KEY" x \
  > /dev/null 2>&1 || rc=$?
check 'Git before 2.30: the stand-in rejects --fixed-value' "$(outcome)" 'failed'
run_step remove-credentials "$WORK/ws" PATH="$OLD_GIT:$PATH" \
  SERVER_URL="$SERVER" RUNNER_TEMP="$WORK/runner-temp"
check 'Git before 2.30: removal succeeds' "$(outcome)" 'succeeded'
check 'Git before 2.30: none left in the repository' \
  "$(credentials "$SUPER_DIR")" ''
check 'Git before 2.30: none left in the submodule' \
  "$(credentials "$SUB_DIR")" ''
check 'Git before 2.30: credential files deleted' \
  "$(find "$WORK/runner-temp" -name 'git-credentials-*' | wc -l)" 0

# Each value is removed exactly, as --fixed-value would: a credential
# path holding regular expression characters takes out that value and
# not another one its unescaped pattern would match
META_ID=0a1b2c3d-0000-4000-8000-00000000000a
META_KEY='includeIf.gitdir:/meta/.git.path'
META_CRED="/tmp/a+b (1)/git-credentials-$META_ID.config"
META_KEPT="/tmp/ab (1)/git-credentials-${META_ID}xconfig"
git -C "$WORK/ws" config --local --add "$META_KEY" "$META_KEPT"
git -C "$WORK/ws" config --local --add "$META_KEY" "$META_CRED"
run_step remove-credentials "$WORK/ws" \
  SERVER_URL="$SERVER" RUNNER_TEMP="$WORK/runner-temp"
check 'exact values: removal succeeds' "$(outcome)" 'succeeded'
check 'exact values: only the credential path removed' \
  "$(git -C "$WORK/ws" config --local --get-all "$META_KEY")" "$META_KEPT"
git -C "$WORK/ws" config --local --unset-all "$META_KEY"

# A change that breaks .gitmodules must not keep any token in place:
# submodules are found from .git/modules, not from that file
persist "$SUPER_DIR" 0a1b2c3d-0000-4000-8000-000000000004
persist "$SUB_DIR" 0a1b2c3d-0000-4000-8000-000000000005
persist "$LEAF_DIR" 0a1b2c3d-0000-4000-8000-000000000006
cp "$WORK/ws/.gitmodules" "$WORK/gitmodules.saved"
printf '[submodule "sub"\n\tpath = sub\n[broken\n' > "$WORK/ws/.gitmodules"
rc=0
git -C "$WORK/ws" submodule foreach --quiet --recursive true \
  > /dev/null 2>&1 || rc=$?
check 'malformed .gitmodules: git submodule cannot read it' \
  "$(outcome)" 'failed'
run_step remove-credentials "$WORK/ws" \
  SERVER_URL="$SERVER" RUNNER_TEMP="$WORK/runner-temp"
check 'malformed .gitmodules: removal succeeds' "$(outcome)" 'succeeded'
check 'malformed .gitmodules: none left in the repository' \
  "$(credentials "$SUPER_DIR")" ''
check 'malformed .gitmodules: none left in the submodule' \
  "$(credentials "$SUB_DIR")" ''
check 'malformed .gitmodules: none left in the nested submodule' \
  "$(credentials "$LEAF_DIR")" ''
check 'malformed .gitmodules: credential files deleted' \
  "$(find "$WORK/runner-temp" -name 'git-credentials-*' | wc -l)" 0
check 'malformed .gitmodules: the token appears nowhere in the clone' \
  "$(grep -rl 'basic secret' "$WORK/ws/.git" | wc -l)" 0
cp "$WORK/gitmodules.saved" "$WORK/ws/.gitmodules"

# A Windows runner writes native paths, in any letter case. Here such a
# path is relative, so the files sit under the working directory.
WIN_ID=0a1b2c3d-0000-4000-8000-000000000007
WIN_IN="D:\\a\\_temp\\git-credentials-$WIN_ID.config"
WIN_OUT="D:\\a\\_temp-other\\git-credentials-$WIN_ID.config"
mkdir -p "$WORK/ws/D:/a/_temp" "$WORK/ws/D:/a/_temp-other"
touch "$WORK/ws/D:/a/_temp/git-credentials-$WIN_ID.config" \
  "$WORK/ws/D:/a/_temp-other/git-credentials-$WIN_ID.config"
git --git-dir="$SUPER_DIR" config --local --add \
  'includeIf.gitdir:D:/a/repo/.git.path' "$WIN_IN"
git --git-dir="$SUPER_DIR" config --local --add \
  'includeIf.gitdir:D:/a/other/.git.path' "$WIN_OUT"
run_step remove-credentials "$WORK/ws" \
  SERVER_URL="$SERVER" RUNNER_TEMP="d:\\A\\_Temp\\"
check 'Windows paths: removal succeeds' "$(outcome)" 'succeeded'
check 'Windows paths: includeIf entries removed' \
  "$(credentials "$SUPER_DIR")" ''
check 'Windows paths: file under RUNNER_TEMP deleted, case aside' \
  "$(find "$WORK/ws/D:/a/_temp" -name 'git-credentials-*' | wc -l)" 0
check 'Windows paths: file beside RUNNER_TEMP kept' \
  "$(find "$WORK/ws/D:/a/_temp-other" -name 'git-credentials-*' | wc -l)" 1

mkdir -p "$WORK/empty"
run_step remove-credentials "$WORK/empty" \
  SERVER_URL="$SERVER" RUNNER_TEMP="$WORK/runner-temp"
check 'removal without a repository: succeeds' "$(outcome)" 'succeeded'

echo
echo "Passed: $passed, failed: $failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
