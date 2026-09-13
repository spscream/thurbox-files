#!/usr/bin/env bash
# Build the interface directory these panes are meant to live in, the way an
# install lays it out: thurbox's own `ui/` as the base, this repository as a
# working copy beside it, the bundled agent pane deleted because ours replaces
# it, and the `files` slot placed in `layout.lua`.
#
# Used by CI and by you: the result is what `thurbox-cli plugin check` loads, so
# a failure here is a failure a user would have seen on their own screen.
#
#   ci/assemble-interface.sh <thurbox-checkout> <output-dir>
set -euo pipefail

UPSTREAM=${1:?usage: assemble-interface.sh <thurbox-checkout> <output-dir>}
OUT=${2:?usage: assemble-interface.sh <thurbox-checkout> <output-dir>}
HERE=$(cd "$(dirname "$0")/.." && pwd)

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -r "$UPSTREAM/ui" "$OUT"

# Ours lands where `plugin install` puts a cloned repository: a directory named
# after it, keeping its own `plugins/` prefix, so `require("lib.theme")` still
# resolves from the interface root exactly as it does after a real install.
mkdir -p "$OUT/thurbox-files/plugins"
cp "$HERE"/plugins/*.lua "$OUT/thurbox-files/plugins/"

# The bundled agent pane is what ours forks. Both loading is two occupants of
# the `center` slot, which is the state the README tells a user to avoid.
rm -f "$OUT/plugins/20_agent.lua"

cat > "$OUT/plugins.toml" <<'SPEC'
[[plugin]]
src = "git+https://github.com/spscream/thurbox-files"
file = "thurbox-files/plugins/90_files.lua"

[[plugin]]
src = "git+https://github.com/spscream/thurbox-files"
file = "thurbox-files/plugins/95_files_menu.lua"

[[plugin]]
src = "git+https://github.com/spscream/thurbox-files"
file = "thurbox-files/plugins/20_agent.lua"
SPEC

# The one line the column needs, inserted where the README says to put it. The
# anchor is thurbox's own; if it ever moves, this fails loudly rather than
# assembling an interface whose column is never placed — and the README snippet
# is then the thing to revisit.
python3 - "$OUT/layout.lua" "$HERE/ci/files-slot.lua" <<'PY'
import sys

layout_path, snippet_path = sys.argv[1], sys.argv[2]
layout = open(layout_path).read()
snippet = open(snippet_path).read()
anchor = '    columns[#columns + 1] = { slot = "center" }\n'
if anchor not in layout:
    sys.exit("layout.lua: the `center` column line this patch anchors on is gone")
open(layout_path, "w").write(layout.replace(anchor, anchor + snippet, 1))
PY

echo "assembled $OUT"
