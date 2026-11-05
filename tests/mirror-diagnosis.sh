#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Checks the diagnosis the action prints once it has failed on the
# mirror path: whether the GitHub mirror is missing, archived, empty,
# without the branch or without the change, and who can fix it. It
# must say nothing about a healthy mirror, never claim a cause it has
# no evidence for, never change the outcome, never echo what the server
# sends, and keep the token off the command line and out of the log.
#
# The step runs as the runner runs it, read out of action.yaml with its
# 'shell:', as in gerrit-fallback.sh. It needs git and python3, for a
# server on the loopback interface standing in for the GitHub API and
# for github.com, serving local repositories through 'git http-backend'.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
SERVER_PID=''
STALL_PID=''
STALL_ADDRESS=''
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2> /dev/null || true
  fi
  if [ -n "$STALL_PID" ]; then
    kill "$STALL_PID" 2> /dev/null || true
  fi
  # A failing run must not leave a stalled git transport behind
  if [ -n "$STALL_ADDRESS" ]; then
    stalled_helpers | xargs -r kill -KILL 2> /dev/null || true
  fi
  # Nor a command that ignored the time limit
  survivors | xargs -r kill -KILL 2> /dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# The PIDs of the commands the time-limit checks start, which carry
# $MARK in their command line
MARK="bounded-$$-$RANDOM"
survivors() {
  ps -eo pid=,args= | awk -v mark="$MARK" \
    '$2 !~ /awk$/ && index($0, mark) { print $1 }'
}

# Keep the caller's git configuration (signing, hooks, URL rewrites,
# credentials) out of the fixtures.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_COUNT GIT_ASKPASS SSH_ASKPASS
export HOME="$WORK/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
git config --global user.name 'Diagnosis Test'
git config --global user.email 'test@example.invalid'
git config --global init.defaultBranch main
git config --global commit.gpgSign false

### The step under test ###

# The hook checks the changed files alone, so it may not be handed
# the helper to follow
# shellcheck source=tests/steps.sh disable=SC1091
source "$REPO_ROOT/tests/steps.sh"
stage_scripts
step_command diagnose-mirror
DIAGNOSE_CMD=("${STEP_CMD[@]}")

### Fixtures ###

# The server records each request's path and Authorization header. It
# routes:
#   /api/repos/org/<name>  the GitHub API, answering as API below says:
#                          a status, a JSON body, and a delay
#   /github/org/<name>     github.com, serving $GIT_ROOT/org/<name>;
#                          'slowgit' stalls past the step's limit
#   anything else          404
cat > "$WORK/server.py" << 'EOF'
import http.server
import json
import os
import subprocess
import sys
import time

LOG, PORT_FILE, GIT_ROOT = sys.argv[1:4]
HOSTILE = "::error::pwned%0A\r::warning::pwned\n##[error]pwned"
NOT_ARCHIVED = {"full_name": "org/x", "archived": False}
API = {
    "healthy": (200, NOT_ARCHIVED, 0),
    "empty": (200, NOT_ARCHIVED, 0),
    "lagging": (200, NOT_ARCHIVED, 0),
    "slowgit": (200, NOT_ARCHIVED, 0),
    "stalled": (200, NOT_ARCHIVED, 0),
    "oddnames": (200, NOT_ARCHIVED, 0),
    "archived": (200, {"archived": True}, 0),
    # A fork carries its parent's state too; only the top level counts
    "fork": (200, {"archived": False, "parent": {"archived": True}}, 0),
    "hostile": (200, {"archived": False, "description": HOSTILE, "name": HOSTILE}, 0),
    "hostile-archived": (200, {"archived": True, "description": HOSTILE}, 0),
    "garbage": (200, HOSTILE, 0),
    # Answers in which the archive state cannot be read
    "nobody": (200, "", 0),
    "html": (200, "<html><body>" + HOSTILE + "</body></html>", 0),
    "stringly": (200, {"archived": "false"}, 0),
    "nofield": (200, {"full_name": "org/nofield"}, 0),
    # Numbers are not booleans, though Python compares 1 equal to True
    "one": (200, {"archived": 1}, 0),
    "zero": (200, {"archived": 0}, 0),
    "onefloat": (200, {"archived": 1.0}, 0),
    "zerofloat": (200, {"archived": 0.0}, 0),
    # A valid value followed by bytes that are not JSON
    "trailfalse": (200, '{"archived":false} invalid', 0),
    "trailtrue": (200, '{"archived":true} invalid', 0),
    "broken": (500, {"message": HOSTILE}, 0),
    "limited": (403, {"message": HOSTILE}, 0),
    "slow": (200, NOT_ARCHIVED, 15),
}


