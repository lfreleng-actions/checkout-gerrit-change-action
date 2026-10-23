#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Checks the path a Gerrit change takes when the project has no GitHub
# mirror. probe-mirror asks the GitHub API whether the mirror exists;
# on a 404, gerrit-checkout asks Gerrit for the project and the change,
# and only once Gerrit serves them sets the workspace up and checks the
# change out. A project closed to anonymous reads fails the step, or
# with on-unavailable: skip leaves the workspace as it was, so callers
# can skip their checks rather than vote on a tree that is not the
# change. Anything else Gerrit refuses fails either way.
#
# Each step comes out of action.yaml, its 'shell:' included, and runs
# the way the runner runs it, as in submodule-refresh.sh. It needs git,
# ruby (for the YAML parser) and python3, for a server on the loopback
# interface standing in for the GitHub API and for Gerrit: it serves
# repositories over smart HTTP through 'git http-backend', with and
# without a password, and answers 401, 403 and 404 the way Gerrit does.

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
# runner expands the 'bash' keyword to the command below; see
# src/Runner.Worker/Handlers/ScriptHandlerHelpers.cs in actions/runner.
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
    bash) shell='bash --noprofile --norc -e -o pipefail {0}' ;;
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

for id in probe-mirror gerrit-checkout; do
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

# The server records each request's path and Authorization header, so
# a check can see whether a request was made, and with what. It routes:
#   /api/repos/<owner>/<name>  the GitHub API: 'present' answers 200,
#                              'broken' 500, anything else 404
#   /git/<project>             Gerrit, serving anyone
#   /auth/<project>            Gerrit, serving only fallback-user with
#                              the password s3cr3t-pass
#   /digest/<project>          Gerrit, demanding Digest authentication:
#                              it serves a Digest response for
#                              fallback-user and challenges anything
#                              else, Basic included
#   /restricted/<project>      Gerrit, closed to anonymous reads: 401
#   /truncated/<project>       a 401 whose body the connection cuts
#                              short, as a dropped connection would
#   /absent/<project>          Gerrit, for a project that is hidden or
#                              does not exist: 403
#   anything else              404, which Gerrit can also answer for
#                              either of the last two
cat > "$WORK/server.py" << 'EOF'
import base64
import http.server
import os
import subprocess
import sys

LOG, PORT_FILE, GIT_ROOT = sys.argv[1:4]
API = {"present": 200, "broken": 500}
CREDENTIALS = "Basic " + base64.b64encode(b"fallback-user:s3cr3t-pass").decode()
CHALLENGE = {"WWW-Authenticate": 'Basic realm="Gerrit Code Review"'}
DIGEST_CHALLENGE = {
    "WWW-Authenticate": 'Digest realm="Gerrit Code Review", '
    'nonce="6e6f6e6365", qop="auth", algorithm=MD5'
}


