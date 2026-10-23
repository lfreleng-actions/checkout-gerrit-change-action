#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Checks the path a Gerrit change takes when the project has no GitHub
# mirror. probe-mirror asks the GitHub API whether the mirror exists;
# on a 404, gerrit-fallback points the workspace at Gerrit and asks it
# for the change, and gerrit-checkout fetches it from there. A project
# Gerrit will not serve anonymously fails the step, or with
# on-unavailable: skip leaves the workspace empty, so callers can skip
# their checks rather than vote on a tree that is not the change.
#
# Each step comes out of action.yaml, its 'shell:' included, and runs
# the way the runner runs it, as in submodule-refresh.sh. It needs git,
# ruby (for the YAML parser) and python3 (for a stub HTTP server on the
# loopback interface standing in for the GitHub API and for a Gerrit
# that refuses anonymous reads). A readable Gerrit project is a local
# bare repository.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${REPO_ROOT}/action.yaml"
WORK="$(mktemp -d)"
SERVER_PID=''
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2> /dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Keep the caller's git configuration (signing, hooks, URL rewrites,
# credentials) out of the fixtures.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT GIT_ASKPASS SSH_ASKPASS
export HOME="$WORK/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
git config --global user.name 'Fallback Test'
git config --global user.email 'test@example.invalid'
git config --global init.defaultBranch main
git config --global commit.gpgSign false
git config --global advice.detachedHead false
git config --global protocol.file.allow always

### The steps under test ###

# Write step $1's script to $WORK/$1.sh and its command line, with the
# script in place of '{0}', to $WORK/$1.cmd, one word per line. The
# runner expands the 'bash' keyword to the command below.
extract() {
  local id="$1" shell
  ruby -ryaml -e '
    steps = YAML.safe_load(File.read(ARGV[0])).dig("runs", "steps")
    step = steps.find { |s| s["id"] == ARGV[1] }
    abort "No step with id #{ARGV[1]} in #{ARGV[0]}" unless step
    File.write(ARGV[2], step.fetch("run"))
    File.write(ARGV[3], step.fetch("shell", "bash"))
  ' "$ACTION" "$id" "$WORK/$id.sh" "$WORK/$id.shell"
  shell="$(cat "$WORK/$id.shell")"
  case "$shell" in
    bash) shell='bash --noprofile --norc -eo pipefail {0}' ;;
    *'{0}'*) ;;
    *)
      echo "Unsupported shell for $id: $shell" >&2
      exit 1
      ;;
  esac
  read -ra words <<< "$shell"
  for i in "${!words[@]}"; do
    if [ "${words[i]}" = '{0}' ]; then
      words[i]="$WORK/$id.sh"
    fi
  done
  printf '%s\n' "${words[@]}" > "$WORK/$id.cmd"
}

for id in probe-mirror gerrit-fallback gerrit-checkout; do
  extract "$id"
done

# Run step $1 in directory $2 with the environment that follows, the
# way the runner does: fresh GITHUB_OUTPUT and GITHUB_STEP_SUMMARY
# files, output and exit status captured for the checks.
run_step() {
  local id="$1" dir="$2" cmd=()
  shift 2
  mapfile -t cmd < "$WORK/$id.cmd"
  : > "$WORK/output"
  : > "$WORK/summary"
  rc=0
  (
    cd "$dir"
    env GITHUB_OUTPUT="$WORK/output" GITHUB_STEP_SUMMARY="$WORK/summary" \
      "$@" "${cmd[@]}"
  ) > "$WORK/log" 2>&1 || rc=$?
}

# The value step output $1 was set to, or nothing
output() {
  sed -n "s/^$1=//p" "$WORK/output"
}

### Fixtures ###

# A server that records each request it receives, so a check can see
# whether one was made at all. Under /api it answers as the GitHub API
# does for a repository that exists, does not, or errors, and records
# each request's path and Authorization header. Under /restricted and
# /absent it answers as Gerrit does when anonymous users may not read a
# project (401, asking for credentials) or when the project does not
# exist (403). Any other path, /not-found included, answers 404, which
# a Gerrit can also return for a hidden or absent project.
cat > "$WORK/server.py" << 'EOF'
import http.server
import sys