class Handler(http.server.BaseHTTPRequestHandler):
    def route(self):
        path, _, query = self.path.partition("?")
        with open(LOG, "a") as log:
            log.write(f"{path} {self.headers.get('Authorization', '-')}\n")
        if path.startswith("/api/repos/org/"):
            name = path[len("/api/repos/org/") :]
            if name not in API:
                return self.reply(404, b'{"message": "Not Found"}')
            status, body, delay = API[name]
            time.sleep(delay)
            if not isinstance(body, str):
                body = json.dumps(body)
            return self.reply(status, body.encode())
        if path.startswith("/github/"):
            if path.startswith("/github/org/slowgit/"):
                time.sleep(15)
            return self.backend(path[len("/github") :], query)
        return self.reply(404)

    do_GET = route
    do_POST = route

    def reply(self, status, body=b"", headers=None):
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
        self.reply(status, body, headers)

    def log_message(self, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    # A client that gave up on a slow answer is the point of the test
    def handle_error(self, request, client_address):
        pass


server = Server(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
EOF
GIT_ROOT="$WORK/github"
mkdir -p "$GIT_ROOT/org"
python3 "$WORK/server.py" "$WORK/requests.log" "$WORK/port" "$GIT_ROOT" &
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

# A listener that accepts every connection and never answers, so a
# git transport talking to it blocks on the network
cat > "$WORK/stall.py" << 'EOF'
import socket
import sys

listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(16)
with open(sys.argv[1], "w") as f:
    f.write(str(listener.getsockname()[1]))
held = []
while True:
    connection, _ = listener.accept()
    held.append(connection)
EOF
python3 "$WORK/stall.py" "$WORK/stall-port" &
STALL_PID=$!
for _ in $(seq 50); do
  [ -s "$WORK/stall-port" ] && break
  sleep 0.1
done
if [ ! -s "$WORK/stall-port" ]; then
  echo 'The stalled listener did not start' >&2
  exit 1
fi
STALL_ADDRESS="127.0.0.1:$(cat "$WORK/stall-port")"

# The PIDs of git HTTP transports talking to the stalled listener
stalled_helpers() {
  ps -eo pid=,args= | awk -v address="$STALL_ADDRESS" \
    '$2 ~ /git-remote-http/ && index($0, address) { print $1 }'
}

# A port nothing listens on: bind one, then let it go
CLOSED_PORT="$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
')"

# Mirrors in each state: populated with the change, populated without
# it (replication lagging, or a private change), and empty
REFSPEC='refs/changes/21/46421/1'
git init -q "$WORK/src"
git -C "$WORK/src" commit -q --allow-empty -m base
git -C "$WORK/src" commit -q --allow-empty -m 'the change'
# Branch names git accepts but a message cannot show safely
ODD_BRANCHES=('feature/c++' 'user@host-fix' 'wip#12' 'feature/ünï')
UNREADABLE=(garbage nobody html stringly nofield one zero onefloat zerofloat
  trailfalse trailtrue)
for name in healthy lagging empty slowgit archived fork hostile \
  hostile-archived broken limited slow oddnames "${UNREADABLE[@]}"; do
  git init -q --bare "$GIT_ROOT/org/$name"
done
for name in healthy lagging slowgit archived fork hostile \
  hostile-archived broken limited slow oddnames "${UNREADABLE[@]}"; do
  git -C "$WORK/src" push -q "$GIT_ROOT/org/$name" HEAD~1:refs/heads/main
done
for name in healthy slowgit archived fork broken limited slow \
  oddnames "${UNREADABLE[@]}"; do
  git -C "$WORK/src" push -q "$GIT_ROOT/org/$name" "HEAD:$REFSPEC"
done
for branch in "${ODD_BRANCHES[@]}"; do
  git -C "$WORK/src" push -q "$GIT_ROOT/org/oddnames" \
    "HEAD~1:refs/heads/$branch"
done
git -C "$WORK/src" push -q "$GIT_ROOT/org/healthy" HEAD~1:refs/tags/v1.0

# Wrappers that record the command line of every git and curl the step
# runs, so a check can see what reached argv. They are made here, at
# run time: the repository holds no executable files.
mkdir -p "$WORK/bin"
for tool in git curl; do
  # $* and $@ belong to the wrapper, so they stay in single quotes
  # shellcheck disable=SC2016
  printf '#!%s\nprintf "%%s\\n" "%s $*" >> %q\nexec %q "$@"\n' \
    "$(command -v bash)" "$tool" "$WORK/argv.log" "$(command -v "$tool")" \
    > "$WORK/bin/$tool"
  chmod +x "$WORK/bin/$tool"
done

# A PATH holding only the tools the step needs, without the commands
# named in the arguments, to exercise the fallbacks for a runner
# lacking them
#
# python3 is linked to the interpreter itself, as sys.executable names
# it, not to whatever 'command -v' finds: a shim such as pyenv's is a
# script that needs tools this directory may not hold.
restricted_path() {
  local dir tool
  dir="$(mktemp -d "$WORK/path.XXXXXX")"
  for tool in bash env sed grep tr mktemp rm cat sleep base64 cut kill \
    git curl jq python3; do
    case " $* " in *" $tool "*) continue ;; esac
    if [ -x "$WORK/bin/$tool" ]; then
      ln -s "$WORK/bin/$tool" "$dir/$tool"
    elif [ "$tool" = python3 ]; then
      ln -s "$PYTHON3_EXE" "$dir/$tool"
    elif command -v "$tool" > /dev/null; then
      ln -s "$(command -v "$tool")" "$dir/$tool"
    fi
  done
  printf '%s' "$dir"
}

PYTHON3_EXE="$(python3 -c 'import sys; print(sys.executable)')"

TOKEN='test-token-7f3a'
TOKEN_BASIC="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"

# Run the diagnosis for mirror org/$1, as the step runs after a failed
# checkout, with xtrace forced on to show what a trace would reveal.
# REF, GERRIT, DELAY, REFSPEC_IN, API, GIT_SERVER and SEARCH_PATH, when
# set, stand in for the ref, gerrit-url, delay and gerrit-refspec
# inputs, github.api_url, github.server_url and PATH. Whatever the
# fixture, no annotation may name an empty branch.
diagnose() {
  : > "$WORK/requests.log"
  : > "$WORK/argv.log"
  : > "$WORK/summary"
  rc=0
  local start=$SECONDS
  (
    cd "$WORK"
    env PATH="${SEARCH_PATH-$WORK/bin:$PATH}" SHELLOPTS=xtrace \
      GITHUB_STEP_SUMMARY="$WORK/summary" RUNNER_TEMP="$WORK/runner-temp" \
      INPUT_REPOSITORY="org/$1" INPUT_REF="${REF-refs/heads/main}" \
      INPUT_GERRIT_REFSPEC="${REFSPEC_IN-$REFSPEC}" \
      INPUT_GERRIT_URL="${GERRIT-}" INPUT_DELAY="${DELAY-10s}" \
      INPUT_TOKEN="$TOKEN" API_URL="${API-$STUB/api}" \
      SERVER_URL="${GIT_SERVER-$STUB/github}" "${DIAGNOSE_CMD[@]}"
  ) > "$WORK/log" 2>&1 || rc=$?
  elapsed=$((SECONDS - start))
  if annotations | grep -qE 'branch( or tag)? [.,]'; then
    failed=$((failed + 1))
    echo "❌ org/$1, ref '${REF-refs/heads/main}': an annotation names an empty branch"
    annotations
  fi
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

# The annotations the step printed, one per line
annotations() {
  grep -E '^::(error|warning|notice)( |::)' "$WORK/log" || true
}

# Whether the annotations contain the fixed text $1
says() {
  if annotations | grep -qF -- "$1"; then echo yes; else echo no; fi
}

# The step ended well and printed exactly one annotation of kind $2 and
# one summary line, naming the mirror org/$1
reported() {
  local desc="$1" mirror="$2" kind="$3"
  check "$desc: step exits 0" "$rc" 0
  check "$desc: one annotation" "$(annotations | wc -l | tr -d ' ')" 1
  check "$desc: an annotation of kind $kind" \
    "$(annotations | sed -E 's/^::([a-z]+) .*/\1/')" "$kind"
  check "$desc: names the mirror" "$(says "org/$mirror")" yes
  check "$desc: one line of job summary" \
    "$(grep -c "org/$mirror" "$WORK/summary")" 1
}

# The step ended well and said nothing
silent() {
  check "$1: step exits 0" "$rc" 0
  check "$1: no annotation" "$(annotations)" ''
  check "$1: no job summary" "$(cat "$WORK/summary")" ''
}

# Requests matching $1 in the server's log
requests() {
  grep -c -- "$1" "$WORK/requests.log" || true
}

echo '### The step in action.yaml'

check 'runs only after a failure in Gerrit mode, and not on the Gerrit fallback' \
  "$(step_field diagnose-mirror if)" \
  "failure() && steps.select-mode.outputs.mode == 'gerrit' && steps.probe-mirror.outputs.mirror != 'absent'"
check 'is the last step, so it follows every failure' \
  "$(grep -E '^    - ' "$REPO_ROOT/action.yaml" | tail -n 1)" \
  '    - id: diagnose-mirror'

echo
echo '### Mirror states'

GERRIT='' diagnose missing
reported 'not found, no gerrit-url' missing error
check 'not found, no gerrit-url: says not found or not visible' \
  "$(says 'was not found, or is private and not visible to this token')" yes
check 'not found, no gerrit-url: says no gerrit-url was given' \
  "$(says 'no gerrit-url was given')" yes
check 'not found, no gerrit-url: the caller acts' \
  "$(says 'For the caller to fix: set gerrit-url')" yes

GERRIT="$STUB/gerrit" diagnose missing
reported 'not found, with gerrit-url' missing error
check 'not found, with gerrit-url: says not found or not visible' \
  "$(says 'was not found, or is private and not visible to this token')" yes
check 'not found, with gerrit-url: does not ask for gerrit-url' \
  "$(says 'gerrit-url')" no
check 'not found, with gerrit-url: the caller acts' \
  "$(says 'For the caller to fix: check the repository input')" yes

diagnose archived
reported 'archived' archived error
check 'archived: says the change will never arrive' \
  "$(says 'is archived, so Gerrit replication cannot update it')" yes
check 'archived: LF Releng or the administrators act' \
  "$(says 'LF Releng or the project')" yes
check 'archived: not the caller' "$(says 'For the caller')" no
check 'archived: no git request' "$(requests '^/github/')" 0

diagnose fork
silent 'fork of an archived repository, healthy itself'

REF=refs/heads/main diagnose empty
reported 'empty, branch failure' empty error
check 'empty, branch failure: says it has no branches' \
  "$(says 'org/empty has no branches')" yes
check 'empty, branch failure: LF Releng acts' \
  "$(says 'LF Releng must repair replication')" yes
check 'empty, branch failure: not the caller' "$(says 'For the caller')" no

REF="$(git -C "$WORK/src" rev-parse HEAD~1)" diagnose empty
reported 'empty, change-ref failure' empty error
check 'empty, change-ref failure: says it has no branches' \
  "$(says 'org/empty has no branches')" yes

REF=refs/heads/release/9 diagnose healthy
reported 'branch missing' healthy error
check 'branch missing: names the branch' \
  "$(says 'org/healthy has no branch release/9.')" yes
check 'branch missing: the caller acts' \
  "$(says 'For the caller to fix: check the ref input')" yes

REF=release/9 diagnose healthy
reported 'bare name, neither branch nor tag' healthy error
check 'bare name, neither branch nor tag: names it' \
  "$(says 'org/healthy has no branch or tag release/9.')" yes

DELAY=30s diagnose lagging
reported 'change ref missing' lagging error
check 'change ref missing: names the ref' \
  "$(says "has branches but not $REFSPEC")" yes
check 'change ref missing: gives the delay' "$(says '(delay is 30s)')" yes
check 'change ref missing: says private changes do not replicate' \
  "$(says 'private change refs are not replicated')" yes
check 'change ref missing: retry, then LF Releng' \
  "$(says 'Retry; if it persists, ask LF Releng')" yes

DELAY=$'1s\n::error::pwned' diagnose lagging
check 'malformed delay: left out' "$(says 'delay is')" no
check 'malformed delay: not echoed' "$(grep -c pwned "$WORK/log" || true)" 0

echo
echo '### Saying nothing without cause'

diagnose healthy
silent 'healthy mirror, unrelated failure'

REF="$(git -C "$WORK/src" rev-parse HEAD~1)" diagnose healthy
silent 'healthy mirror, ref naming a commit'

for ref in main v1.0; do
  REF="$ref" diagnose healthy
  silent "healthy mirror, bare name '$ref' it holds"
done

REF=$'refs/heads/x\n::error::pwned' diagnose healthy
silent 'malformed branch'

# A name git accepts but a message cannot show is not checked at all:
# with no name to give, there is no claim to make
for branch in "${ODD_BRANCHES[@]}"; do
  for ref in "$branch" "refs/heads/$branch"; do
    REF="$ref" diagnose oddnames
    silent "unshowable branch '$ref' the mirror holds"
  done
done

REFSPEC_IN=$'refs/changes/21/46421/1\n::error::pwned' diagnose lagging
silent 'malformed refspec'

for bad in '../x' 'org/..' 'org/x/y'; do
  : > "$WORK/requests.log"
  rc=0
  (
    cd "$WORK"
    env INPUT_REPOSITORY="$bad" INPUT_REF=refs/heads/main \
      INPUT_GERRIT_REFSPEC="$REFSPEC" INPUT_GERRIT_URL='' INPUT_DELAY=10s \
      INPUT_TOKEN="$TOKEN" API_URL="$STUB/api" SERVER_URL="$STUB/github" \
      GITHUB_STEP_SUMMARY="$WORK/summary" "${DIAGNOSE_CMD[@]}"
  ) > "$WORK/log" 2>&1 || rc=$?
  silent "malformed repository '$bad'"
  check "malformed repository '$bad': no request" "$(cat "$WORK/requests.log")" ''
done

echo
echo '### Cannot tell'

diagnose broken
reported 'API answers 500' broken notice
check 'API answers 500: gives the status' "$(says 'answered HTTP 500')" yes
check 'API answers 500: claims no cause' "$(says 'No cause is identified')" yes
check 'API answers 500: one attempt' "$(requests '^/api/')" 1

diagnose limited
reported 'API answers 403 (rate limit)' limited notice
check 'API answers 403: gives the status' "$(says 'answered HTTP 403')" yes

API="http://127.0.0.1:$CLOSED_PORT" diagnose healthy
reported 'API unreachable' healthy notice
check 'API unreachable: says the API did not answer' \
  "$(says 'the GitHub API did not answer')" yes

diagnose slow
reported 'API times out' slow notice
check 'API times out: says the API did not answer' \
  "$(says 'the GitHub API did not answer')" yes
check 'API times out: bounded' "$([ "$elapsed" -lt 15 ] && echo yes || echo no)" yes

diagnose slowgit
reported 'git times out' slowgit notice
check 'git times out: says git ls-remote failed' \
  "$(says 'git ls-remote failed')" yes
check 'git times out: bounded' "$([ "$elapsed" -lt 15 ] && echo yes || echo no)" yes

GIT_SERVER="http://$STALL_ADDRESS/github" diagnose stalled
reported 'git transport stalls' stalled notice
check 'git transport stalls: says git ls-remote failed' \
  "$(says 'git ls-remote failed')" yes
check 'git transport stalls: bounded' \
  "$([ "$elapsed" -lt 15 ] && echo yes || echo no)" yes
# The step has returned; give a survivor a moment to show itself
for _ in $(seq 20); do
  [ -z "$(stalled_helpers)" ] && break
  sleep 0.1
done
check 'git transport stalls: no transport survives the step' \
  "$(stalled_helpers | wc -l | tr -d ' ')" 0

echo
echo '### The time limit'

# diagnosis_bounded itself, with a one-second limit, on commands that
# ignore TERM. The file's helpers are read without the diagnosis that
# runs when it is sourced; the commands carry $MARK in their command
# line, which the runner script below does not.
sed '/^diagnose_mirror()$/,$d' "$REPO_ROOT/scripts/diagnose-mirror.sh" \
  > "$WORK/helpers.sh"
cat > "$WORK/bounded.sh" << 'EOF'
# Run case $1 under diagnosis_bounded with a one-second limit, and
# write its status to file $2
# shellcheck source=/dev/null
source "$HELPERS"
status_file=$2
case $1 in
  resistant)
    set -- bash -c 'trap "" TERM; while :; do sleep 1; done' "$BOUNDED_MARK" ;;
  grandchild)
    set -- bash -c 'bash -c "trap \"\" TERM; while :; do sleep 1; done" "$0-grandchild" & wait' "$BOUNDED_MARK" ;;
  obedient)
    set -- bash -c 'sleep 30; :' "$BOUNDED_MARK" ;;
  quick)
    set -- bash -c 'exit 3' "$BOUNDED_MARK" ;;