class Handler(http.server.BaseHTTPRequestHandler):
    def route(self):
        path, _, query = self.path.partition("?")
        with open(LOG, "a") as log:
            log.write(f"{path} {self.headers.get('Authorization', '-')}\n")
        if path.startswith("/api/repos/"):
            return self.reply(API.get(path.rsplit("/", 1)[-1], 404))
        if path.startswith("/git/"):
            return self.backend(path[len("/git") :], query)
        if path.startswith("/auth/"):
            if self.headers.get("Authorization") != CREDENTIALS:
                return self.reply(401, CHALLENGE)
            return self.backend(path[len("/auth") :], query)
        if path.startswith("/digest/"):
            auth = self.headers.get("Authorization", "")
            if not (auth.startswith("Digest ") and 'username="fallback-user"' in auth):
                return self.reply(401, DIGEST_CHALLENGE)
            return self.backend(path[len("/digest") :], query)
        if path.startswith("/restricted/"):
            return self.reply(401, CHALLENGE)
        if path.startswith("/truncated/"):
            self.send_response(401)
            for name, value in CHALLENGE.items():
                self.send_header(name, value)
            self.send_header("Content-Length", "100")
            self.end_headers()
            self.close_connection = True
            return
        if path.startswith("/absent/"):
            return self.reply(403)
        return self.reply(404)

    do_GET = route
    do_POST = route

    def reply(self, status, headers=None, body=b""):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # Smart HTTP through git http-backend, as a CGI program
    def backend(self, path_info, query):
        length = int(self.headers.get("Content-Length") or 0)
        env = dict(
            os.environ,
            GIT_PROJECT_ROOT=GIT_ROOT,
            GIT_HTTP_EXPORT_ALL="1",
            REQUEST_METHOD=self.command,
            PATH_INFO=path_info,
            QUERY_STRING=query,
            CONTENT_TYPE=self.headers.get("Content-Type", ""),
            CONTENT_LENGTH=str(length),
            REMOTE_ADDR="127.0.0.1",
        )
        for header, name in (
            ("Content-Encoding", "HTTP_CONTENT_ENCODING"),
            ("Git-Protocol", "GIT_PROTOCOL"),
        ):
            if self.headers.get(header):
                env[name] = self.headers[header]
        result = subprocess.run(
            ["git", "http-backend"],
            input=self.rfile.read(length),
            env=env,
            capture_output=True,
        )
        head, sep, body = result.stdout.partition(b"\r\n\r\n")
        if not sep:
            head, _, body = result.stdout.partition(b"\n\n")
        status, headers = 200, {}
        for line in head.decode().splitlines():
            name, _, value = line.partition(":")
            if name.lower() == "status":
                status = int(value.split()[0])
            elif name and name.lower() != "content-length":
                headers[name] = value.strip()
        self.reply(status, headers, body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
EOF
mkdir -p "$WORK/gerrit"
python3 "$WORK/server.py" "$WORK/requests.log" "$WORK/port" "$WORK/gerrit" &
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
STUB_HOST="${STUB#http://}"
API_URL="$STUB/api"

# A port nothing listens on: bind one, then let it go
CLOSED_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')"

# A Gerrit project: a branch of three commits, and a change on top of
# it, published only to Gerrit. The fixtures push to it directly, and
# the step reaches it over HTTP.
GERRIT_URL="$STUB/git"
CRED_URL="http://fallback-user:s3cr3t-pass@$STUB_HOST/auth"
GERRIT_FILE="file://$WORK/gerrit"
PROJECT='releng/project'
REFSPEC='refs/changes/42/1042/3'
git init -q --bare "$WORK/gerrit/$PROJECT"
git init -q "$WORK/src"
for n in 1 2 3; do
  printf '%s\n' "$n" > "$WORK/src/content.txt"
  git -C "$WORK/src" add content.txt
  git -C "$WORK/src" commit -qm "commit $n"
done
git -C "$WORK/src" push -q "$GERRIT_FILE/$PROJECT" HEAD:refs/heads/main
BASE="$(git -C "$WORK/src" rev-parse HEAD)"
# A branch and a tag outside the change's ancestry, which only a
# fetch-depth 0 checkout should bring in
git -C "$WORK/src" checkout -q -b other HEAD~2
printf 'other\n' > "$WORK/src/other.txt"
git -C "$WORK/src" add other.txt
git -C "$WORK/src" commit -qm 'other branch'
git -C "$WORK/src" tag -a -m 'v9.9.9' v9.9.9
git -C "$WORK/src" push -q "$GERRIT_FILE/$PROJECT" HEAD:refs/heads/other v9.9.9
git -C "$WORK/src" checkout -q main
printf 'change\n' > "$WORK/src/content.txt"
git -C "$WORK/src" commit -qam 'the change'
git -C "$WORK/src" push -q "$GERRIT_FILE/$PROJECT" "HEAD:$REFSPEC"
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
  git -C "$WORK/src" push -q "$GERRIT_FILE/$PROJECT" "HEAD:$1"
}
SSH_REFSPEC='refs/changes/43/1043/1'
add_submodule_change "$SSH_REFSPEC" "git@$GITHUB:org/sub.git"
PRIVATE_REFSPEC='refs/changes/44/1044/1'
add_submodule_change "$PRIVATE_REFSPEC" "$STUB/github/org/private.git"
# What actions/checkout sends: the token as a basic credential
TOKEN_BASIC="$(printf 'x-access-token:%s' 'test-token' | base64 | tr -d '\n')"
# What a client sends for the password-protected Gerrit
GERRIT_BASIC="Basic $(printf '%s' 'fallback-user:s3cr3t-pass' | base64 | tr -d '\n')"

