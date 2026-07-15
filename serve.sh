#!/bin/sh
# Router server exposing every model in models.ini. Serves the Anthropic
# Messages API on /v1/messages natively, so Claude Code needs no proxy, and
# the OpenAI API on /v1/chat/completions for everything else.
#
#   ./serve.sh                 listen on 127.0.0.1:8080
#   PORT=9000 ./serve.sh       listen elsewhere
#   ./serve.sh --no-webui      API only, no browser UI
#
# Then, in another terminal: ./claude-local/claude-local.sh
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INI="$DIR/models.ini"
PORT=${PORT:-8080}
HUB="${HF_HOME:-$HOME/.cache/huggingface}/hub"

# A fixed path, not mktemp -d: this script exec's into llama-server, so no exit
# trap can ever run to clean up. Contents derive wholly from models.ini, so
# concurrent servers can share it.
TMP="${TMPDIR:-/tmp}/local_LLMs.$(id -u)"
mkdir -p "$TMP" || exit 1

presets() { awk -F'[][]' '/^[ \t]*\[/ { print $2 }' "$INI"; }

# Value of one key inside one section, empty if absent.
key_of() {
    awk -v want="$1" -v key="$2" '
        /^[ \t]*#/ { next }
        /^[ \t]*\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); insec = (s == want); next }
        !insec || !/=/ { next }
        {
            k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
            v = $0; sub(/^[^=]*=/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (k == key) { print v; exit }
        }
    ' "$INI"
}

# "owner/repo:QUANT" -> the .gguf it currently resolves to, mirroring
# --hf-repo. Reading refs/main each launch is what keeps this off a stale
# revision.
resolve_gguf() {
    _spec=$1
    _repo=${_spec%:*}
    _quant=${_spec##*:}
    _dir="$HUB/models--$(echo "${_repo%%/*}" | tr -d '\n')--$(echo "${_repo#*/}" | tr -d '\n')"
    [ -d "$_dir" ] || return 1
    _sha=$(cat "$_dir/refs/main" 2>/dev/null) || return 1
    [ -n "$_sha" ] || return 1
    _snap="$_dir/snapshots/$_sha"
    [ -d "$_snap" ] || return 1
    find "$_snap" -maxdepth 1 -name "*-$_quant.gguf" ! -name "mmproj*" 2>/dev/null | head -1
}

# The vision projector next to it, if the repo ships one.
resolve_mmproj() {
    _g=$1
    find "$(dirname "$_g")" -maxdepth 1 -name "mmproj*.gguf" 2>/dev/null | head -1
}

# section <tab> gguf <tab> mmproj-or-empty
MAP="$TMP/map"
: > "$MAP"
MISSING=""
for m in $(presets); do
    spec=$(key_of "$m" "hf-repo")
    if [ -z "$spec" ]; then
        # Already an explicit path (or no model at all) -- leave it alone.
        continue
    fi
    if ! gguf=$(resolve_gguf "$spec") || [ -z "$gguf" ]; then
        MISSING="$MISSING  $m ($spec)
"
        continue
    fi
    mm=""
    if [ -z "$(key_of "$m" "no-mmproj")" ]; then
        mm=$(resolve_mmproj "$gguf")
    fi
    printf '%s\t%s\t%s\n' "$m" "$gguf" "$mm" >> "$MAP"
done

if [ -n "$MISSING" ]; then
    echo "not downloaded yet:" >&2
    printf '%s' "$MISSING" >&2
    echo "fetch each once with:  ./chat.sh <model>    (that path still uses hf-repo)" >&2
    exit 1
fi

# Rewrite hf-repo lines into resolved paths and section names into
# claude-prefixed ids; everything else verbatim. Runs fresh on every launch,
# so models.ini stays portable and this can't go stale.
RESOLVED="$TMP/models.resolved.ini"
awk -v mapfile="$MAP" -v dir="$DIR" '
    BEGIN {
        FS = "\t"
        while ((getline line < mapfile) > 0) {
            split(line, a, "\t")
            gguf[a[1]] = a[2]; mmproj[a[1]] = a[3]
        }
        FS = "\n"
    }
    # Claude Code hard-filters gateway /v1/models to ids matching
    # ^(claude|anthropic), with no way to turn it off, so advertise the
    # prefixed id and keep the bare name routable via --alias. See README.
    /^[ \t]*\[/ {
        s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); sec = s
        if (tolower(sec) ~ /^(claude|anthropic)/) print "[" sec "]"
        else printf "[claude-%s]\nalias = %s\n", sec, sec
        next
    }
    {
        k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
        # Ours, not a llama.cpp flag -- the router refuses to start on it.
        if (k == "wired-limit-mb") next
        if (k == "hf-repo" && sec in gguf) {
            printf "model = %s\n", gguf[sec]
            if (mmproj[sec] != "") printf "mmproj = %s\n", mmproj[sec]
            next
        }
        # Written relative to models.ini; the router would resolve it against
        # its own CWD instead.
        if (k == "chat-template-file") {
            v = $0; sub(/^[^=]*=/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
            printf "chat-template-file = %s\n", (v ~ /^\// ? v : dir "/" v)
            next
        }
        print
    }
' "$INI" > "$RESOLVED"

# The router loads on demand, so raise the cap to the largest any preset asks
# for. It's a cap, not a reservation; resets on reboot.
NEED=$(awk '
    /^[ \t]*#/ { next }
    !/=/ { next }
    {
        k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
        if (k != "wired-limit-mb") next
        v = $0; sub(/^[^=]*=/, "", v)
        if (v + 0 > m) m = v + 0
    }
    END { print m + 0 }
' "$INI")
if [ "$NEED" -gt 0 ]; then
    current=$(sysctl -n iogpu.wired_limit_mb)
    if [ "$current" -eq 0 ] || [ "$current" -lt "$NEED" ]; then
        echo "Raising GPU wired limit to ${NEED} MB (sudo)..."
        sudo sysctl iogpu.wired_limit_mb="$NEED" || exit 1
    fi
fi

echo "Serving $(presets | wc -l | tr -d ' ') models from models.ini on 127.0.0.1:${PORT}"

# HF_HOME points at an empty dir to stop the router advertising the whole
# llama.cpp cache alongside the presets, listing each model twice in /model
# (no flag for that in b9960) -- which is also why the presets carry absolute
# paths by now. --models-max 1 is load-bearing: 16 GB holds exactly one of
# these models, and the default of 4 would OOM on every /model switch.
mkdir -p "$TMP/emptycache"
HF_HOME="$TMP/emptycache" exec llama-server \
    --models-preset "$RESOLVED" \
    --models-max 1 \
    --host 127.0.0.1 \
    --port "$PORT" \
    "$@"
