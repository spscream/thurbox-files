#!/usr/bin/env bash
# Build a throwaway thurbox that has these panes installed, and print its root.
#
# Nothing here can touch a real interface, a real database or a real tmux
# server: HOME and every XDG root point at a fresh mktemp directory, and
# TMUX_TMPDIR gives the server its own socket directory — the socket NAME is
# shared by every thurbox of the same build, so without that a teardown would
# kill sessions you have running.
#
# The panes are installed the way the README says to install them, from a local
# clone of THIS repository (`git+file://`), so what a recording shows is what a
# user gets — committed state, not the working tree. Set DEMO_SRC to install
# from somewhere else; demo/record.sh points it at the public repository so the
# line thurbox prints while trusting a pane names a URL anyone can type.
#
#   demo/sandbox.sh
#
# Prints the sandbox root on stdout. The caller owns teardown:
#   TMUX_TMPDIR=<root>/tmux tmux -L thurbox kill-server; rm -rf <root>
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
CLI=${THURBOX_CLI:-thurbox-cli}
command -v "$CLI" >/dev/null || { echo "no thurbox-cli on PATH (set THURBOX_CLI)" >&2; exit 2; }
command -v sqlite3 >/dev/null || { echo "sqlite3 is needed to skip the first-launch gate" >&2; exit 2; }

S=$(mktemp -d /tmp/thurbox-files-demo.XXXXXX)
export HOME="$S"
export XDG_CONFIG_HOME="$S/.config" XDG_DATA_HOME="$S/.local/share"
export XDG_STATE_HOME="$S/.local/state" XDG_CACHE_HOME="$S/.cache"
export TMUX_TMPDIR="$S/tmux"
# paths.rs honours these ahead of XDG, so an inherited one would defeat the
# isolation and point the sandbox at a real config.
unset THURBOX_CONFIG_DIR THURBOX_DATA_DIR
mkdir -p "$XDG_CONFIG_HOME/thurbox" "$XDG_DATA_HOME/thurbox" "$TMUX_TMPDIR"

# A stub agent: a long-lived shell, so a session exists and the centre pane has
# something to draw without a real agent CLI or an account.
cat > "$XDG_CONFIG_HOME/thurbox/agents.toml" <<'AGENTS'
default = "stub"

[[agents]]
name = "stub"
command = "sh"
args = ["-c", "echo stub agent; exec sh"]
AGENTS

# A small repository for the tree to show, with one edit already made so the
# Changes tab has something in it.
R="$S/sample-project"
mkdir -p "$R/src" "$R/docs" "$R/tests"
printf '# sample-project\n\nA small repo used to show the file column.\n' > "$R/README.md"
printf 'fn main() {\n    println!("hello");\n}\n' > "$R/src/main.rs"
printf 'pub fn width(input: &str) -> usize {\n    input.len()\n}\n' > "$R/src/width.rs"
printf 'Design notes.\n' > "$R/docs/design.md"
printf '#[test]\nfn widths() {\n    assert_eq!(1, 1);\n}\n' > "$R/tests/width.rs"
git init -q "$R"
git -C "$R" add -A
git -C "$R" -c user.email=demo@example.com -c user.name=demo commit -qm 'initial'
printf 'pub fn width(input: &str) -> usize {\n    // count graphemes, not bytes\n    input.chars().count()\n}\n' > "$R/src/width.rs"

# Installed, not copied: this is the flow the README documents.
SRC=${DEMO_SRC:-git+file://$REPO}
for pane in 90_files 95_files_menu 20_agent; do
    "$CLI" plugin install "$SRC" --as "plugins/$pane.lua" >/dev/null
done
U="$XDG_CONFIG_HOME/thurbox/ui"
rm -f "$U/plugins/20_agent.lua"
python3 - "$U/layout.lua" "$REPO/ci/files-slot.lua" <<'PY'
import sys
layout_path, snippet_path = sys.argv[1], sys.argv[2]
layout = open(layout_path).read()
snippet = open(snippet_path).read()
anchor = '    columns[#columns + 1] = { slot = "center" }\n'
if anchor not in layout:
    sys.exit("layout.lua: the `center` column line this patch anchors on is gone")
open(layout_path, "w").write(layout.replace(anchor, anchor + snippet, 1))
PY

"$CLI" session create --name fix-width --repo-path "$R" --agent stub >/dev/null
"$CLI" session create --name docs-column --repo-path "$R" --agent stub >/dev/null

# The first launch asks whether to continue to v2 and waits for an answer. A
# recording is about the panes, so the answer is recorded up front.
sqlite3 "$XDG_DATA_HOME/thurbox/thurbox.db" \
    "INSERT INTO metadata (key, value) VALUES ('v2_interface_acknowledged', '1')
     ON CONFLICT(key) DO UPDATE SET value = '1';"

"$CLI" plugin check --text >&2
echo "$S"