esac
diagnosis_bounded 1 "$@"
echo "$?" > "$status_file"
EOF

# Run case $1, under a guard of its own that gives up after eight
# seconds, and set hung, elapsed and status
bounded() {
  local runner start=$SECONDS
  : > "$WORK/bounded.status"
  HELPERS="$WORK/helpers.sh" BOUNDED_MARK="$MARK" \
    bash "$WORK/bounded.sh" "$1" "$WORK/bounded.status" > /dev/null 2>&1 &
  runner=$!
  for _ in $(seq 80); do
    kill -0 "$runner" 2> /dev/null || break
    sleep 0.1
  done
  hung=no
  if kill -0 "$runner" 2> /dev/null; then
    hung=yes
    kill -KILL "$runner" 2> /dev/null || true
  fi
  wait "$runner" 2> /dev/null || true
  elapsed=$((SECONDS - start))
  status="$(cat "$WORK/bounded.status")"
  # A killed process may take a moment to go
  for _ in $(seq 10); do
    [ -z "$(survivors)" ] && break
    sleep 0.1
  done
}

# As timeout(1) reports it: 124 for a command stopped by TERM, 128+9
# for one that needed KILL
for spec in 'resistant 137' 'grandchild 124' 'obedient 124' 'quick 3'; do
  read -r name want <<< "$spec"
  bounded "$name"
  check "$name: returns" "$hung" no
  check "$name: within five seconds" \
    "$([ "$elapsed" -lt 5 ] && echo yes || echo no)" yes
  check "$name: exit status" "$status" "$want"
  check "$name: nothing left running" "$(survivors | wc -l | tr -d ' ')" 0
  survivors | xargs -r kill -KILL 2> /dev/null || true
