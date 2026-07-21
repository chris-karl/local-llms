#!/bin/sh
# Sanitizing reverse-proxy that fronts llama-server for the Claude Code router.
#
# Why this exists: llama.cpp (checked on b10050 and b10075) compiles a tool's
# JSON-Schema *value* constraints -- pattern, format, min*/max*, minItems,
# propertyNames, ... -- into a grammar that forces tool-call arguments to match.
# Across Claude Code's full ~27-tool suite the combined grammar overflows
# llama.cpp's rule limit and the request fails closed:
#
#     400  Failed to initialize samplers: failed to parse grammar
#
# Only formats that grammar-constrain arguments hit it (gpt-oss harmony, devstral
# Mistral); the Qwen presets are immune. Neither the stable nor the HEAD build
# fixes it, and there is no flag for it.
#
# The fix: strip those value-constraint keywords from every tool schema before
# the request reaches llama-server. They only bound argument *values*; the tool's
# name, description and parameter structure are untouched, so tool calls still
# work -- the model just isn't grammar-forced to honour value bounds.
#
# Implementation is shell + jq + socat + curl (no extra language runtime):
#   - socat listens on the public port and forks a handler per connection;
#   - the handler (this script, --handle mode) reads the HTTP request, strips
#     the keywords with jq, forwards to llama-server with curl, and streams the
#     reply back (SSE stays live);
#   - responses use Connection: close, so one request per connection -- no
#     keep-alive framing to get wrong.
#
# It also *owns* the llama-server it fronts: launches the command after `--` on a
# private port, dies with it, kills it on TERM. So to router.sh it is just "the
# router on $PORT". serve.sh execs it in place of llama-server.
#
#   router-shim.sh --listen 127.0.0.1:8080 -- llama-server --models-preset ...
#   router-shim.sh --handle        (internal: run per connection by socat)
set -eu

SELF=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")

# Value-constraint keywords llama.cpp turns into grammar rules. Dropping them is
# what keeps the combined tool grammar under its limit.
STRIP='del(.pattern, .format, .minLength, .maxLength, .minimum, .maximum,
           .exclusiveMinimum, .exclusiveMaximum, .multipleOf, .minItems,
           .maxItems, .uniqueItems, .minProperties, .maxProperties,
           .propertyNames, .patternProperties)'

