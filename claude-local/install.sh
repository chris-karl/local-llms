#!/bin/sh
# Put "claude-local" on your PATH, so Claude Code can be pointed at the local
# router from any directory instead of only from this repo.
#
#   ./install.sh                            symlink into ~/.local/bin
#   BIN_DIR=/usr/local/bin sudo ./install.sh
#   ./install.sh --no-rc                    link only, never touch a shell rc
#
# The link is a symlink, not a copy, so moving this repo breaks it (re-run to
# fix). Undo with ./uninstall.sh.
set -eu

MARK_START='# >>> claude-local >>>'
MARK_END='# <<< claude-local <<<'

no_rc=0
for arg in "$@"; do
    case $arg in
        --no-rc) no_rc=1 ;;
        # The header block above, up to the first line of actual code.
        -h|--help) sed -n '2,/^[^#]/p' "$0" | sed '$d' | cut -c3-; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET="$DIR/claude-local.sh"

if [ ! -f "$TARGET" ]; then
    echo "claude-local.sh is not next to this script (looked in $DIR)" >&2
    exit 1
fi
[ -x "$TARGET" ] || chmod +x "$TARGET"

BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
LINK="$BIN_DIR/claude-local"

# Never clobber a real file: only ever replace a symlink we could have made.
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
    echo "$LINK already exists and is not a symlink -- leaving it alone." >&2
    echo "Remove it yourself, or pick another dir:  BIN_DIR=... $0" >&2
    exit 1
fi

mkdir -p "$BIN_DIR"

if [ -L "$LINK" ]; then
    old=$(readlink "$LINK")
    [ "$old" = "$TARGET" ] || echo "  relink   was pointing at $old"
fi

ln -sfn "$TARGET" "$LINK"
echo "  linked   $LINK -> $TARGET"

# Already reachable? Then there is nothing to configure.
case ":$PATH:" in
    *":$BIN_DIR:"*)
        echo
        echo "Done. Start the router with ./serve.sh, then run:  claude-local"
        exit 0
        ;;
esac

if [ "$no_rc" -eq 1 ]; then
    echo
    echo "$BIN_DIR is not on your PATH. Add it yourself, e.g.:"
    echo "    export PATH=\"$BIN_DIR:\$PATH\""
    exit 0
fi

# The login shell, not the one running this script: the rc file that matters
# is the one your terminals actually read. Fall back to the user record if
# $SHELL is unset (cron, etc).
login_shell=${SHELL:-}
if [ -z "$login_shell" ] && command -v dscl >/dev/null 2>&1; then
    login_shell=$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null \
        | sed 's/^UserShell: //')
fi
if [ -z "$login_shell" ] && command -v getent >/dev/null 2>&1; then
    login_shell=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
fi
shell_name=$(basename "${login_shell:-sh}")

case $shell_name in
    zsh)  rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
    # macOS opens login shells, which read .bash_profile and never .bashrc;
    # most Linux terminals are the other way round.
    bash) if [ "$(uname -s)" = Darwin ]
          then rc="$HOME/.bash_profile"
          else rc="$HOME/.bashrc"
          fi ;;
    fish) rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
    ksh)  rc="$HOME/.kshrc" ;;
    sh|dash) rc="$HOME/.profile" ;;
    *)    rc="$HOME/.profile"
          echo "  note     unrecognised shell '$shell_name', assuming POSIX" ;;
esac

if [ -f "$rc" ] && grep -qF "$MARK_START" "$rc"; then
    echo "  rc       $rc already has the PATH block"
else
    # Keep $HOME symbolic so the rc file stays portable across machines.
    path_expr=$BIN_DIR
    case $BIN_DIR in
        "$HOME"/*) path_expr="\$HOME${BIN_DIR#"$HOME"}" ;;
    esac

    mkdir -p "$(dirname "$rc")"

    # Guarded rather than a bare prepend, so nested shells don't stack up
    # duplicate PATH entries; the markers are what uninstall.sh matches on.
    # The leading \n also terminates a last line that lacks one, which is the
    # one thing uninstall.sh cannot undo -- such an rc keeps a trailing
    # newline afterwards.
    if [ "$shell_name" = fish ]; then
        {
            printf '\n%s\n' "$MARK_START"
            printf 'if not contains "%s" $PATH\n' "$path_expr"
            printf '    set -gx PATH "%s" $PATH\n' "$path_expr"
            printf 'end\n'
            printf '%s\n' "$MARK_END"
        } >> "$rc"
    else
        {
            printf '\n%s\n' "$MARK_START"
            printf 'case ":$PATH:" in\n'
            printf '    *":%s:"*) ;;\n' "$path_expr"
            printf '    *) export PATH="%s:$PATH" ;;\n' "$path_expr"
            printf 'esac\n'
            printf '%s\n' "$MARK_END"
        } >> "$rc"
    fi
    echo "  rc       added PATH block to $rc ($shell_name)"
fi

echo
echo "$BIN_DIR was not on your PATH. Pick up the change with:"
echo "    . $rc          # or just open a new terminal"
echo
echo "Then, with ./serve.sh running, 'claude-local' works from anywhere."