LOG = sys.argv[1]
PORT_FILE = sys.argv[2]
API = {"present": 200, "missing": 404, "broken": 500}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        status = 404
        headers = {}
        with open(LOG, "a") as log:
            log.write(f"{path} {self.headers.get('Authorization', '-')}\n")
        if path.startswith("/api/repos/"):
            status = API.get(path.rsplit("/", 1)[-1], 404)
        elif path.startswith("/restricted/"):
            status = 401
            headers["WWW-Authenticate"] = 'Basic realm="Gerrit Code Review"'
        elif path.startswith("/absent/"):
            status = 403
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
EOF
python3 "$WORK/server.py" "$WORK/requests.log" "$WORK/port" &
SERVER_PID=$!
for _ in $(seq 50); do
  [ -s "$WORK/port" ] && break
  sleep 0.1
done
if [ ! -s "$WORK/port" ]; then
  echo 'The stub server did not start' >&2
  exit 1
fi
STUB="http://127.0.0.1:$(cat "$WORK/port")"
API_URL="$STUB/api"
: > "$WORK/requests.log"

# A port nothing listens on: bind one, then let it go
CLOSED_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')"

# A readable Gerrit project: a branch of three commits, and a change on
# top of it published only to Gerrit
GERRIT_URL="file://$WORK/gerrit"
PROJECT='releng/project'
REFSPEC='refs/changes/42/1042/3'
git init -q --bare "$WORK/gerrit/$PROJECT"
git init -q "$WORK/src"
for n in 1 2 3; do
  printf '%s\n' "$n" > "$WORK/src/content.txt"
  git -C "$WORK/src" add content.txt
  git -C "$WORK/src" commit -qm "commit $n"
done
git -C "$WORK/src" push -q "$GERRIT_URL/$PROJECT" HEAD:refs/heads/main
BASE="$(git -C "$WORK/src" rev-parse HEAD)"
# A branch and a tag outside the change's ancestry, which only a
# fetch-depth 0 checkout should bring in
git -C "$WORK/src" checkout -q -b other HEAD~2
printf 'other\n' > "$WORK/src/other.txt"
git -C "$WORK/src" add other.txt
git -C "$WORK/src" commit -qm 'other branch'
git -C "$WORK/src" tag -a -m 'v9.9.9' v9.9.9
git -C "$WORK/src" push -q "$GERRIT_URL/$PROJECT" HEAD:refs/heads/other v9.9.9
git -C "$WORK/src" checkout -q main
printf 'change\n' > "$WORK/src/content.txt"
git -C "$WORK/src" commit -qam 'the change'
git -C "$WORK/src" push -q "$GERRIT_URL/$PROJECT" "HEAD:$REFSPEC"
CHANGE="$(git -C "$WORK/src" rev-parse HEAD)"

# A local repository standing in for GitHub, holding a public
# submodule, and two changes adding a submodule: one by its SSH URL,
# which a runner without an SSH key reaches only through the HTTPS
# rewrite, and one on the stub server, which records whether the token
# arrives with the request
GITHUB="$WORK/github"
git init -q --bare "$GITHUB/org/sub.git"
git init -q "$WORK/sub"
printf 'sub\n' > "$WORK/sub/sub.txt"
git -C "$WORK/sub" add sub.txt
git -C "$WORK/sub" commit -qm sub
git -C "$WORK/sub" push -q "file://$GITHUB/org/sub.git" HEAD:refs/heads/main
SUB="$(git -C "$WORK/sub" rev-parse HEAD)"

# Publish to Gerrit, at refspec $1, a child of the branch tip that adds
# submodule 'sub' from URL $2
add_submodule_change() {
  git -C "$WORK/src" checkout -q --detach "$BASE"
  git -C "$WORK/src" config -f .gitmodules submodule.sub.path sub
  git -C "$WORK/src" config -f .gitmodules submodule.sub.url "$2"
  git -C "$WORK/src" add .gitmodules
  git -C "$WORK/src" update-index --add --cacheinfo "160000,$SUB,sub"
  git -C "$WORK/src" commit -qm "add sub from $2"
  git -C "$WORK/src" push -q "$GERRIT_URL/$PROJECT" "HEAD:$1"
}
SSH_REFSPEC='refs/changes/43/1043/1'
add_submodule_change "$SSH_REFSPEC" "git@$GITHUB:org/sub.git"
PRIVATE_REFSPEC='refs/changes/44/1044/1'
add_submodule_change "$PRIVATE_REFSPEC" "$STUB/github/org/private.git"
# What actions/checkout sends: the token as a basic credential
WANT_AUTH="basic $(printf 'x-access-token:%s' 'test-token' | base64 | tr -d '\n')"

