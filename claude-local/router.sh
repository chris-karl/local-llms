#!/bin/sh
# Lifecycle of the router claude-local talks to: start one on demand, share it,
# stop it once nobody is left using it.
#
#   ./router.sh acquire <pid>   note that <pid> needs the router, starting one
#                               if this is the first; blocks until it answers
#   ./router.sh supervise       internal: owns the router, stops it once the
#                               last acquirer is gone
#
# Refcounted rather than one router per terminal, because these models are far
# too big to load twice. The count is a directory of pid files rather than a
# number, so a client that dies without saying so still drops out of it. A
# router started by hand with ./serve.sh is never adopted and never stopped.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SELF="$DIR/${0##*/}"
SERVE="$DIR/../serve.sh"

# The supervisor, and serve.sh under it, have to agree with claude-local here.
PORT=${PORT:-8080}
export PORT
BASE="http://127.0.0.1:${PORT}"

# One router per port, so its state is per port too. A fixed path, not
# mktemp -d: every terminal has to find the same directory.
RUN="${TMPDIR:-/tmp}/local_LLMs.$(id -u)/claude-local.$PORT"
CLIENTS="$RUN/clients"
LOCK="$RUN/lock"
LOG="$RUN/router.log"

POLL=3        # seconds between sweeps for clients that have gone away
STARTUP=90    # seconds a new router gets to answer /health

healthy() { curl -sf -o /dev/null --max-time 2 "$BASE/health"; }

# Start time of a pid, empty if it is gone. Recorded with each client and
# checked against it, so a recycled pid cannot pin the router up forever.
proc_stamp() { ps -o lstart= -p "$1" 2>/dev/null | awk '{ $1 = $1; print; exit }'; }

client_alive() {
    kill -0 "$1" 2>/dev/null || return 1
    _now=$(proc_stamp "$1")
    # A ps without lstart (busybox) leaves only the pid to go on. Erring
    # towards "alive" leaves a router up; the other way pulls one out from
    # under a live claude.
    [ -z "$_now" ] || [ -z "${2:-}" ] || [ "$_now" = "${2:-}" ]
}

# Clients still there, one pid per line, pruning the files of those that aren't.
live_clients() {
    for _f in "$CLIENTS"/*; do
        [ -e "$_f" ] || continue        # no matches: the glob stands as itself
        _pid=${_f##*/}
        if client_alive "$_pid" "$(cat "$_f" 2>/dev/null || :)"; then
            printf '%s\n' "$_pid"
        else
            rm -f "$_f"
        fi
    done
}

# A symlink is the lock: creating one is atomic, and it carries the owner's pid
# in the same step, leaving no window where nobody knows whose it is.
LOCK_HELD=""
lock_acquire() {
    _waited=0
    while ! ln -s "$$" "$LOCK" 2>/dev/null; do
        _owner=$(readlink "$LOCK" 2>/dev/null || :)
        if [ -z "$_owner" ]; then       # released under us; race for it again
            sleep 0.05
            continue
        fi
        if ! kill -0 "$_owner" 2>/dev/null; then
            # Owner killed mid-start. Re-read before removing, so we can only
            # break the dead lock we just looked at, never one taken since.
            if [ "$(readlink "$LOCK" 2>/dev/null || :)" = "$_owner" ]; then
                rm -f "$LOCK"
            fi
            continue
        fi
        # They may be sitting at a sudo prompt: better than looking hung.
        if [ "$_waited" = 8 ]; then
            echo "Waiting for another claude-local to finish starting the router..."
        fi
        _waited=$((_waited + 1))
        sleep 0.25
    done
    LOCK_HELD=1
}

lock_release() {
    [ -n "$LOCK_HELD" ] || return 0
    LOCK_HELD=""
    rm -f "$LOCK"
}

# Run "$@" beyond the reach of this terminal, output appended to $1: nohup, so
# the window closing cannot take it down (an ignored signal stays ignored
# across exec); its own process group, so a Ctrl+C meant for Claude Code cannot
# either, as the tty signals the whole foreground group; and no tty to hold
# open.
#
# setsid does the group part on Linux; macOS has none, but /bin/sh gives a
# background job its own group once job control is on. Never both: with job
# control on we are a group leader, the one case where setsid forks and $! then
# names the wrong process.
DETACHED_PID=""
spawn_detached() {
    _log=$1
    shift
    if command -v setsid >/dev/null 2>&1; then
        nohup setsid "$@" >>"$_log" 2>&1 </dev/null &
    else
        set -m 2>/dev/null || :
        nohup "$@" >>"$_log" 2>&1 </dev/null &
        set +m 2>/dev/null || :
    fi
    DETACHED_PID=$!
}