# --------------------------------------------------------------------------
# Per-connection handler (stdin/stdout = the client socket, via socat EXEC).
# --------------------------------------------------------------------------
handle() {
    CR=$(printf '\r')
    UP=${UPSTREAM_PORT:?}

    # Request line: "METHOD /path?query HTTP/1.1".
    IFS= read -r line || return 0
    line=${line%"$CR"}
    method=${line%% *}
    rest=${line#* }
    path=${rest%% *}
    case $path in /*) ;; *) path=/ ;; esac

    # claude-local points Claude Code at .../m/<model>/... so each session sees
    # only its own model in the /model picker. Strip the prefix here and remember
    # <model> to filter GET /v1/models below. Other callers omit it and are
    # forwarded unchanged.
    only_model=""
    case $path in
        /m/*/*) rest2=${path#/m/}; only_model=${rest2%%/*}; path=/${rest2#*/} ;;
    esac

    # Headers: we only need Content-Length. read is byte-at-a-time on a socket,
    # so it stops exactly at the blank line and leaves the body unread.
    clen=0
    while IFS= read -r h; do
        h=${h%"$CR"}
        [ -z "$h" ] && break
        case $h in
            [Cc]ontent-[Ll]ength:*) clen=$(printf '%s' "${h#*:}" | tr -dc '0-9') ;;
        esac
    done
    [ -n "$clen" ] || clen=0

    body=$(mktemp) || return 0
    [ "$clen" -gt 0 ] 2>/dev/null && head -c "$clen" > "$body"

    # Strip value-constraint keywords from tools; detect streaming. Non-JSON or
    # tool-less bodies pass through untouched.
    stream=0
    if [ "$method" = POST ] && [ -s "$body" ]; then
        if jq -c 'if has("tools") then .tools |= walk(if type == "object" then '"$STRIP"' else . end) else . end' \
              "$body" > "$body.s" 2>/dev/null; then
            mv "$body.s" "$body"
        else
            rm -f "$body.s"
        fi
        jq -e '.stream == true' "$body" >/dev/null 2>&1 && stream=1
    fi

    url="http://127.0.0.1:$UP$path"
    if [ "$stream" = 1 ]; then
        # Relay the upstream's real status and headers, then stream the body.
        # curl -i writes status + headers + body in order; the read loop consumes
        # just the header block (read is byte-at-a-time on a pipe, so it stops at
        # the blank line and leaves the body untouched) and cat streams the body
        # live. Framing headers are dropped and the body delimited by
        # Connection: close. This is what makes a streaming request the router
        # rejects (a context overflow, say) come back as its real 4xx/5xx rather
        # than a 200 with an error body mislabelled as SSE.
        curl -sN -i -X POST "$url" -H 'content-type: application/json' --data-binary @"$body" | {
            if ! IFS= read -r _st || [ -z "$_st" ]; then
                printf 'HTTP/1.1 502 .\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n'
                printf '{"error":{"type":"unavailable","message":"no response from llama-server"}}'
                exit 0
            fi
            printf '%s\r\n' "${_st%"$CR"}"
            while IFS= read -r _h; do
                _h=${_h%"$CR"}
                [ -z "$_h" ] && break
                case $_h in
                    [Tt]ransfer-[Ee]ncoding:* | [Cc]ontent-[Ll]ength:* | [Cc]onnection:*) continue ;;
                esac
                printf '%s\r\n' "$_h"
            done
            printf 'Connection: close\r\n\r\n'
            cat
        }
    else
        out=$(mktemp) || { rm -f "$body"; return 0; }
        if [ "$method" = POST ]; then
            code=$(curl -s -o "$out" -w '%{http_code}' -X POST "$url" \
                        -H 'content-type: application/json' --data-binary @"$body")
        else
            code=$(curl -s -o "$out" -w '%{http_code}' -X "$method" "$url")
        fi
        [ -n "$code" ] || code=502
        # Keep only the session's model in the picker's list.
        if [ -n "$only_model" ]; then
            case $path in
                /v1/models*)
                    if jq -c --arg m "$only_model" '.data |= map(select(.id == $m))' \
                          "$out" > "$out.f" 2>/dev/null; then mv "$out.f" "$out"; else rm -f "$out.f"; fi ;;
            esac
        fi
        printf 'HTTP/1.1 %s .\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n' "$code"
        cat "$out"
        rm -f "$out"
    fi
    rm -f "$body"
}

# --------------------------------------------------------------------------
case ${1:-} in
    --handle) handle; exit 0 ;;
esac

# --------------------------------------------------------------------------
# Main: launch + own llama-server, run the socat front door.
# --------------------------------------------------------------------------
LISTEN=""
while [ $# -gt 0 ]; do
    case $1 in
        --listen) LISTEN=$2; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
[ -n "$LISTEN" ] || { echo "router-shim.sh: --listen HOST:PORT required" >&2; exit 2; }
[ $# -gt 0 ] || { echo "router-shim.sh: no upstream command after --" >&2; exit 2; }

LHOST=${LISTEN%:*}
LPORT=${LISTEN##*:}
UP=$((LPORT + 1))   # llama-server's private port

# Launch llama-server on the private port; its output is ours (-> router.log).
"$@" --host 127.0.0.1 --port "$UP" &
LLAMA=$!

cleanup() {
    kill "$LLAMA" 2>/dev/null || :
    [ -n "${WATCH:-}" ] && kill "$WATCH" 2>/dev/null || :
    [ -n "${SOCAT:-}" ] && kill "$SOCAT" 2>/dev/null || :
}
trap 'cleanup; exit 0' TERM INT
trap cleanup EXIT

# If llama-server exits on its own, take the shim down so router.sh notices.
( while kill -0 "$LLAMA" 2>/dev/null; do sleep 2; done; kill "$$" 2>/dev/null || : ) &
WATCH=$!

UPSTREAM_PORT="$UP"
export UPSTREAM_PORT
socat "TCP-LISTEN:$LPORT,bind=$LHOST,reuseaddr,fork" "EXEC:$SELF --handle" &
SOCAT=$!
wait "$SOCAT"