# A workspace holding leftovers, which the fallback must clear the way
# actions/checkout clears a workspace it does not recognise
new_workspace() {
  rm -rf "$WORK/ws"
  mkdir -p "$WORK/ws/stale"
  printf 'stale\n' > "$WORK/ws/stale/file.txt"
  printf 'stale\n' > "$WORK/ws/.hidden"
}

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
    echo '--- step output ---'
    cat "$WORK/log"
    echo '---'
  fi
}

outcome() {
  if [ "$rc" -eq 0 ]; then echo 'succeeded'; else echo 'failed'; fi
}

errors() {
  grep '^::error::' "$WORK/log" || true
}

# probe-mirror with the given repository, gerrit-url and on-unavailable
probe() {
  : > "$WORK/requests.log"
  run_step probe-mirror "$WORK" \
    INPUT_REPOSITORY="$1" INPUT_GERRIT_URL="$2" INPUT_ON_UNAVAILABLE="$3" \
    INPUT_TOKEN='test-token' API_URL="$API_URL"
}

echo '### probe-mirror'

probe org/present "$GERRIT_URL" fail
check 'existing mirror: step succeeds' "$(outcome)" 'succeeded'
check 'existing mirror: mirror is present' "$(output mirror)" 'present'
check 'existing mirror: on-unavailable passes through' \
  "$(output on-unavailable)" 'fail'
check 'existing mirror: API sees the token as a bearer token' \
  "$(cat "$WORK/requests.log")" '/api/repos/org/present Bearer test-token'

probe org/missing "$GERRIT_URL" fail
check 'missing mirror: step succeeds' "$(outcome)" 'succeeded'
check 'missing mirror: mirror is absent' "$(output mirror)" 'absent'

probe org/broken "$GERRIT_URL" fail
check 'API error: mirror path kept' "$(output mirror)" 'present'

: > "$WORK/requests.log"
run_step probe-mirror "$WORK" INPUT_REPOSITORY=org/missing \
  INPUT_GERRIT_URL="$GERRIT_URL" INPUT_ON_UNAVAILABLE=fail \
  INPUT_TOKEN='test-token' API_URL="http://127.0.0.1:$CLOSED_PORT"
check 'API unreachable: step succeeds' "$(outcome)" 'succeeded'
check 'API unreachable: mirror path kept' "$(output mirror)" 'present'

probe org/missing '' fail
check 'no gerrit-url: mirror path kept' "$(output mirror)" 'present'
check 'no gerrit-url: no API request' "$(cat "$WORK/requests.log")" ''

for bad in '../missing' 'org/..' './missing' 'org'; do
  probe "$bad" "$GERRIT_URL" fail
  check "malformed repository '$bad': mirror path kept" \
    "$(output mirror)" 'present'
  check "malformed repository '$bad': no API request" \
    "$(cat "$WORK/requests.log")" ''
done

probe org/present "$GERRIT_URL" ' SKIP '
check 'padded, upper-case on-unavailable: normalised' \
  "$(output on-unavailable)" 'skip'

probe org/present "$GERRIT_URL" maybe
check 'invalid on-unavailable: step fails' "$(outcome)" 'failed'
check 'invalid on-unavailable: step reports it' "$(errors)" \
  "::error::Invalid on-unavailable input: 'maybe' (expected fail or skip)"

# gerrit-fallback with the given gerrit-url, project, refspec and
# on-unavailable (as probe-mirror normalised it), in a fresh workspace.
# REF and DEPTH, when set, stand in for the ref and fetch-depth inputs.
fallback() {
  new_workspace
  run_step gerrit-fallback "$WORK/ws" \
    INPUT_GERRIT_URL="$1" INPUT_GERRIT_PROJECT="$2" \
    INPUT_GERRIT_REFSPEC="$3" ON_UNAVAILABLE="$4" \
    INPUT_REF="${REF-refs/heads/main}" INPUT_FETCH_DEPTH="${DEPTH-2}"
}

