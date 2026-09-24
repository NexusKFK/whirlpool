#!/bin/bash
# Drives a built macOS binary through its real per-user control socket: launch,
# CLI commands, duplicate launch, quit, an older instance still listening on the
# pre-2.0.5 /tmp path, and (with passwordless sudo) a socket another user planted
# on that path. Uses a throwaway configuration with demo quotes. Refuses to run
# while another Whirlpool instance is reachable.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=${1:-.build/debug/whirlpool}
bin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")"
unset WHIRLPOOL_SOCKET
state=$(mktemp -d "${TMPDIR:-/tmp}/whirlpool-cli.XXXXXX")
export WHIRLPOOL_CONFIG="$state/config.json"
socket="$(getconf DARWIN_USER_TEMP_DIR)whirlpool.sock"
legacy="/tmp/whirlpool-$(id -u).sock"
python=$(command -v python3)
app_pid=""
cleanup() {
    if [ -n "$app_pid" ]; then kill "$app_pid" 2>/dev/null || true; fi
    rm -rf "$state"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [ -f "$state/app.log" ] && cat "$state/app.log" >&2; exit 1; }
pass() { echo "PASS: $*"; }
limited() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # macOS has no timeout(1)

# A stand-in for an older Whirlpool: answers every request with its pid, exits after 60 idle seconds.
fake_instance='
import json, os, socket, sys
path = sys.argv[1]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path); os.chmod(path, 0o666); server.listen(4); server.settimeout(60)
try:
    while True:
        client, _ = server.accept()
        client.recv(65536)
        client.sendall(json.dumps({"pid": os.getpid(), "legacy": True}).encode())
        client.close()
except socket.timeout:
    pass
finally:
    os.unlink(path)
'
wait_for_socket() { for _ in $(seq 50); do [ -S "$1" ] && return 0; sleep 0.1; done; fail "no socket at $1"; }

launch() {
    "$bin" >"$state/app.log" 2>&1 &
    app_pid=$!
    local status=""
    for _ in $(seq 75); do
        status=$("$bin" --status 2>/dev/null || true)
        [[ "$status" == *"\"pid\":$app_pid"* ]] && return 0
        kill -0 "$app_pid" 2>/dev/null || fail "app exited during launch"
        sleep 0.2
    done
    fail "app did not answer --status: $status"
}

quit() {
    [ "$(limited 10 "$bin" --quit)" = ok ] || fail "--quit was not acknowledged"
    for _ in $(seq 50); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.2; done
    kill -0 "$app_pid" 2>/dev/null && fail "app still running after --quit"
    app_pid=""
}

if limited 10 "$bin" --status >/dev/null 2>&1; then fail "another Whirlpool instance is running; quit it first"; fi
[ -e "$legacy" ] && fail "$legacy exists; remove it first"
printf '{"provider":"demo","checkUpdates":false,"smartRefresh":false}' > "$WHIRLPOOL_CONFIG"

launch
[ -S "$socket" ] || fail "socket is not in the per-user temporary directory: $socket"
[ "$(stat -f %Lp "$socket")" = 600 ] || fail "socket permissions are $(stat -f %Lp "$socket")"
[ -e "$legacy" ] && fail "the app still created $legacy"
pass "the app listens on $socket with owner-only permissions"

[ "$(limited 10 "$bin" --send HELLO)" = ok ] && [ "$(limited 10 "$bin" --list next)" = ok ] || fail "CLI commands"
second=$(limited 10 "$bin" 2>&1) || fail "second launch did not exit: $second"
[[ "$second" == *"already running"* ]] || fail "second launch: $second"
pass "CLI commands reach the app; a second launch exits"

quit
[ -e "$socket" ] && fail "socket left behind after quitting"
limited 10 "$bin" --status >/dev/null 2>&1 && fail "--status succeeded with no instance"
pass "--quit stops the app and removes its socket"

"$python" -c "$fake_instance" "$legacy" &
fake_pid=$!
wait_for_socket "$legacy"
[[ "$(limited 10 "$bin" --status)" == *'"legacy": true'* ]] || fail "CLI did not fall back to $legacy"
second=$(limited 10 "$bin" 2>&1) || fail "launch next to an older instance did not exit: $second"
[[ "$second" == *"already running"* ]] || fail "older instance not recognized: $second"
kill "$fake_pid" 2>/dev/null || true; wait "$fake_pid" 2>/dev/null || true; rm -f "$legacy"
pass "an older instance on $legacy is still found by the CLI and blocks a second launch"

if sudo -n true 2>/dev/null; then
    sudo -n -u nobody "$python" -c "$fake_instance" "$legacy" &
    squatter_pid=$!
    wait_for_socket "$legacy"
    limited 10 "$bin" --status >/dev/null 2>&1 && fail "CLI trusted a socket owned by another user"
    launch
    quit
    sudo -n pkill -u nobody -f "socket.AF_UNIX" 2>/dev/null || true
    wait "$squatter_pid" 2>/dev/null || true
    sudo -n rm -f "$legacy"
    pass "a socket planted by another user is ignored"
else
    echo "SKIP: planted-socket check needs passwordless sudo"
fi
echo "All CLI checks passed."
