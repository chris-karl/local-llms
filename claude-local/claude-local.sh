#!/bin/sh
# Run Claude Code against a local model, starting the router if it isn't up.
# Everything is scoped to this one process, so a plain "claude" in any other
# terminal still talks to the real Anthropic API.
#
#   ./claude-local.sh                  pick a model from a menu, then start
#
# The router is shared and refcounted: it is stopped once the last claude-local
# exits, not when the one that started it does. See router.sh. One started by
# hand with ./serve.sh is used as-is and never stopped.
#
# ./install.sh puts this on your PATH as "claude-local", usable from any
# directory. The session runs on the model you pick; /model is scoped to just
# it, so switching models means restarting.
set -eu

# Follow the symlink install.sh puts on your PATH, so router.sh and serve.sh
# are found in the checkout rather than next to the link.
SELF=$0
case $SELF in
    */*) ;;
    *) SELF=$(command -v -- "$SELF") ;;
esac
_hops=0
while [ -L "$SELF" ] && [ "$_hops" -lt 16 ]; do
    _link=$(readlink -- "$SELF")
    case $_link in
        /*) SELF=$_link ;;
        *) SELF=$(dirname -- "$SELF")/$_link ;;
    esac
    _hops=$((_hops + 1))
done
DIR=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd)
INI="$DIR/../models.ini"
. "$DIR/../lib.sh"

PORT=${PORT:-8080}
BASE="http://127.0.0.1:${PORT}"

# Pick the model for this session. Only one model is resident (--models-max 1)
# and Claude Code drives two slots -- a main model and a background "haiku" one
# -- so both run the SAME model, chosen here. The picker is then scoped to it
# (see the base URL below and router-shim.sh), so switching means restarting.
# Presets whose context is too small for Claude Code's system prompt are left out.
MIN_CTX=32768   # below this a preset can't hold Claude Code's ~29K prompt
_rows=$(for _m in $(presets); do
    _ctx=$(key_of "$_m" ctx-size)
    if [ -n "$_ctx" ] && [ "$_ctx" -ge "$MIN_CTX" ] 2>/dev/null; then
        printf '%s\t%s\n' "$_m" "$_ctx"
    fi
done)
[ -n "$_rows" ] || { echo "claude-local: no Claude Code-capable models in $INI" >&2; exit 1; }
echo "Model for this Claude Code session:"
echo
printf '%s\n' "$_rows" | awk -F'\t' '{ printf "  %d) %-18s %dK ctx\n", NR, $1, $2 / 1024 }'
_n=$(printf '%s\n' "$_rows" | grep -c .)
# Read from the terminal, not the caller's stdin: we exec claude next.
choose "$_n" < /dev/tty
ANTHROPIC_MODEL="claude-$(printf '%s\n' "$_rows" | sed -n "${CHOICE}p" | cut -f1)"
echo

# Registers this shell as one of the things keeping the router alive, starting
# one if there is none. "exec claude" below keeps this pid, so the router lives
# exactly as long as the session does, however it ends. PORT is passed rather
# than exported: it is router.sh's business, not claude's.
PORT="$PORT" "$DIR/router.sh" acquire "$$"

export ANTHROPIC_MODEL

# The model is baked into the base URL path (/m/<model>). router-shim.sh strips
# it and filters GET /v1/models down to this one model, so Claude Code's /model
# picker shows only it -- no mid-session switch, restart to change models.
export ANTHROPIC_BASE_URL="$BASE/m/$ANTHROPIC_MODEL"

# llama-server ignores auth unless --api-key is set, but Claude Code needs
# some credential present or it falls back to your real login.
export ANTHROPIC_AUTH_TOKEN="local"

# Populates /model from the router's /v1/models. Needs Claude Code >= 2.1.129.
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

# The background "haiku" slot (titles, summaries) runs the same model as the
# main one, so the single resident model (--models-max 1) never thrashes.
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$ANTHROPIC_MODEL"

exec claude "$@"