# gerrit-checkout in the workspace the fallback prepared. CHANGE_REF,
# SUBMODULES, FALLBACK and SERVER, when set, stand in for the refspec,
# the submodules input, the fallback's verdict and github.server_url.
checkout() {
  run_step gerrit-checkout "$WORK/ws" \
    INPUT_GERRIT_URL="$GERRIT_URL" INPUT_GERRIT_PROJECT="$PROJECT" \
    INPUT_GERRIT_REFSPEC="${CHANGE_REF-$REFSPEC}" \
    INPUT_FETCH_DEPTH="${DEPTH-2}" INPUT_SUBMODULES="${SUBMODULES-false}" \
    INPUT_TOKEN='test-token' FALLBACK="${FALLBACK-true}" \
    SERVER_URL="${SERVER-https://github.com}"
}

# The refs a workspace holds, other than HEAD, one per line
refs() {
  git -C "$WORK/ws" for-each-ref --format='%(refname)' | LC_ALL=C sort
}

safe_directories() {
  git config --global --get-all safe.directory || true
}

echo
echo '### gerrit-fallback, then gerrit-checkout'

fallback "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
check 'readable project: fallback succeeds' "$(outcome)" 'succeeded'
check 'readable project: change available' "$(output available)" 'true'
check 'readable project: leftovers cleared' \
  "$(find "$WORK/ws" -mindepth 1 -maxdepth 1 ! -name .git | wc -l | tr -d ' ')" 0
check 'readable project: origin is the Gerrit project' \
  "$(git -C "$WORK/ws" config --get remote.origin.url)" "$GERRIT_URL/$PROJECT"
check 'readable project: workspace marked as a safe directory' \
  "$(safe_directories)" "$(cd "$WORK/ws" && pwd -P)"
check 'readable project: ref fetched as origin/main' \
  "$(refs)" 'refs/remotes/origin/main'
check 'readable project: ref fetched at fetch-depth' \
  "$(git -C "$WORK/ws" rev-list --count refs/remotes/origin/main)" 2
checkout
check 'readable project: checkout succeeds' "$(outcome)" 'succeeded'
check 'readable project: checked-out output set' \
  "$(output checked-out)" 'true'
check 'readable project: HEAD is the change' \
  "$(git -C "$WORK/ws" rev-parse HEAD)" "$CHANGE"
check 'readable project: parent reachable for HEAD~1' \
  "$(git -C "$WORK/ws" rev-parse HEAD~1)" "$BASE"
check 'readable project: history limited to fetch-depth' \
  "$(git -C "$WORK/ws" rev-list --count HEAD)" 2

fallback "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
check 'second run: safe directory not added again' \
  "$(safe_directories)" "$(cd "$WORK/ws" && pwd -P)"

DEPTH=0 fallback "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
DEPTH=0 checkout
check 'fetch-depth 0: every branch and tag fetched' "$(refs)" \
  "$(printf '%s\n' refs/remotes/origin/main refs/remotes/origin/other refs/tags/v9.9.9)"
check 'fetch-depth 0: full history' \
  "$(git -C "$WORK/ws" rev-list --count HEAD)" 4
check 'fetch-depth 0: not shallow' \
  "$(git -C "$WORK/ws" rev-parse --is-shallow-repository)" 'false'

REF="$BASE" fallback "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
check 'ref naming a commit: no base fetched' "$(refs)" ''
checkout
check 'ref naming a commit: HEAD is the change' \
  "$(git -C "$WORK/ws" rev-parse HEAD)" "$CHANGE"
check 'ref naming a commit: parent reachable for HEAD~1' \
  "$(git -C "$WORK/ws" rev-parse HEAD~1)" "$BASE"

REF=refs/heads/no-such-branch fallback "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
check 'ref naming a missing branch: step fails' "$(outcome)" 'failed'