# A workspace holding what earlier steps might have left there. The
# checkout clears it the way actions/checkout clears a workspace it does
# not recognise, but only once Gerrit serves the change.
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

# What the workspace holds, '.git' aside, one entry per line
workspace_entries() {
  (cd "$WORK/ws" && find . -mindepth 1 -path ./.git -prune -o -print | LC_ALL=C sort)
}

UNTOUCHED="$(printf '%s\n' ./.hidden ./stale ./stale/file.txt)"

# Checks that the workspace is as new_workspace left it
check_untouched() {
  check "$1: workspace left as it was" "$(workspace_entries)" "$UNTOUCHED"
  check "$1: no repository created" "$(test -e "$WORK/ws/.git" && echo yes || echo no)" 'no'
}

safe_directories() {
  git config --global --get-all safe.directory || true
}

# probe-mirror with the given repository, gerrit-url and on-unavailable,
# called from the repository CALLER names (another one by default)
probe() {
  : > "$WORK/requests.log"
  run_step probe-mirror "$WORK" \
    INPUT_REPOSITORY="$1" INPUT_GERRIT_URL="$2" INPUT_ON_UNAVAILABLE="$3" \
    INPUT_TOKEN='test-token' CALLER_REPOSITORY="${CALLER-org/caller}" \
    API_URL="$API_URL"
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
check 'API error: retried once' "$(wc -l < "$WORK/requests.log" | tr -d ' ')" 2

: > "$WORK/requests.log"
run_step probe-mirror "$WORK" INPUT_REPOSITORY=org/missing \
  INPUT_GERRIT_URL="$GERRIT_URL" INPUT_ON_UNAVAILABLE=fail \
  INPUT_TOKEN='test-token' CALLER_REPOSITORY=org/caller \
  API_URL="http://127.0.0.1:$CLOSED_PORT"
check 'API unreachable: step succeeds' "$(outcome)" 'succeeded'
check 'API unreachable: mirror path kept' "$(output mirror)" 'present'

CALLER=org/missing probe org/missing "$GERRIT_URL" fail
check 'calling repository: mirror path kept' "$(output mirror)" 'present'
check 'calling repository: no API request' "$(cat "$WORK/requests.log")" ''

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

# gerrit-checkout, as the fallback runs it, with the given gerrit-url,
# project, refspec and on-unavailable (as probe-mirror normalised it),
# in a fresh workspace. REF, DEPTH, SUBMODULES, MIRROR and SERVER, when
# set, stand in for the ref, fetch-depth and submodules inputs, the
# probe's verdict and github.server_url.
checkout() {
  new_workspace
  : > "$WORK/requests.log"
  run_step gerrit-checkout "$WORK/ws" \
    INPUT_GERRIT_URL="$1" INPUT_GERRIT_PROJECT="$2" \
    INPUT_GERRIT_REFSPEC="$3" ON_UNAVAILABLE="$4" \
    INPUT_REF="${REF-refs/heads/main}" INPUT_FETCH_DEPTH="${DEPTH-2}" \
    INPUT_SUBMODULES="${SUBMODULES-false}" INPUT_TOKEN='test-token' \
    MIRROR="${MIRROR-absent}" SERVER_URL="${SERVER-https://github.com}"
}

# The refs a workspace holds, other than HEAD, one per line
refs() {
  git -C "$WORK/ws" for-each-ref --format='%(refname)' | LC_ALL=C sort
}

echo
echo '### gerrit-checkout, from Gerrit'

checkout "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
check 'readable project: step succeeds' "$(outcome)" 'succeeded'
check 'readable project: checked-out output set' \
  "$(output checked-out)" 'true'
check 'readable project: leftovers cleared' "$(workspace_entries)" './content.txt'
check 'readable project: origin is the Gerrit project' \
  "$(git -C "$WORK/ws" config --get remote.origin.url)" "$GERRIT_URL/$PROJECT"
check 'readable project: workspace marked as a safe directory' \
  "$(safe_directories)" "$(cd "$WORK/ws" && pwd -P)"
check 'readable project: ref fetched as origin/main' \
  "$(refs)" 'refs/remotes/origin/main'
check 'readable project: origin/main is the branch tip' \
  "$(git -C "$WORK/ws" rev-parse refs/remotes/origin/main)" "$BASE"
check 'readable project: HEAD is the change' \
  "$(git -C "$WORK/ws" rev-parse HEAD)" "$CHANGE"
check 'readable project: parent reachable for HEAD~1' \
  "$(git -C "$WORK/ws" rev-parse HEAD~1)" "$BASE"
check 'readable project: history limited to fetch-depth' \
  "$(git -C "$WORK/ws" rev-list --count HEAD)" 2

checkout "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
check 'second run: safe directory not added again' \
  "$(safe_directories)" "$(cd "$WORK/ws" && pwd -P)"

git config --global --unset-all safe.directory
git config --global --add safe.directory '*'
checkout "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
check "safe.directory '*' already set: nothing added" "$(safe_directories)" '*'
git config --global --unset-all safe.directory

DEPTH=0 checkout "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
check 'fetch-depth 0: every branch and tag fetched' "$(refs)" \
  "$(printf '%s\n' refs/remotes/origin/main refs/remotes/origin/other refs/tags/v9.9.9)"
check 'fetch-depth 0: full history' \
  "$(git -C "$WORK/ws" rev-list --count HEAD)" 4
check 'fetch-depth 0: not shallow' \
  "$(git -C "$WORK/ws" rev-parse --is-shallow-repository)" 'false'

REF="$BASE" checkout "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
check 'ref naming a commit: no base fetched' "$(refs)" ''
check 'ref naming a commit: HEAD is the change' \
  "$(git -C "$WORK/ws" rev-parse HEAD)" "$CHANGE"
check 'ref naming a commit: parent reachable for HEAD~1' \
  "$(git -C "$WORK/ws" rev-parse HEAD~1)" "$BASE"

REF=refs/heads/no-such-branch checkout "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
check 'ref naming a missing branch: step fails' "$(outcome)" 'failed'

checkout "$GERRIT_URL/" "/$PROJECT" "$REFSPEC" fail
check 'slashes around gerrit-url and project: step succeeds' "$(outcome)" 'succeeded'
check 'slashes around gerrit-url and project: no doubled slash' \
  "$(git -C "$WORK/ws" config --get remote.origin.url)" "$GERRIT_URL/$PROJECT"

checkout "$GERRIT_FILE" "$PROJECT" "$REFSPEC" fail
check 'non-HTTP gerrit-url: step succeeds' "$(outcome)" 'succeeded'
check 'non-HTTP gerrit-url: HEAD is the change' \
  "$(git -C "$WORK/ws" rev-parse HEAD)" "$CHANGE"

# Where Gerrit will not serve the change, the workspace must survive:
# earlier steps may have put the caller's own files there.
checkout "$GERRIT_URL" "$PROJECT" 'refs/changes/99/1099/1' skip
check 'missing change: fails even with skip' "$(outcome)" 'failed'
check 'missing change: step reports it' "$(errors)" \
  "::error::Gerrit project $PROJECT has no refs/changes/99/1099/1"
check_untouched 'missing change'

UNAVAILABLE="Gerrit project $PROJECT has no GitHub mirror and is closed to anonymous reads (HTTP 401), so $REFSPEC cannot be checked out"

checkout "$STUB/restricted" "$PROJECT" "$REFSPEC" fail
check 'restricted project, fail: step fails' "$(outcome)" 'failed'
check 'restricted project, fail: step reports it' "$(errors)" \
  "::error::$UNAVAILABLE"
check_untouched 'restricted project, fail'

git config --global --unset-all safe.directory || true
checkout "$STUB/restricted" "$PROJECT" "$REFSPEC" skip
check 'restricted project, skip: step succeeds' "$(outcome)" 'succeeded'
check 'restricted project, skip: checked-out is false' \
  "$(output checked-out)" 'false'
check_untouched 'restricted project, skip'
check 'restricted project, skip: no safe directory added' "$(safe_directories)" ''
check 'restricted project, skip: notice explains the skip' \
  "$(grep -c '^::notice title=Gerrit change not checked out::' "$WORK/log")" 1
check 'restricted project, skip: job summary explains the skip' \
  "$(grep -c '^### Gerrit change not checked out' "$WORK/summary")" 1

# A configured credential.username must not change that: the probe
# reads the HTTP status, not what git would then prompt for
git config --global credential.username someone
checkout "$STUB/restricted" "$PROJECT" "$REFSPEC" skip
git config --global --unset credential.username
check 'credential.username configured, skip: skipped' \
  "$(output checked-out)" 'false'

# Gerrit answers 403 or 404 for a hidden project and for a misspelt one
# alike, so neither may pass a check
for server in absent not-found; do
  case "$server" in
    absent) status=403 ;;
    *) status=404 ;;
  esac
  checkout "$STUB/$server" "$PROJECT" "$REFSPEC" skip
  check "$server project (HTTP $status): fails even with skip" "$(outcome)" 'failed'
  check "$server project (HTTP $status): step reports it" "$(errors)" \
    "::error::Gerrit project $PROJECT not found, or hidden from this runner (HTTP $status): check gerrit-project and gerrit-url"
  check_untouched "$server project (HTTP $status)"