done

echo
echo '### Hostile server answers'

for name in hostile hostile-archived broken limited garbage html; do
  diagnose "$name"
  check "$name: step exits 0" "$rc" 0
  check "$name: nothing from the body in the log" \
    "$(grep -c -e pwned -e '##\[' "$WORK/log" || true)" 0
  check "$name: nothing from the body in the summary" \
    "$(grep -c -e pwned -e '##\[' "$WORK/summary" || true)" 0
done
diagnose hostile
check 'hostile, not archived: diagnosed from git' \
  "$(says "has branches but not $REFSPEC")" yes
diagnose hostile-archived
check 'hostile, archived: diagnosed as archived' "$(says 'is archived')" yes

echo
echo '### An archive state that cannot be read'

# Each mirror holds the branch and the change, so only the archive state
# is in doubt, and the step must say so rather than fall silent. Neither
# parser may read anything but a JSON true or false as an answer.
for parser in jq python3; do
  if [ "$parser" = jq ]; then
    search="$WORK/bin:$PATH"
  else
    search="$(restricted_path jq)"
  fi
  for name in "${UNREADABLE[@]}"; do
    SEARCH_PATH="$search" diagnose "$name"
    reported "$parser, $name" "$name" notice
    check "$parser, $name: says the archive state is unknown" \
      "$(says "Cannot tell whether GitHub mirror org/$name is archived")" yes
    check "$parser, $name: claims no cause" "$(says 'No cause is identified')" yes
  done