# Config the checkout must not leave behind, in the superproject or a
# submodule
persisted() {
  for dir in "$WORK/ws" "$WORK/ws/sub"; do
    if [ -e "$dir/.git" ]; then
      git -C "$dir" config --local --get-regexp 'extraheader|insteadof' || true
    fi
  done
}

fallback "$GERRIT_URL" "$PROJECT" "$SSH_REFSPEC" fail
CHANGE_REF="$SSH_REFSPEC" SUBMODULES=true SERVER="file://$GITHUB" checkout
check 'submodule by SSH URL: checkout succeeds' "$(outcome)" 'succeeded'
check 'submodule by SSH URL: populated over the HTTPS rewrite' \
  "$(git -C "$WORK/ws/sub" rev-parse HEAD 2> /dev/null)" "$SUB"
check 'submodule by SSH URL: no config left behind' "$(persisted)" ''

fallback "$GERRIT_URL" "$PROJECT" "$PRIVATE_REFSPEC" fail
: > "$WORK/requests.log"
CHANGE_REF="$PRIVATE_REFSPEC" SUBMODULES=true SERVER="$STUB/github" checkout
check 'submodule on GitHub: token sent with the request' \
  "$(sed -n 's#^/github/org/private.git/info/refs ##p' "$WORK/requests.log" | sort -u)" \
  "$WANT_AUTH"