done

checkout "$GERRIT_FILE" 'no/such/project' "$REFSPEC" skip
check 'non-HTTP gerrit-url, missing project: fails even with skip' \
  "$(outcome)" 'failed'
check_untouched 'non-HTTP gerrit-url, missing project'

checkout "http://127.0.0.1:$CLOSED_PORT" "$PROJECT" "$REFSPEC" skip
check 'Gerrit unreachable: fails even with skip' "$(outcome)" 'failed'
check 'Gerrit unreachable: step reports the network error' \
  "$(errors | grep -c "Unable to reach Gerrit")" 1
check_untouched 'Gerrit unreachable'

# A 401 whose transfer breaks is a network error, not a closed project
checkout "$STUB/truncated" "$PROJECT" "$REFSPEC" skip
check 'connection lost after a 401: fails even with skip' "$(outcome)" 'failed'
check 'connection lost after a 401: step reports the network error' \
  "$(errors | grep -c "Unable to reach Gerrit")" 1
check_untouched 'connection lost after a 401'

echo
echo '### Credentials in gerrit-url'

# Where the credentials arrived, and whether they show anywhere
sent_auth() {
  sed -n "s#^/auth/$PROJECT/info/refs ##p" "$WORK/requests.log" |
    grep -v '^-$' | sort -u
}
secrets_in() {
  grep -rl 's3cr3t-pass' "$@" 2> /dev/null | wc -l | tr -d ' '
}