done

# jq prints a value it has parsed before failing on the bytes after
# it, which must not pass for an answer
check 'jq is on PATH for the trailing-garbage fixtures' \
  "$(command -v jq > /dev/null && echo yes || echo no)" yes
SEARCH_PATH="$WORK/bin:$PATH" diagnose trailfalse
reported 'jq, false then garbage' trailfalse notice
check 'jq, false then garbage: says the archive state is unknown' \
  "$(says 'Cannot tell whether GitHub mirror org/trailfalse is archived')" yes
SEARCH_PATH="$WORK/bin:$PATH" diagnose trailtrue
check 'jq, true then garbage: not called archived' \
  "$(says 'org/trailtrue is archived, so')" no
check 'jq, true then garbage: says the archive state is unknown' \
  "$(says 'Cannot tell whether GitHub mirror org/trailtrue is archived')" yes

echo
echo '### Both parsers read the archive state alike'

# One table of bodies, read by each parser with the other hidden from
# PATH. Only a JSON true or false in a body holding a single JSON value
# is an answer, and both parsers must give the same one, so neither can
# drift alone. Each row is the expected answer, a space, and the body,
# which may hold newlines. The parsers are hidden through
# restricted_path, which links python3 to sys.executable.
sed -n '/^diagnosis_archived()$/,/^}$/p' \
  "$REPO_ROOT/scripts/diagnose-mirror.sh" > "$WORK/archived.sh"