check 'submodule on GitHub: no config left behind' "$(persisted)" ''
check 'submodule on GitHub: token masked in the log' \
  "$(grep -c "^::add-mask::${WANT_AUTH#basic }\$" "$WORK/log")" 1
check 'submodule on GitHub: token absent from the trace' \
  "$(grep -c -e 'test-token' -e "${WANT_AUTH#basic }" "$WORK/log" | tr -d ' ')" 1

fallback "$GERRIT_URL" "$PROJECT" "$PRIVATE_REFSPEC" fail
: > "$WORK/requests.log"
CHANGE_REF="$PRIVATE_REFSPEC" SUBMODULES=true SERVER="$STUB/github" \
  FALLBACK='' checkout
check 'mirror path: token not added by this step' \
  "$(sed -n 's#^/github/org/private.git/info/refs ##p' "$WORK/requests.log" | sort -u)" \
  '-'

# A translated git must not hide an unavailable project. In German, git
# words a 404 as "Repository '<url>/' nicht gefunden", which matches
# none of the English patterns, so the classifier depends on the step
# pinning the locale. Without the German locale or git's catalogue,
# git speaks English anyway and the check proves nothing; say so
# rather than pass. (grep reads all its input here: with -q it would
# stop at the match, and pipefail would fail the pipeline on the
# SIGPIPE that leaves 'locale -a'.)
if locale -a 2> /dev/null | grep -ix 'de_DE.utf-\{0,1\}8' > /dev/null &&
   [ "$(LANGUAGE=de LC_ALL=de_DE.UTF-8 git ls-remote -- "$STUB/nf" 2>&1 | grep -c 'nicht gefunden')" -gt 0 ]; then
  LANGUAGE=de LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 \
    fallback "$STUB/not-found" "$PROJECT" "$REFSPEC" skip
  check 'translated git, not-found project, skip: change unavailable' \
    "$(output available)" 'false'
else
  echo '⏭️  translated git: German locale or git catalogue absent, skipped'
fi

fallback "$GERRIT_URL/" "$PROJECT" "$REFSPEC" fail
check 'trailing slash on gerrit-url: no doubled slash' \
  "$(git -C "$WORK/ws" config --get remote.origin.url)" "$GERRIT_URL/$PROJECT"

fallback "$GERRIT_URL" "$PROJECT" 'refs/changes/99/1099/1' skip
check 'missing change: fails even with skip' "$(outcome)" 'failed'
check 'missing change: step reports it' "$(errors)" \
  "::error::Gerrit project $PROJECT has no refs/changes/99/1099/1"

UNAVAILABLE="Gerrit project $PROJECT has no GitHub mirror and refuses anonymous access, so $REFSPEC cannot be checked out"

for server in restricted absent not-found; do
  fallback "$STUB/$server" "$PROJECT" "$REFSPEC" fail
  check "$server project, fail: step fails" "$(outcome)" 'failed'
  check "$server project, fail: step reports it" "$(errors)" \
    "::error::$UNAVAILABLE"

  fallback "$STUB/$server" "$PROJECT" "$REFSPEC" skip
  check "$server project, skip: step succeeds" "$(outcome)" 'succeeded'
  check "$server project, skip: change unavailable" \
    "$(output available)" 'false'
  check "$server project, skip: workspace left empty" \
    "$(find "$WORK/ws" -mindepth 1 | wc -l | tr -d ' ')" 0
  check "$server project, skip: notice explains the skip" \
    "$(grep -c '^::notice title=Gerrit change not checked out::' "$WORK/log")" 1
  check "$server project, skip: job summary explains the skip" \
    "$(grep -c '^### Gerrit change not checked out' "$WORK/summary")" 1
done

fallback "file://$WORK/gerrit" 'no/such/project' "$REFSPEC" skip
check 'project missing from a file:// Gerrit, skip: change unavailable' \
  "$(output available)" 'false'

# A 401 to a request that already names a user leaves git asking for a
# password rather than a username: from a username-only gerrit-url, or
# a runner that configures credential.username
fallback "http://onlyuser@${STUB#http://}/restricted" "$PROJECT" "$REFSPEC" skip
check 'username-only gerrit-url, skip: change unavailable' \
  "$(output available)" 'false'
fallback "http://onlyuser@${STUB#http://}/restricted" "$PROJECT" "$REFSPEC" fail
check 'username-only gerrit-url, fail: step reports it' "$(errors)" \
  "::error::$UNAVAILABLE"
git config --global credential.username someone
fallback "$STUB/restricted" "$PROJECT" "$REFSPEC" skip
git config --global --unset credential.username
check 'credential.username configured, skip: change unavailable' \
  "$(output available)" 'false'

fallback "http://127.0.0.1:$CLOSED_PORT" "$PROJECT" "$REFSPEC" skip
check 'Gerrit unreachable: fails even with skip' "$(outcome)" 'failed'
check 'Gerrit unreachable: step reports the network error' \
  "$(errors | grep -c "Failed to connect")" 1

# Credentials embedded in gerrit-url reach Gerrit, but never .git/config
# or the log. The stub challenges with 401 and records what comes back.
CRED_URL="http://fallback-user:s3cr3t-pass@${STUB#http://}/restricted"
WANT_BASIC="Basic $(printf '%s' 'fallback-user:s3cr3t-pass' | base64 | tr -d '\n')"
sent_auth() {
  sed -n "s#^/restricted/$PROJECT/info/refs ##p" "$WORK/requests.log" |
    grep -v '^-$' | sort -u
}
secrets_in() {
  grep -rl 's3cr3t-pass' "$@" 2> /dev/null | wc -l | tr -d ' '
}

: > "$WORK/requests.log"
fallback "$CRED_URL" "$PROJECT" "$REFSPEC" fail
check 'gerrit-url with credentials: fallback sends them to Gerrit' \
  "$(sent_auth)" "$WANT_BASIC"
check 'gerrit-url with credentials: origin stored without them' \
  "$(git -C "$WORK/ws" config --get remote.origin.url)" \
  "$STUB/restricted/$PROJECT"
check 'gerrit-url with credentials: none under .git' "$(secrets_in "$WORK/ws/.git")" 0
check 'gerrit-url with credentials: none in the fallback log' \
  "$(secrets_in "$WORK/log")" 0

: > "$WORK/requests.log"
run_step gerrit-checkout "$WORK/ws" \
  INPUT_GERRIT_URL="$CRED_URL" INPUT_GERRIT_PROJECT="$PROJECT" \
  INPUT_GERRIT_REFSPEC="$REFSPEC" INPUT_FETCH_DEPTH=2 \
  INPUT_SUBMODULES=false INPUT_TOKEN='' FALLBACK=true SERVER_URL=''
check 'gerrit-url with credentials: checkout sends them to Gerrit' \
  "$(sent_auth)" "$WANT_BASIC"
check 'gerrit-url with credentials: still none under .git' \
  "$(secrets_in "$WORK/ws/.git")" 0
check 'gerrit-url with credentials: none in the checkout log' \
  "$(secrets_in "$WORK/log")" 0

echo
echo "Passed: $passed, failed: $failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