checkout "$CRED_URL" "$PROJECT" "$REFSPEC" fail
check 'credentials: step succeeds' "$(outcome)" 'succeeded'
check 'credentials: sent to Gerrit' "$(sent_auth)" "$GERRIT_BASIC"
check 'credentials: HEAD is the change' \
  "$(git -C "$WORK/ws" rev-parse HEAD)" "$CHANGE"
check 'credentials: origin stored without them' \
  "$(git -C "$WORK/ws" config --get remote.origin.url)" "$STUB/auth/$PROJECT"
check 'credentials: none under .git' "$(secrets_in "$WORK/ws/.git")" 0
check 'credentials: none in the log' "$(secrets_in "$WORK/log")" 0

# A 401 to credentials means they are wrong, not that the project is
# closed: a configuration error, which must not pass a check
for creds in 'fallback-user:wrong' 'onlyuser'; do
  checkout "http://$creds@$STUB_HOST/auth" "$PROJECT" "$REFSPEC" skip
  check "credentials '$creds' rejected: fails even with skip" "$(outcome)" 'failed'
  check "credentials '$creds' rejected: step reports it" "$(errors)" \
    "::error::Gerrit rejected the credentials in gerrit-url for project $PROJECT (HTTP 401)"
  check_untouched "credentials '$creds' rejected"
done

checkout "http://fallback-user:s3cr3t-pass@127.0.0.1:$CLOSED_PORT" "$PROJECT" "$REFSPEC" fail
check 'credentials, Gerrit unreachable: step fails' "$(outcome)" 'failed'
check 'credentials, Gerrit unreachable: none in the log' "$(secrets_in "$WORK/log")" 0

# Git answers whatever scheme Gerrit asks for, so the status probe must
# too, or valid credentials on a Digest-only Gerrit read as rejected
checkout "http://fallback-user:s3cr3t-pass@$STUB_HOST/digest" "$PROJECT" "$REFSPEC" fail
check 'Digest-only Gerrit: step succeeds' "$(outcome)" 'succeeded'
check 'Digest-only Gerrit: probe answered with Digest' \
  "$(sed -n "s#^/digest/$PROJECT/info/refs Digest .*#Digest#p" "$WORK/requests.log" | sort -u)" \
  'Digest'