check 'the parser under test was found' \
  "$(grep -c 'python3 -c' "$WORK/archived.sh")" 1
PARITY=(
  'true {"archived": true}'
  'false {"archived": false}'
  'unknown {"archived": 1}'
  'unknown {"archived": 0}'
  'unknown {"archived": 1.0}'
  'unknown {"archived": 0.0}'
  'unknown {"archived": "true"}'
  'unknown {"archived": null}'
  'unknown {"archived": [true]}'
  'unknown {"archived": {"x": 1}}'
  'unknown {"x": 1}'
  'unknown "true"'
  'unknown null'
  'unknown [true]'
  'unknown {"full_name": "org/x"}'
  'unknown {"archived": tru'
  'unknown '
  'unknown {"archived":false} invalid'
  'unknown {"archived":true} invalid'
  'unknown {"archived":false}{"archived":true}'
  'unknown {"archived":true}{"archived":false}'
  $'unknown {"archived":false}\n{"archived":true}'
  $'unknown {"archived":true}\n{"archived":false}'
  'unknown {"archived":false}}'
)
JQ_PATH="$(restricted_path python3)"
PYTHON_PATH="$(restricted_path jq)"
NO_PARSER_PATH="$(restricted_path jq python3)"
read_archived() {
  # $1 and $2 belong to the inner shell, so they stay in single quotes
  # shellcheck disable=SC2016
  env PATH="$1" bash -c 'source "$1"; diagnosis_archived "$2"' _ \
    "$WORK/archived.sh" "$WORK/parity.json"
}
for spec in "${PARITY[@]}"; do
  want="${spec%% *}"
  body="${spec#* }"
  printf '%s' "$body" > "$WORK/parity.json"
  by_jq="$(read_archived "$JQ_PATH")"
  by_python="$(read_archived "$PYTHON_PATH")"
  check "jq reads '$body' as $want" "$by_jq" "$want"
  check "python3 reads '$body' as $want" "$by_python" "$want"
  check "jq and python3 agree on '$body'" "$by_jq" "$by_python"
  check "with neither, '$body' is unknown" \
    "$(read_archived "$NO_PARSER_PATH")" unknown
