#!/usr/bin/env bash
# Record media/demo.gif: the real TUI, in a throwaway thurbox this repository's
# panes were installed into.
#
# asciinema records the pty and agg rasterises the cast — not VHS, which drives
# a headless browser and could not emit an F-key even if it worked here. Both
# doors into this feature (F3 for the column, F6 for settings) are F-keys, so
# the recording presses the real chords a user presses.
#
# Needs: asciinema, agg, tmux, git, sqlite3, nvim (the editor tab runs it) and a
# thurbox on PATH. See demo/sandbox.sh for what is thrown away afterwards.
#
#   demo/record.sh [output.gif]
#
# SNAP=<dir> writes what the screen held at each step there, which is the only
# way to tell a key that missed from a key that landed on the wrong row: the
# cast is gone with the sandbox by the time the GIF looks wrong.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$REPO/media/demo.gif}
THURBOX=${THURBOX:-thurbox}
COLS=${COLS:-150}
ROWS=${ROWS:-42}
SNAP=${SNAP:-}
# The public repository, so the line thurbox prints while trusting a pane names
# a source a reader can install from rather than a path on the machine that
# recorded it.
export DEMO_SRC=${DEMO_SRC:-git+https://github.com/spscream/thurbox-files}

missing=
for tool in asciinema agg tmux git sqlite3 nvim "$THURBOX"; do
    command -v "$tool" >/dev/null || missing="$missing $tool"
done
[ -n "$missing" ] && { echo "missing:$missing" >&2; exit 2; }

S=$("$REPO/demo/sandbox.sh")
TM="tmux -L thurbox-files-demo"
cleanup() {
    TMUX_TMPDIR="$S/tmux" $TM kill-server 2>/dev/null || true
    TMUX_TMPDIR="$S/tmux" tmux -L thurbox kill-server 2>/dev/null || true
    rm -rf "$S"
}
trap cleanup EXIT INT TERM

cat > "$S/run.sh" <<RUN
#!/usr/bin/env bash
export HOME="$S"
export XDG_CONFIG_HOME="$S/.config" XDG_DATA_HOME="$S/.local/share"
export XDG_STATE_HOME="$S/.local/state" XDG_CACHE_HOME="$S/.cache"
export TMUX_TMPDIR="$S/tmux"
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR
cd "$S/sample-project"
exec $(command -v "$THURBOX")
RUN
chmod +x "$S/run.sh"

export TMUX_TMPDIR="$S/tmux"
CAST="$S/demo.cast"
$TM new-session -d -x "$COLS" -y "$ROWS" \
    "asciinema rec --overwrite --quiet --command '$S/run.sh' '$CAST'"

# One key, then a pause long enough to read what it did. `send-keys` reaches the
# recorded program, so what lands in the cast is the real interface reacting.
k() { $TM send-keys -t 0 "$1"; sleep "${2:-0.8}"; }
snap() { [ -n "$SNAP" ] && $TM capture-pane -p -t 0 > "$SNAP/$1.txt"; true; }
[ -n "$SNAP" ] && mkdir -p "$SNAP"

# Wait for the first frame rather than guessing: a cold start reads the DB,
# boots tmux and spawns two sessions.
for _ in $(seq 1 40); do
    $TM capture-pane -p -t 0 2>/dev/null | grep -q 'Sessions' && break
    sleep 1
done
sleep 3

# Trust, pressed rather than seeded: `run` for the Changes tab, `program` for
# the editor tab. This is thurbox's own flow — F6, ] for the Interface tab, `t`
# on a pane — and it is in the recording because a pane you have not trusted
# draws a different thing.
k F6 1.5; k "]" 1.5
k j 0.4; k j 0.4; k j 0.4
k t 1.0
k j 0.4
k t 1.2
k Escape 2
snap 1-trusted

# Into the column and down to a source file. F3 is the way in and the way out.
k F3 1.5
k j; k j
k Enter 1.2       # src opens in place, under its own row
k j; k j
snap 2-tree

# Enter on a file emits `user.openfile`. The agent pane runs nvim on it in a tab
# of its own, beside the agent rather than over it.
k Enter 6
snap 3-editor

# Back to the column and over to what git says changed.
k F3 1.2
k Tab 2
snap 4-changes

# The Changes tab comes up already open on the one directory that has an edit
# in it, with the directory row selected — so a step down, not an expand, is
# what puts Enter on a file with a diff behind it. (An Enter here collapses the
# directory instead, which is how the first recording ended on no diff at all.)
k j 1.2
snap 5-file-picked
k Enter 5
snap 6-diff

# A beat on the diff before quitting: the last frame of a GIF is the one a
# reader looks at while deciding whether to scroll on.
sleep 3

# Quit, which is what ends the recording: asciinema writes the cast when the
# command it wrapped exits.
k C-q 3
for _ in $(seq 1 20); do [ -s "$CAST" ] && break; sleep 1; done

# A GIF loops, so its last frame is on screen as long as its first one. Quitting
# leaves a bare shell there, so the cast is cut where teardown starts: thurbox
# runs with the cursor hidden, so the cursor coming back (or the alternate
# screen going away) is the first byte of the exit and everything from there on
# is dropped. The last thing recorded is then the diff it was showing.
python3 - "$CAST" <<'TRIM'
import json, sys

path = sys.argv[1]
lines = open(path).read().splitlines()
for i, line in enumerate(lines[1:], start=1):  # line 0 is the header
    data = json.loads(line)[2]
    if "\x1b[?25h" in data or "\x1b[?1049l" in data:
        open(path, "w").write("\n".join(lines[:i]) + "\n")
        break
TRIM

mkdir -p "$(dirname "$OUT")"
agg --font-size 14 --idle-time-limit 1.5 --theme asciinema "$CAST" "$OUT"
ls -lh "$OUT"