check 'Digest-only Gerrit: HEAD is the change' \
  "$(git -C "$WORK/ws" rev-parse HEAD)" "$CHANGE"

echo
echo '### Control characters'

# A CR or LF would end the line curl reads its URL from and start an
# option of the caller's choosing: here, one that writes a trace file
INJECTED="$WORK/injected.txt"
checkout "$GERRIT_URL"$'\n'"trace-ascii = $INJECTED"$'\n'"url = $GERRIT_URL" \
  "$PROJECT" "$REFSPEC" skip
check 'newline in gerrit-url: step fails' "$(outcome)" 'failed'
check 'newline in gerrit-url: step reports it' "$(errors)" \
  '::error::gerrit-url and gerrit-project must not contain control characters'
check 'newline in gerrit-url: no option injected' \
  "$(test -e "$INJECTED" && echo injected || echo none)" 'none'
check_untouched 'newline in gerrit-url'

checkout "$GERRIT_URL" "$PROJECT"$'\r'"trace-ascii = $INJECTED" "$REFSPEC" skip
check 'carriage return in gerrit-project: step fails' "$(outcome)" 'failed'
check 'carriage return in gerrit-project: no option injected' \
  "$(test -e "$INJECTED" && echo injected || echo none)" 'none'
check_untouched 'carriage return in gerrit-project'

echo
echo '### Submodules hosted on GitHub'

# Config the checkout must not leave behind, in the superproject or a
# submodule
persisted() {
  for dir in "$WORK/ws" "$WORK/ws/sub"; do
    if [ -e "$dir/.git" ]; then
      git -C "$dir" config --local --get-regexp 'extraheader|insteadof' || true
    fi
  done
}

# Requests for the GitHub-hosted submodule, by Authorization header
submodule_auth() {
  sed -n 's#^/github/org/private.git/info/refs ##p' "$WORK/requests.log" | sort -u
}

SUBMODULES=true SERVER="file://$GITHUB" checkout "$GERRIT_URL" "$PROJECT" "$SSH_REFSPEC" fail
check 'submodule by SSH URL: step succeeds' "$(outcome)" 'succeeded'
check 'submodule by SSH URL: populated over the HTTPS rewrite' \
  "$(git -C "$WORK/ws/sub" rev-parse HEAD 2> /dev/null)" "$SUB"
check 'submodule by SSH URL: no config left behind' "$(persisted)" ''

SUBMODULES=true SERVER="$STUB/github" checkout "$GERRIT_URL" "$PROJECT" "$PRIVATE_REFSPEC" fail
check 'submodule on GitHub: token sent with the request' \
  "$(submodule_auth)" "basic $TOKEN_BASIC"
check 'submodule on GitHub: no config left behind' "$(persisted)" ''
check 'submodule on GitHub: token masked in the log' \
  "$(grep -c "^::add-mask::$TOKEN_BASIC\$" "$WORK/log")" 1
check 'submodule on GitHub: token nowhere else in the log' \
  "$(grep -v '^::add-mask::' "$WORK/log" | grep -c -e 'test-token' -e "$TOKEN_BASIC" || true)" 0

# On the mirror path actions/checkout supplies the token; this step must
# not add a second header. Reuse the workspace a fallback prepared, with
# Gerrit as origin, so the change and its submodule are reachable.
checkout "$GERRIT_URL" "$PROJECT" "$REFSPEC" fail
: > "$WORK/requests.log"
run_step gerrit-checkout "$WORK/ws" \
  INPUT_GERRIT_URL="$GERRIT_URL" INPUT_GERRIT_PROJECT="$PROJECT" \
  INPUT_GERRIT_REFSPEC="$PRIVATE_REFSPEC" INPUT_FETCH_DEPTH=2 \
  INPUT_SUBMODULES=true INPUT_TOKEN='test-token' MIRROR=present \
  SERVER_URL="$STUB/github"
check 'mirror path: token not added by this step' "$(submodule_auth)" '-'

echo
echo "Passed: $passed, failed: $failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