done

echo
echo '### Without jq, or without jq and python3'

SEARCH_PATH="$(restricted_path jq)" diagnose archived
check 'python3 alone: archived read' "$(says 'org/archived is archived')" yes
SEARCH_PATH="$(restricted_path jq)" diagnose fork
silent 'python3 alone: fork of an archived repository'
SEARCH_PATH="$(restricted_path jq python3)" diagnose archived
reported 'neither: archived state unknown' archived notice
check 'neither: says the archive state is unknown' \
  "$(says 'Cannot tell whether GitHub mirror org/archived is archived')" yes
SEARCH_PATH="$(restricted_path jq python3)" diagnose lagging
reported 'neither: a git diagnosis wins' lagging error
check 'neither: git checks still run' \
  "$(says "has branches but not $REFSPEC")" yes

echo
echo '### The token'

diagnose lagging
check 'sent to the API as a bearer token' \
  "$(sed -n 's#^/api/repos/org/lagging ##p' "$WORK/requests.log")" \
  "Bearer $TOKEN"
check 'sent to git as a basic credential' \
  "$(sed -n 's#^/github/org/lagging/info/refs ##p' "$WORK/requests.log" | sort -u)" \
  "basic $TOKEN_BASIC"
check 'git and curl ran' \
  "$(cut -d' ' -f1 "$WORK/argv.log" | sort -u | tr '\n' ' ')" 'curl git '
check 'not in any command line' \
  "$(grep -c -e "$TOKEN" -e "$TOKEN_BASIC" "$WORK/argv.log" || true)" 0
check 'not in the log, xtrace forced on' \
  "$(grep -c -e "$TOKEN" -e "$TOKEN_BASIC" "$WORK/log" || true)" 0
check 'xtrace really was on' \
  "$(grep -q '^+' "$WORK/log" && echo yes || echo no)" yes

echo
echo "Passed: $passed, failed: $failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