die_with_log() {
    echo "claude-local: $1" >&2
    if [ -s "$LOG" ]; then
        echo "--- last lines of $LOG ---" >&2
        tail -n 15 "$LOG" >&2 || :
    fi
    exit 1
}

start_router() {
    # In this terminal, before anything is detached: sudo prompts on /dev/tty,
    # which a background process group may not read from, and a preset that
    # still needs downloading should say so here, not in a log file.
    "$SERVE" --preflight

    echo "Starting the router on 127.0.0.1:${PORT}..."
    : > "$LOG"
    spawn_detached "$LOG" "$SELF" supervise
    _sup=$DETACHED_PID

    # A deadline rather than a count of turns: something that listens on the
    # port without ever answering makes each check cost its own timeout.
    _deadline=$(($(date +%s) + STARTUP))
    while ! healthy; do
        # The supervisor outlives its router by nothing, so this covers both.
        if ! kill -0 "$_sup" 2>/dev/null; then
            die_with_log "the router stopped while starting up"
        fi
        if [ "$(date +%s)" -ge "$_deadline" ]; then
            die_with_log "the router did not answer within ${STARTUP}s"
        fi
        sleep 0.25
    done
}

cmd_acquire() {
    CLIENT_PID=${1:-}
    case $CLIENT_PID in
        '' | *[!0-9]*) echo "usage: $0 acquire <pid>" >&2; exit 2 ;;
    esac
    mkdir -p "$CLIENTS" || exit 1

    # Both undo steps are no-ops until there is something to undo.
    trap 'rm -f "$CLIENTS/$CLIENT_PID"; lock_release' EXIT

    # Under the lock: two terminals opened at once must not both start a
    # router, and a supervisor counting its last client must not stop one in
    # the gap between us finding it healthy and using it. It counts under this
    # same lock, so it either sees us and leaves the router alone, or has
    # finished stopping one and the check below starts a fresh one.
    lock_acquire
    proc_stamp "$CLIENT_PID" > "$CLIENTS/$CLIENT_PID"
    healthy || start_router
    lock_release

    trap - EXIT
}

# Owns the router: only this stops it, and only ever what it started itself.
cmd_supervise() {
    mkdir -p "$CLIENTS" || exit 1
    printf '%s\n' "$$" > "$RUN/supervisor.pid"

    spawn_detached "$LOG" "$SERVE"      # no args: the ./serve.sh of the README
    ROUTER_PID=$DETACHED_PID
    printf '%s\n' "$ROUTER_PID" > "$RUN/router.pid"

    while :; do
        sleep "$POLL"
        # Died on its own, or killed by hand: nothing left to supervise.
        kill -0 "$ROUTER_PID" 2>/dev/null || break

        # Under the lock, and held across the stop: see cmd_acquire, and the
        # port has to be free again before anyone tries to bind it.
        lock_acquire
        if [ -z "$(live_clients)" ]; then
            stop_router
            lock_release
            break
        fi
        lock_release
    done

    # Only while they are still ours: a claude-local may have given up on this
    # router and started a fresh supervisor, and these would describe that one.
    if [ "$(cat "$RUN/supervisor.pid" 2>/dev/null || :)" = "$$" ]; then
        rm -f "$RUN/router.pid" "$RUN/supervisor.pid"
    fi
}

stop_router() {
    kill -0 "$ROUTER_PID" 2>/dev/null || return 0

    # What Ctrl+C on a foreground ./serve.sh does. The router's per-model child
    # servers go with it, killed outright or not.
    kill -TERM "$ROUTER_PID" 2>/dev/null || :

    # Insurance against one too wedged to go, cancelled once the TERM lands.
    (sleep 20; kill -KILL "$ROUTER_PID" 2>/dev/null || :) &
    _killer=$!
    wait "$ROUTER_PID" 2>/dev/null || :
    kill "$_killer" 2>/dev/null || :
}

case ${1:-} in
    acquire) shift; cmd_acquire "$@" ;;
    supervise) cmd_supervise ;;
    *) echo "usage: $0 acquire <pid> | $0 supervise" >&2; exit 2 ;;
esac
