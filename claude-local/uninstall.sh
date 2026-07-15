#!/bin/sh
# Undo ./install.sh, exactly: drop the symlink, the PATH block, and the bin
# dir it made. Leaves no trace.
#
#   ./uninstall.sh
#   BIN_DIR=/usr/local/bin sudo ./uninstall.sh
#
# Each step is scoped to what install.sh actually created: only a symlink
# pointing back at this checkout, only the marker-delimited rc block, and only
# an empty bin dir. Nothing here touches claude-local.sh or the models.
set -eu

MARK_START='# >>> claude-local >>>'
MARK_END='# <<< claude-local <<<'

for arg in "$@"; do
    case $arg in
        # The header block above, up to the first line of actual code.
        -h|--help) sed -n '2,/^[^#]/p' "$0" | sed '$d' | cut -c3-; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET="$DIR/claude-local.sh"
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
LINK="$BIN_DIR/claude-local"

if [ ! -e "$LINK" ] && [ ! -L "$LINK" ]; then
    echo "  none     no link at $LINK"
    # A leftover on PATH from some other dir is worth pointing at.
    other=$(command -v claude-local 2>/dev/null || true)
    [ -n "$other" ] && echo "  note     but 'claude-local' still resolves to $other"
elif [ ! -L "$LINK" ]; then
    echo "$LINK is a real file, not a symlink -- install.sh did not create it." >&2
    echo "Leaving it alone; remove it yourself if you want it gone." >&2
    exit 1
else
    dest=$(readlink "$LINK")
    # Only remove a link that points back into this checkout. Anything else is
    # someone else's claude-local and not ours to delete.
    if [ "$dest" != "$TARGET" ]; then
        echo "$LINK points at $dest, not at $TARGET." >&2
        echo "Leaving it alone -- remove it by hand if you do want it gone." >&2
        exit 1
    fi
    rm -f "$LINK"
    echo "  removed  $LINK"
fi

# Look in every rc file rather than only the current shell's: the block should
# still be found if the login shell changed since install.
found_rc=""
for rc in \
    "${ZDOTDIR:-$HOME}/.zshrc" \
    "$HOME/.bashrc" \
    "$HOME/.bash_profile" \
    "$HOME/.profile" \
    "$HOME/.kshrc" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
do
    [ -f "$rc" ] || continue
    grep -qF "$MARK_START" "$rc" 2>/dev/null || continue
    found_rc="$rc"

    # Drop the block, plus the single blank line install.sh put in front of it,
    # so a round trip leaves the rc byte-identical. Blank lines that were
    # already yours are buffered and printed back. Written back through a temp
    # file so the rc keeps its own inode and permissions.
    tmp=$(mktemp)
    awk -v s="$MARK_START" -v e="$MARK_END" '
        function flush(  i) { for (i = 0; i < pend; i++) print ""; pend = 0 }
        skip            { if ($0 == e) skip = 0; next }
        $0 == s         { if (pend > 0) pend--; flush(); skip = 1; next }
        /^[ \t]*$/      { pend++; next }
                        { flush(); print }
        END             { flush() }
    ' "$rc" > "$tmp"
    cat "$tmp" > "$rc"
    rm -f "$tmp"
    echo "  purged   PATH block from $rc"
done

# install.sh did a mkdir -p, so undo that too. rmdir only ever removes an
# empty dir, so a BIN_DIR holding other tools survives -- but it is off your
# PATH now, which is worth saying out loud.
if [ -d "$BIN_DIR" ]; then
    if rmdir "$BIN_DIR" 2>/dev/null; then
        echo "  rmdir    $BIN_DIR (was left empty)"
    else
        leftovers=$(ls -A "$BIN_DIR" 2>/dev/null || true)
        if [ -n "$leftovers" ] && [ -n "$found_rc" ]; then
            echo "  kept     $BIN_DIR, not empty -- and now off your PATH:"
            printf '%s\n' "$leftovers" | sed 's/^/               /'
        fi
    fi
fi

echo
if [ -n "$found_rc" ]; then
    echo "Done. Open a new terminal for the PATH change to take effect."
else
    echo "Done. 'claude-local' is gone; ./claude-local/claude-local.sh still works."
fi
