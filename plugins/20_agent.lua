-- The central terminal pane: the agent's terminal and a shell, as two TABS of
-- one pane.
--
-- This is the pane that made "everything is a plugin" worth arguing about: it
-- shows a LIVE terminal, which cannot round-trip through Lua tables at 20fps.
--
-- The resolution is that `surface` is a NODE KIND, not a kernel pane. This
-- plugin places and frames it, decides which session it shows, and owns the key
-- rules; the kernel only fills the rect with cells. Lua does not paint a
-- `list`'s glyphs either — same deal.
--
-- The two views are ONE plugin because that is what v1 is: `CentralTab` selects
-- a view of a single pane, and the strip that selects it is drawn on that
-- pane's border. Modelling them as two plugins taking turns in the `switch`
-- slot cost the strip on every tab but the agent's, a second stop in the focus
-- ring, and a slot arbitration that existed only to referee them
-- (v2-system-modals D4).
--
-- Replace this file and you have replaced the central pane.
--
-- The chrome here is an ordinary kernel `frame`. It was drawn by hand for as
-- long as a frame could not express the three things v1's terminal pane needs:
-- a RIGHT-aligned border title, a STYLED one (the focused badge is
-- inverted_fg-on-accent), and a scrollbar overlaid on the right border column
-- so it costs zero content columns. `title_align`, styled title runs and
-- `frame.overlay` are each of those, so the border is one table again and the
-- surface keeps the whole inner rect.

local chrome = require("lib.chrome")
local panels = require("lib.panels")
local hover = require("lib.hover")
local plugin_settings = require("lib.settings")
local theme = require("lib.theme")
local widgets = require("lib.widgets")

--- What this plugin is called. Declared once because the pane has to name
--- ITSELF to bring itself forward (`command("focus", …)`).
local NAME = "agent"

--- The tabs this pane owns, and the actions that select each. The chips select
--- (v1 `select_central_tab`, idempotent); the `shell.open` chord toggles (v1
--- `toggle_shell_view`) — two behaviours, so two entry points.
---
--- v1 has a third view here, the code review. Adding it back is a `REVIEW_TAB`
--- value, a chip naming its select action, and a branch beside the surface in
--- `render` returning the diff body — after which the strip covers it for the
--- same reason it now covers the shell.
--- Is the companion shell available at all?
---
--- v1 gates the pane, its chord and its tab on `[features] shell_pane`; this pane
--- owns all three in v2, so it is the thing that has to ask.
local function shell_enabled()
  return plugin_settings.feature("shell_pane", true) ~= false
end

local AGENT_TAB, SHELL_TAB = "agent", "shell"
local SELECT_AGENT, SELECT_SHELL = "terminal.agent", "terminal.shell"
--- The third view, which is where v1's `Review · F7` chip used to point.
---
--- It is a tab of THIS pane rather than a plugin of its own for the reason the
--- header gives about the shell: a second occupant of the `switch` slot draws
--- over this one entire, so it loses the strip, gains a stop in the focus ring
--- and needs a slot arbitration to referee the two. Built that way first, it
--- read as a window on top of the terminal rather than a third tab beside it —
--- which is exactly the complaint the header was already recording.
local EDITOR_TAB, SELECT_EDITOR = "editor", "terminal.editor"
--- The kernel's name for the program this pane owns, and the same string a
--- `surface` node names to show its cells. One key, so asking again under it is
--- addressed to the pane already standing there.
local EDITOR_PROGRAM = "editor"

--- The fourth tab: one file's diff, opened from the sidebar's changes list.
---
--- A tab here rather than a pane of its own for the same reason the editor is
--- one — the sidebar is 22% of the screen and a diff is a wide thing — and
--- because the strip that gets you back to the agent is drawn on THIS pane's
--- border, so a second occupant of the centre slot would lose it.
local DIFF_TAB, SELECT_DIFF = "diff", "terminal.diff"
--- Toggling into the editor and back out, for the chord rather than the chip.
local EDITOR_OPEN = "editor.open"
--- Scrollback, declared rather than matched inside `on_key`: a key that only
--- exists there is invisible to help and cannot be rebound.
local SCROLL_UP, SCROLL_DOWN = "terminal.scroll_up", "terminal.scroll_down"
--- Rows one page key moves. v1 pages by half the pane's height; the fixed
--- count is a deliberate divergence rather than an oversight.
local SCROLL_LINES = 10
--- Bring the input focus onto this pane, from anywhere.
local FOCUS = "terminal.focus"

--- The session the list published, resolved against the current snapshot.
local function selected()
  local id = store.selected
  if not id then
    return nil
  end
  for _, session in ipairs(thurbox and thurbox.sessions or {}) do
    if session.id == id then
      return session
    end
  end
  return nil
end

--- The tab a session is showing.
---
--- Keyed per session because v1 keys it per session
--- (`App::session_terminal_views`): flipping to the shell on one session must
--- not flip it on the next one you select. Absent = the agent, so a session
--- that never switched costs no state at all.
local function tab_of(id)
  if not id then
    return AGENT_TAB
  end
  return state["tab:" .. id] or AGENT_TAB
end

local function set_tab(id, tab)
  state["tab:" .. id] = tab ~= AGENT_TAB and tab or nil
end

--- The file the editor tab is showing, per session and for the same reason the
--- tab is: opening a file in one session must not point the next one at it.
---
--- Absent means the tab has nothing to show, which is what the chip is gated on
--- — v1's rule for the review chip, that an affordance which lights up and then
--- does nothing is worse than no affordance.
local function file_of(id)
  if not id then
    return nil
  end
  return state["file:" .. id]
end

local function set_file(id, path)
  state["file:" .. id] = path
end

--- What the diff tab is showing, per session: a path relative to the session's
--- working directory, and which side of the index it was asked about.
---
--- Two keys rather than one packed string: `git diff` and `git diff --cached`
--- are different answers about the same path, and a row in the sidebar knows
--- which one the user clicked.
local function diff_of(id)
  if not id then
    return nil
  end
  return state["diff:" .. id], state["diffstaged:" .. id] == true, state["diffnew:" .. id] == true
end

local function set_diff(id, path, staged, untracked)
  state["diff:" .. id] = path
  state["diffstaged:" .. id] = staged and true or nil
  -- Which git can answer about this path at all — see `diff_lines`.
  state["diffnew:" .. id] = untracked and true or nil
  -- A new file starts at the top. Without this the previous file's scroll
  -- position is inherited, which for a short diff is a blank pane.
  state["diffat:" .. id] = nil
end

--- Single quotes for `sh -c`, which is what `run` hands the program to.
---
--- `run` takes ONE string, not an argv the multiplexer quotes for you — the
--- split the `program` command makes for exactly this reason is not available
--- here, so a path with a space, a quote or a `$` in it is this function's
--- problem. The `'\''` dance is the only escape a single-quoted POSIX string
--- has.
local function shell_quote(text)
  -- Parenthesised: `gsub` returns the count as a second value, and a bare call
  -- at the END of a concatenation would drag it in.
  return "'" .. (tostring(text):gsub("'", "'\\''")) .. "'"
end

--- The diff for one file, as styled lines, or nil while there is no answer.
---
--- The run key carries the PATH and the side, not just the session: `run`
--- dedupes on the key, so a single `diff:<id>` key would hand back the previous
--- file's diff for as long as its answer stayed fresh.
local function diff_lines(id, path, staged, untracked)
  if not run or not id or not path then
    return nil
  end
  -- An untracked file has no blob to diff against, so plain `git diff` prints
  -- nothing for it — which the pane would have to render as "no changes" about
  -- a file that is entirely new. `--no-index` against `/dev/null` compares two
  -- paths on disk instead of consulting the index, and reads the whole file as
  -- added, which is what the sidebar's `U` actually means. It exits 1 when the
  -- two differ, i.e. always here; that is why the answer below is read from
  -- `stdout` without consulting `ok`.
  local program
  if untracked then
    program = "git --no-pager diff --no-color --no-index -- /dev/null " .. shell_quote(path)
  else
    program = "git --no-pager diff --no-color "
      .. (staged and "--cached " or "")
      .. "-- "
      .. shell_quote(path)
  end
  -- The flag is in the key too: `git add` flips a path from one command to the
  -- other, and within the ttl the old key would hand back the other shape.
  local key = "diff:"
    .. id
    .. "\0"
    .. (staged and "1" or "0")
    .. (untracked and "n" or "-")
    .. "\0"
    .. path
  run(key, program, { session = id, ttl = 3 })
  local answer = (thurbox.runs or {})[key]
  if not answer or answer.state ~= "done" then
    return nil
  end
  local out = answer.stdout or ""
  local lines = {}
  for line in (out .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  -- A trailing empty line from the split, not a line of the diff.
  if #lines > 0 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

--- The colour of one diff line, by its first character.
---
--- `+++`/`---` are checked BEFORE `+`/`-`: they are file headers, not an added
--- and a removed line, and painting them green and red is the one thing that
--- makes a diff harder to read rather than easier.
local function diff_style(line)
  local head = line:sub(1, 3)
  if head == "+++" or head == "---" then
    return { fg = theme.muted }
  end
  local first = line:sub(1, 1)
  if first == "+" then
    return { fg = theme.role("diff_added") }
  elseif first == "-" then
    return { fg = theme.role("diff_removed") }
  elseif line:sub(1, 2) == "@@" then
    return { fg = theme.accent, bold = true }
  elseif line:sub(1, 4) == "diff" or line:sub(1, 5) == "index" then
    return { fg = theme.muted }
  end
  return { fg = theme.text }
end

--- One editor pane PER SESSION, not one per plugin.
---
--- A program pane belongs to the plugin, not to whatever is selected — so a
--- single `editor` pane would show session A's file while the tab strip over it
--- named session B's. The name is ours to choose and the kernel stamps the owner,
--- so keying it on the session is free and is the only version whose title is
--- true.
--- The separator is `_` because `validate_program_name` accepts letters, digits,
--- `-` and `_` and nothing else: the name becomes a tmux window name, which tmux
--- parses as part of a target string. A session id is a UUID, so `-` is already
--- spoken for and `_` is the one character that cannot appear inside the id.
local function editor_key(id)
  return EDITOR_PROGRAM .. "_" .. id
end

--- Where the editor listens, written as shell rather than as a path.
---
--- The plugin VM has no `os` and no `io`, so a private directory cannot be
--- looked up from here — but both ends of this feature run through `sh`: `run`
--- hands its string to `sh -c`, and the editor is started through one. So the
--- directory is written once and expanded twice, identically, by the shell.
---
--- `$XDG_RUNTIME_DIR` because this socket is an RPC channel into the editor,
--- which is arbitrary code as this user. Measured: `nvim --listen` creates it
--- `srwxr-xr-x`, so in a shared `/tmp` any local account could drive the editor.
--- The fallback therefore owns a `thurbox-$(id -u)` directory and takes 700 on
--- it rather than writing the socket into `/tmp` directly.
local SOCKET_DIR = 'D="${XDG_RUNTIME_DIR:-/tmp}/thurbox-$(id -u)"'

--- The socket for one session's editor, as a shell word.
---
--- A session id is a UUID, so nothing in it needs quoting — and an id that is
--- not one is refused rather than escaped, because this string is interpolated
--- into a command line the shell parses.
local function editor_socket(id)
  if type(id) ~= "string" or id == "" or id:find("[^%w%-]") then
    return nil
  end
  return '"$D/editor-' .. id .. '.sock"'
end

--- The runs that hand files to one session's editor: one key per pick, from a
--- small ring. Per pick because `run` drops an ask whose key is still in flight,
--- `refresh` or not, so a key two picks shared swallowed the second. A ring
--- because `run` keeps an answer for as long as the interface runs, so a key per
--- path or per pick would grow for that long; this is eight per session.
---
--- Eight is not a limit on picks in flight in practice: a hand-off that a later
--- pick has replaced leaves on its next probe (see `editor_handoff`).
local HANDOFF_SLOTS = 8

--- Take the key for a new pick, and remember it as the one the tab reports on.
---
--- Also returns the pick's number, which the hand-off prints: the ring reuses
--- keys, and `run` keeps a key's last answer readable until the next one lands,
--- so an answer is only about THIS pick when it says so.
local function next_handoff(id)
  local pick = (state["pick:" .. id] or 0) + 1
  state["pick:" .. id] = pick
  state["handoff:" .. id] = "editoropen:" .. id .. ":" .. ((pick - 1) % HANDOFF_SLOTS + 1)
  return state["handoff:" .. id], pick
end

--- How long a hand-off waits for the editor, in seconds, counted on the clock
--- and not in probes: a stopped editor accepts the connection and never replies,
--- so a probe nothing bounds never comes back to be counted. `timeout` bounds
--- each probe where it exists (coreutils, not stock macOS); where it does not,
--- `run`'s own 30 s timeout is the bound — per hand-off, and `run` has four
--- slots for every plugin together, so four such hand-offs fill the pool.
local HANDOFF_WAIT = 10

--- Hand `path` to the editor, once the editor can take it.
---
--- The editor is warmed when the column is entered, so a quick click lands while
--- it is still starting — and both halves of that are measured failures. Before
--- nvim listens, `--remote-silent` is not a no-op: finding no server it edits
--- the file in a nvim of its own, which with no terminal hangs until the run
--- times out, and the editor on screen stays on `/dev/null`. After it listens
--- but before startup is over, the file arrives in time for the warm
--- `setlocal bufhidden=wipe nobuflisted` to land on it instead of on
--- `/dev/null`. `v:vim_did_enter` is the moment both are behind us.
---
--- Only the LATEST pick opens. Every hand-off writes its pid to the session's
--- `.pick` file as it starts — making the directory itself, since it can start
--- before the editor's own `mkdir` — and one that finds another pid there
--- steps aside, checked on every probe so a replaced hand-off does not hold a
--- run slot until the editor is up. A `.pick` that cannot be read is an error,
--- not a quiet step aside: picks made before the socket binds are all released
--- by the same edge, and without this whichever got there first won.
---
--- An editor that answers but is still starting at the deadline gets the file
--- anyway — it is alive, so `--remote-silent` cannot fall back to a nvim of its
--- own, and on a cold start it already holds the file from `args`. Only an
--- editor that never answered is an error.
local function editor_handoff(id, path, pick)
  local socket = editor_socket(id)
  return SOCKET_DIR
    .. "; echo 'pick "
    .. pick
    .. "' >&2"
    .. '; P="$D/editor-'
    .. id
    .. '.pick"; mkdir -p "$D" && chmod 700 "$D"; printf %s "$$" >"$P.$$" && mv -f "$P.$$" "$P"; '
    .. 'latest() { m=$(cat "$P" 2>/dev/null) || { echo "the hand-off lost track of the latest pick" >&2; exit 1; }; '
    .. '[ "$m" = "$$" ] || exit 0; }; '
    .. "T=; command -v timeout >/dev/null 2>&1 && T='timeout 2'; start=$(date +%s); up=; "
    .. "while :; do latest; got=$($T nvim --server "
    .. socket
    .. ' --remote-expr v:vim_did_enter 2>/dev/null); [ "$got" = 1 ] && break; [ "$got" = 0 ] && up=1; '
    .. "if [ $(($(date +%s) - start)) -ge "
    .. HANDOFF_WAIT
    .. ' ]; then [ -n "$up" ] && break; '
    .. "echo 'the editor never answered on its socket' >&2; exit 1; fi; sleep 0.1; done; "
    .. "latest; "
    .. "exec nvim --server "
    .. socket
    .. " --remote-silent "
    .. shell_quote(path)
end

--- The tab the editor was entered FROM, so leaving it goes back there.
---
--- Recorded rather than assumed: "back" from the editor is the agent for
--- someone who opened a file while reading the agent, and the shell for someone
--- who opened it while working in one. Sending both to the agent is the version
--- that is wrong half the time, and silently.
---
--- It happens on `:q` as well as on the key. That took a kernel patch: measured
--- 2026-09-10 with a control, `command.done` never fires for a `program` command,
--- the snapshot carries no program state to poll, and tmux 3.2a has no
--- `pane-died` hook to route round the outside. `program.exited` is the channel
--- that was missing — addressed to the plugin that started the pane, so nobody
--- else acts on an editor that is not theirs.
local function previous_tab(id)
  local tab = id and state["prev:" .. id]
  if tab == SHELL_TAB and shell_enabled() then
    return SHELL_TAB
  end
  return AGENT_TAB
end

--- Remember where we are, unless we are already in the editor — entering it
--- twice must not record the editor as its own way out.
local function remember_tab(id)
  local tab = tab_of(id)
  if tab ~= EDITOR_TAB then
    state["prev:" .. id] = tab ~= AGENT_TAB and tab or nil
  end
end

--- Just the last segment: the border has a tab strip on it already.
local function basename(path)
  return path:match("[^/]+$") or path
end

--- The surface a tab addresses: the session itself, or its `#shell` sibling.
---
--- The same spelling the surface node carries and the kernel resolves, so
--- anything keyed on it is keyed on the screen the user is actually reading.
local function surface_of(id, tab)
  if not id then
    return nil
  end
  if tab == DIFF_TAB then
    -- Drawn from `run` output, not from a pty: there is no scrollback to name
    -- and no keystrokes to forward. Its scrolling is this pane's own, below.
    return nil
  end
  if tab == EDITOR_TAB then
    -- A program surface, not a session one — so it has no session scrollback to
    -- name, and every caller keyed on this (the page keys, the wheel, the
    -- snap-to-bottom) correctly finds nothing to move. nvim owns its own screen.
    return nil
  end
  return tab == SHELL_TAB and (id .. "#shell") or id
end

--- How far back a surface is scrolled, and the deepest it has ever been.
---
--- Keyed per SURFACE, which is both halves of the rule at once. Per session,
--- because this is a property of the screen you are looking at rather than of
--- the pane looking at it: shared, selecting another session carried your offset
--- onto it, and — since the kernel writes the offset into whichever parser it is
--- drawing — the next session opened scrolled back with no way to tell why. And
--- per tab within that, because the agent and its companion shell are two live
--- terminals taking turns in one rect with a scrollback each: one offset between
--- them put the shell wherever the agent had been left.
local function scroll_of(surface)
  if not surface then
    return 0, 0
  end
  return state["scroll:" .. surface] or 0, state["scrollmax:" .. surface] or 0
end

local function set_scroll(surface, scroll, scroll_max)
  if not surface then
    return
  end
  state["scroll:" .. surface] = scroll ~= 0 and scroll or nil
  state["scrollmax:" .. surface] = scroll_max ~= 0 and scroll_max or nil
end

--- Move a surface's scrollback by `lines`. `true` when it actually moved.
---
--- Scrollback is this pane's policy rather than the kernel's, so a replacement
--- pane can choose differently. Declining when nothing moved is what lets the
--- kernel put a wheel tick at the live bottom back on its keystroke fallback
--- instead of swallowing it.
local function scroll_surface(surface, lines)
  if not surface then
    return false
  end
  local scroll, scroll_max = scroll_of(surface)
  local moved = math.max(0, scroll + lines)
  if moved == scroll then
    return false
  end
  -- How far back the user has ever gone. The snapshot carries no total
  -- scrollback (v1 probes the vt100 screen for it), so this high-water mark is
  -- what the scrollbar is scaled against — see the report accompanying this
  -- port.
  set_scroll(surface, moved, math.max(scroll_max, moved))
  return true
end

--- Move the AGENT tab's scrollback, or decline.
---
--- The page keys' half of the policy: declining on the shell tab is what leaves
--- them to the pty, where whatever is running (a pager, an editor) has its own
--- idea of what a page is. A wheel tick carries no such meaning, so it scrolls
--- either tab -- see `on_scroll`.
local function scroll_by(id, lines)
  -- The diff tab scrolls TEXT, not a scrollback, so it answers the same keys
  -- with its own offset. Written here and not in `render`, which is what lets
  -- this pane stay `pure`.
  if id and tab_of(id) == DIFF_TAB then
    local path, staged, untracked = diff_of(id)
    local body = path and diff_lines(id, path, staged, untracked) or nil
    local at = (state["diffat:" .. id] or 0) - lines
    local last = math.max(0, (body and #body or 0) - 1)
    state["diffat:" .. id] = math.max(0, math.min(at, last))
    return true
  end
  if not id or tab_of(id) ~= AGENT_TAB then
    return false
  end
  scroll_surface(id, lines)
  -- Claimed even when it did not move: the key is the agent view's, and
  -- handing a PageDown at the live bottom back to the kernel would offer it to
  -- the pty this action exists to keep it away from.
  return true
end

--- Put the view back at the live bottom of the stream.
---
--- v1's rule for every key forwarded to the pty: you type at the end of what
--- you are typing into. Without it a wheel tick leaves you typing into a screen
--- you cannot see.
local function snap_to_bottom(id)
  local surface = surface_of(id, tab_of(id))
  if not surface then
    return false
  end
  local scroll, scroll_max = scroll_of(surface)
  if scroll == 0 then
    return false
  end
  -- The high-water mark stays: it is what the scrollbar is scaled against, and
  -- the bar reading "you are at the bottom of a stream you have been up" is the
  -- same thing it says when you scroll back down by hand.
  set_scroll(surface, 0, scroll_max)
  return true
end

-- --- text measurement ------------------------------------------------------
--
-- `widgets.len`/`pad` measure in terminal COLUMNS, which is what a border
-- budget is spent in; `#` counts bytes and every glyph below is multi-byte.

--- v1's `ui::fit_right_title`: clamp a right-aligned title to what the tab strip
--- on the left of the same border leaves it — the border minus its two corners,
--- minus the reserved block, minus a one-cell gap.
local function fit_right_title(title, border_width, reserved_left)
  reserved_left = reserved_left or 0
  if reserved_left == 0 then
    return title
  end
  local available = math.max(0, (border_width or 0) - 2 - reserved_left - 1)
  return widgets.truncate_hard(title, available)
end

-- --- the title -------------------------------------------------------------

--- The status the way v1's session title writes it: capitalised, spelled out,
--- never a glyph. The snapshot hands Lua the lowercase state name.
local function status_word(status)
  local word = status or "idle"
  return (word:gsub("^%l", string.upper))
end

--- v1's terminal-pane title, exactly.
---
---     " name (agent) [branch] [Status] "
---     " name (agent) [Status] "          -- no worktree, so no branch bracket
---     " name (shell) "
---
--- plus, when scrolled back, ` [N↑] ` appended AFTER trimming the base title's
--- trailing space. The branch bracket is absent rather than empty when the
--- session has no worktree, and the leading/trailing spaces keep the title off
--- the rounded corners.
--- What the pane is running, for the title's `(…)` bracket.
---
--- The row's own agent, plus the one observed in the pane when a driver started
--- something else there — `(zsh → claude)`. Two names rather than one because
--- neither is the whole truth: the row says what thurbox launched, the arrow
--- says what answered.
local function agent_word(session)
  local agent = session.agent or ""
  local detected = session.detected_agent
  if detected and detected ~= agent then
    return agent .. " → " .. detected
  end
  return agent
end

local function terminal_title(session, opts)
  opts = opts or {}
  local name = session.name or ""
  local base
  if opts.shell then
    base = " " .. name .. " (shell) "
  elseif session.branch then
    base = " "
      .. name
      .. " ("
      .. agent_word(session)
      .. ") ["
      .. session.branch
      .. "] ["
      .. status_word(session.status)
      .. "] "
  else
    base = " "
      .. name
      .. " ("
      .. agent_word(session)
      .. ") ["
      .. status_word(session.status)
      .. "] "
  end

  local scroll = opts.scroll or 0
  if scroll > 0 then
    base = (base:gsub("%s+$", "")) .. " [" .. scroll .. "↑] "
  end
  return base
end

-- --- focus -----------------------------------------------------------------
--
-- v1 has THREE levels (`ui::FocusLevel`); this pane's caller only ever produces
-- two, so `inactive` is carried for completeness rather than reached. Focus is
-- communicated by COLOUR, never by a marker glyph or a heavier border — which
-- is why nothing below prefixes the title. The mapping itself is
-- `chrome.border_style` / `chrome.title_style`, shared with the session list.

-- --- the scrollbar ---------------------------------------------------------

--- The role the scrollbar column carries.
---
--- The kernel's own spelling for "a press here takes hold of the pointer", so
--- the moves that follow reach this pane instead of painting a text selection
--- across the terminal the bar is about to scroll. This pane has one draggable,
--- so the bare role identifies it; a pane with two would tell them apart by `id`.
local DRAG = "drag"

local SCROLLBAR = { begin_ = "▲", end_ = "▼", track = "║", thumb = "█" }

--- Integer divide, rounding to nearest — ratatui's `rounding_divide`.
local function rounding_divide(numerator, denominator)
  return math.floor((numerator + math.floor(denominator / 2)) / denominator)
end

--- Where the thumb sits in a track of `track_length` rows, and how long it is.
---
--- Ratatui's `Scrollbar::part_lengths` arithmetic, so the thumb lands where v1's
--- does. Split out from the drawing because a press on the bar has to answer the
--- same question the paint does — and answering it twice, differently, is how a
--- thumb comes to jump out from under the pointer that grabbed it.
---
--- `nil` when there is no bar: no content to scroll, or no room for a track.
local function thumb_geometry(track_length, content_len, viewport, position)
  if content_len <= 0 or track_length <= 0 then
    return nil
  end

  local max_position = math.max(0, content_len - 1)
  local start_position = math.max(0, math.min(position, max_position))
  local max_viewport_position = max_position + viewport
  if max_viewport_position == 0 then
    return nil
  end

  local thumb_length = rounding_divide(viewport * track_length, max_viewport_position)
  thumb_length = math.max(1, math.min(thumb_length, track_length))

  local thumb_start = rounding_divide(start_position * track_length, max_viewport_position)
  thumb_start = math.max(0, math.min(thumb_start, track_length - thumb_length))
  return thumb_start, thumb_length
end

--- The position a thumb dropped at `thumb_start` is asking for.
---
--- The inverse of `thumb_geometry`, pinned at both ends rather than derived from
--- the same ratio: the forward map's rounding leaves the last row of travel
--- short of `max_position`, so a bar dragged all the way down would stop a line
--- or two above the live bottom and never quite arrive.
local function position_of_thumb(track_length, content_len, viewport, thumb_start)
  local max_position = math.max(0, content_len - 1)
  local _, thumb_length = thumb_geometry(track_length, content_len, viewport, 0)
  if not thumb_length then
    return 0
  end
  local travel = track_length - thumb_length
  if travel <= 0 then
    return max_position
  end
  local at = math.max(0, math.min(thumb_start, travel))
  return math.min(max_position, rounding_divide(at * max_position, travel))
end

--- One run per row of a vertical scrollbar.
---
--- Returns nil when there is nothing to draw, and the caller falls back to a
--- plain border column — v1 skips the bar entirely when no scrollback exists.
local function scrollbar_rows(height, content_len, viewport, position)
  local track_length = height - 2
  local thumb_start, thumb_length = thumb_geometry(track_length, content_len, viewport, position)
  if not thumb_start then
    return nil
  end

  local track_end = track_length - (thumb_start + thumb_length)

  -- The caps carry no style in v1 (ratatui leaves begin/end unstyled); the
  -- track and thumb do. Every row carries `DRAG`, and adjacent runs sharing an
  -- identity coalesce into ONE hitbox — which is what makes the bar a single
  -- target the length of the column rather than one target per row.
  local track_run = { text = SCROLLBAR.track, style = { fg = theme.muted }, role = DRAG }
  local thumb_run = { text = SCROLLBAR.thumb, style = { fg = theme.accent }, role = DRAG }

  local rows = { { text = SCROLLBAR.begin_, role = DRAG } }
  for _ = 1, thumb_start do
    rows[#rows + 1] = track_run
  end
  for _ = 1, thumb_length do
    rows[#rows + 1] = thumb_run
  end
  for _ = 1, track_end do
    rows[#rows + 1] = track_run
  end
  rows[#rows + 1] = { text = SCROLLBAR.end_, role = DRAG }
  return rows
end

--- The bar's content length for a scrollback `depth` deep.
---
--- `depth + 1`, because the places you can be are `0..depth` inclusive and the
--- live bottom is one of them. Passing `depth` clamps the end of the track to
--- one line above the live end, so the bar could be dragged all the way down
--- and still leave you off the bottom of the stream.
local function bar_content_len(depth)
  return depth + 1
end

--- A press or a drag on the scrollbar, mapped back to a scroll offset.
---
--- Every row of the bar carries the same role, so the paint walk coalesces them
--- into one hitbox: `hit.y` is already the row of the bar under the pointer and
--- `hit.h` its length — which is the only reason a `pure` pane can answer this
--- at all, since `render` may not stash geometry.
local function scrollbar_grab(id, hit)
  local surface = surface_of(id, tab_of(id))
  local scroll, depth = scroll_of(surface)
  local height = hit.h or 0
  local track = height - 2
  local content_len = bar_content_len(depth)
  local thumb_start, thumb_length = thumb_geometry(track, content_len, height, depth - scroll)
  if not thumb_start then
    return false
  end

  -- Row 0 and the last row are the caps, so the track starts one in. A press on
  -- a cap clamps onto the end of the track it caps.
  local row = math.max(0, math.min((hit.y or 0) - 1, track - 1))

  -- Where INSIDE the thumb the press landed, so the thumb is picked up rather
  -- than centred: grabbing its lower half must not jerk it up by half its
  -- length, and the thumb here is tall whenever the scrollback is shallow. Held
  -- for the whole gesture; a press on the bare track jumps the thumb there.
  if not hit.dragging then
    local inside = row - thumb_start
    local held = (inside > 0 and inside < thumb_length) and inside or nil
    state["grab:" .. surface] = held
  end

  local position =
    position_of_thumb(track, content_len, height, row - (state["grab:" .. surface] or 0))
  -- The bar is inverted, as in v1: the top of the track is the deepest offset
  -- and the bottom is the live end of the stream.
  set_scroll(surface, math.max(0, math.min(depth - position, depth)), depth)
  return true
end

-- --- the border strip ------------------------------------------------------
--
-- v1 packs the session-list collapse chevron and the view tabs into the LEFT of
-- this pane's top border (`App::render_central_pane` → `session_collapse_
-- toggle_label` / `central_tab_cells` / `draw_central_tabs`), leaving the
-- right-aligned session title on the same row:
--
--   ╭ ◀ F9 ─ Agent ─ Shell · F8 ───────────────── add-wsl (idle) [Idle] ╮
--
-- The one-cell gaps between chips are border cells, not spaces, which is what
-- makes the chips read as sitting ON the border rather than in a strip of their
-- own. Rendering only: clicking them is the mouse layer's business.

--- Cells the padded chevron segment (` ◀ `) occupies, so the accent chevron and
--- the muted ` F9 ` hint are styled apart — v1 `COLLAPSE_CHEVRON_CELLS`.
local COLLAPSE_CHEVRON_CELLS = 3
--- v1 `COLLAPSE_TOGGLE_MIN_WIDTH`: narrower than this and even a bare chevron
--- has nowhere to go.
local COLLAPSE_TOGGLE_MIN_WIDTH = 5
--- v1 `COLLAPSE_HINT_MIN_WIDTH`: below it the toggle is chevron-only, to save
--- border space for the tabs.
local COLLAPSE_HINT_MIN_WIDTH = 40

--- v1 renders a chord compactly: `^Q`, `⇧J`, `F7`. Mirrors `KeyChord::compact`
--- — which also drives the kernel's action band (`kernel::bands`), so the hint
--- on this border and the pill in the band spell the same chord the same way.
local function compact_chord(chord)
  local modifiers, key = "", chord
  while true do
    local prefix, rest = string.match(key, "^(%a+)%+(.*)$")
    if not prefix then
      break
    end
    local symbol = ({ ctrl = "^", shift = "⇧", alt = "⌥", cmd = "⌘" })[prefix]
    if not symbol then
      break
    end
    modifiers = modifiers .. symbol
    key = rest
  end
  if widgets.chars(key) == 1 then
    key = string.upper(key)
  elseif widgets.chars(key) > 1 then
    key = string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)
  end
  return modifiers .. key
end

--- v1 `compact_shortcut`: prefer a bare F-key over a chord, because a focused
--- terminal passes bare `Ctrl+<letter>` through to the agent — so the F-key is
--- the hint that works from where the user is standing.
---
--- Memoized on the published registry's identity: `thurbox.registry` is a
--- gated group, so the same table object means the same bindings — and this
--- runs from the border strip on every render, scanning every plugin's
--- bindings each time.
local shortcut_cache = { src = nil, by_action = {} }

local function shortcut_for(action)
  local registry = thurbox and thurbox.registry
  local keys = (registry and registry.keys) or {}
  if not rawequal(registry, shortcut_cache.src) then
    shortcut_cache.src = registry
    shortcut_cache.by_action = {}
  end
  local cached = shortcut_cache.by_action[action]
  if cached ~= nil then
    return cached or nil
  end
  local first
  local found
  for _, binding in ipairs(keys) do
    if binding.action == action and binding.key then
      if string.match(binding.key, "^f%d+$") then
        found = compact_chord(binding.key)
        break
      end
      first = first or binding.key
    end
  end
  found = found or (first and compact_chord(first))
  -- `false` marks "looked, nothing bound", so a miss is remembered too.
  shortcut_cache.by_action[action] = found or false
  return found
end

--- v1 `button_style`: the active view is the accent-filled "primary" chip, the
--- rest the neutral selection pair every palette guarantees is legible.
local function chip_style(primary)
  if primary then
    return { fg = theme.role("inverted_fg"), bg = theme.role("accent"), bold = true }
  end
  return { fg = theme.role("selection_fg"), bg = theme.role("selection_bg"), bold = true }
end

--- The hovered chip.
---
--- `accent_bright` rather than `accent`, so hovering the chip that is ALREADY
--- active still reads as a response — filling it with the colour it already has
--- would look like nothing happened.
local function chip_hover_style()
  return { fg = theme.role("inverted_fg"), bg = theme.role("accent_bright"), bold = true }
end

--- v1 `session_collapse_toggle_label`: ` ◀ F9 ` while the list is shown
--- (collapse it leftward), ` ▶ F9 ` while hidden (expand it back). The chevron
--- points the way the list will move; the hint is dropped on a narrow pane.
local function collapse_label(width)
  if width < COLLAPSE_TOGGLE_MIN_WIDTH then
    return nil
  end
  local chevron = panels.shown("sessions") and "◀" or "▶"
  local hint = width >= COLLAPSE_HINT_MIN_WIDTH and shortcut_for("sessions.toggle_panel") or nil
  if hint then
    return " " .. chevron .. " " .. hint .. " "
  end
  return " " .. chevron .. " "
end

--- v1 `central_tab_cells`' candidate list. Agent has no dedicated key — the
--- Shell toggle returns to it — so it shows no hint.
---
--- `role` is what a CLICK on the chip does: both tabs name their own select
--- action, so a chip and the keyboard agree by construction.
---
--- v1 lists a third chip here, `Review · F7`. It is absent because the review
--- plugin is: a chip whose `focus:review` role names a plugin that does not
--- exist would light up and then do nothing, which is worse than not offering
--- it. Re-adding the pane means re-adding its chip.
local function tab_specs(active)
  local specs = {
    { name = "Agent", active = active == AGENT_TAB, role = "action:" .. SELECT_AGENT },
  }
  -- `[features] shell_pane` off means there is no second view, so there is no
  -- chip for one either: an affordance for a disabled feature is the clutter the
  -- switch was flipped to avoid.
  if shell_enabled() then
    specs[#specs + 1] = {
      name = "Shell",
      active = active == SHELL_TAB,
      shortcut = shortcut_for("shell.open"),
      role = "action:" .. SELECT_SHELL,
    }
  end
  -- Offered only once there is a file to show. Before that the tree is how you
  -- open one (F3), and a chip leading to an empty pane would be the lit-up
  -- affordance that does nothing.
  if file_of(store.selected) then
    specs[#specs + 1] = {
      name = "Editor",
      active = active == EDITOR_TAB,
      shortcut = shortcut_for(EDITOR_OPEN),
      role = "action:" .. SELECT_EDITOR,
    }
  end
  -- Same rule as the editor's: offered once there is a diff to show, and never
  -- as a lit chip leading to an empty pane. The changes list in the file column
  -- is where one comes from.
  if diff_of(store.selected) then
    specs[#specs + 1] = {
      name = "Diff",
      active = active == DIFF_TAB,
      role = "action:" .. SELECT_DIFF,
    }
  end
  return specs
end

--- `Name` alone, or `Name · <shortcut>` while the suffix is still shown.
local function tab_label(spec)
  if spec.shortcut then
    return spec.name .. " · " .. spec.shortcut
  end
  return spec.name
end

--- v1 `central_tabs_block_width`: each chip is ` label `, chips joined by one
--- cell — the same packing the kernel's action band uses for its pills, so the
--- trim agrees with what paints.
local function tabs_block_width(specs)
  if #specs == 0 then
    return 0
  end
  local total = 0
  for _, spec in ipairs(specs) do
    total = total + widgets.len(tab_label(spec)) + 2
  end
  return total + #specs - 1
end

--- v1 `trim_central_tabs`, escalating until the block fits:
---
---   1. strip the `· shortcut` suffix from every label (~4 cols/chip);
---   2. drop the lowest-priority tab — Shell — but never Agent (the fallback
---      view) nor the active one, which must stay visible.
local function trim_tabs(specs, usable)
  while #specs > 1 and tabs_block_width(specs) > usable do
    local stripped = false
    for _, spec in ipairs(specs) do
      if spec.shortcut then
        spec.shortcut = nil
        stripped = true
      end
    end
    if not stripped then
      local victim
      for _, name in ipairs({ "Shell" }) do
        for index, spec in ipairs(specs) do
          if not victim and spec.name == name and not spec.active then
            victim = index
          end
        end
      end
      if not victim then
        return specs
      end
      table.remove(specs, victim)
    end
  end
  return specs
end

--- The runs painted over the top border's left half, plus the column the
--- rightmost of them ends at — v1's `reserved_left`, which is what the
--- right-aligned title is then fitted against.
---
--- Columns are pane-local and 0-based: the corner sits at 0 and the strip starts
--- at 1, exactly where v1 puts the chevron rect (`terminal.x + 1`).
local function border_strip(width, border_style, active)
  local runs, cursor = {}, 1
  --- `role`, when given, is the kernel's click verb for this run: a run carries
  --- its own identity and the paint walk registers a hitbox over the columns it
  --- laid the run out at. The `─` filler between chips is what puts each one at
  --- the column it belongs at, since the overlay paints its runs consecutively.
  local function put(at, text, style, role)
    if at > cursor then
      runs[#runs + 1] = { text = string.rep("─", at - cursor), style = border_style }
    end
    runs[#runs + 1] = { text = text, style = style, role = role }
    cursor = at + widgets.len(text)
  end

  local label = collapse_label(width)
  if label then
    -- The chevron and its ` F9 ` hint are ONE affordance in two colours: the
    -- chevron reads accent, the hint muted.
    --
    -- They are two runs — a run has one style — but both carry the SAME role,
    -- and adjacent runs sharing an identity coalesce into one hitbox, so the
    -- kernel hit-tests them as one target. Without that the hint was inert: not
    -- clickable, and not lit when the pointer was over it, which made the button
    -- feel like it had a three-cell hitbox in the middle of a six-cell label.
    local toggle = "action:sessions.toggle_panel"
    -- v1: "a button by action but a bare border glyph by look, so it takes the
    -- subtle band too" — a filled pill here would invent a chip on the border
    -- where v1 draws none. Both runs take the band together, or half the button
    -- would light.
    local lit = hover.role(toggle)
    local band = lit and theme.role("selection_bg") or nil
    put(
      1,
      widgets.keep_left(label, COLLAPSE_CHEVRON_CELLS),
      { fg = theme.accent, bg = band },
      toggle
    )
    local hint = widgets.keep_right(label, widgets.len(label) - COLLAPSE_CHEVRON_CELLS)
    if hint ~= "" then
      put(cursor, hint, { fg = theme.muted, bg = band }, toggle)
    end
  end

  -- One blank border cell after the chevron, matching the gap the strip keeps
  -- between its own chips — without it the two would read as one chip.
  local start = label and (cursor + 1) or 1
  -- The run of border cells the chips may use: up to one shy of the right
  -- corner, which is never painted over.
  local specs = trim_tabs(tab_specs(active), math.max(0, (width - 1) - start))
  local limit = width - 1
  local x = start
  for index, spec in ipairs(specs) do
    local gap = (index > 1) and 1 or 0
    local chip = widgets.len(tab_label(spec)) + 2
    if x + gap + chip > limit then
      break
    end
    x = x + gap
    put(
      x,
      " " .. tab_label(spec) .. " ",
      hover.style(spec.role, chip_hover_style(), chip_style(spec.active)),
      spec.role
    )
    x = x + chip
  end

  return runs, cursor
end

--- This pane's border: a right-aligned styled title, the tab strip painted over
--- the top border's left half, and the scrollbar down the right border column.
---
--- All three are border cells, which is the point — the surface underneath
--- keeps the full inner rect, exactly as v1 insets the terminal vertically only.
---
--- `title_style` overrides the focus colour, for a title that is a warning.
local function border_frame(title, level, border, strip, bar, title_style)
  return {
    title = { { text = title, style = title_style or chrome.title_style(level) } },
    title_align = "right",
    border_style = border,
    overlay = { top_left = strip, right_column = bar },
  }
end

-- --- the empty pane --------------------------------------------------------

local HINT_W, HINT_H = 33, 5

--- v1's hint box: a SQUARE box (no title) holding left-aligned lines, the key
--- column padded to 8 so the keys line up.
---
--- v1 opens with `Ctrl+N  New session`. It is absent because the new-session
--- plugin is: advertising a chord that resolves to nothing is worse than
--- advertising nothing, and `tests/keymap.rs` asserts that chord stays
--- unbound rather than being reused. Re-adding the wizard means re-adding its
--- line here.
local function hint_box_lines()
  local border = { fg = theme.border }
  local inner = HINT_W - 2

  local function row(runs)
    local width = 0
    for _, run in ipairs(runs) do
      width = width + widgets.len(run.text)
    end
    local line = { { text = chrome.SQUARE.v, style = border } }
    for _, run in ipairs(runs) do
      line[#line + 1] = run
    end
    line[#line + 1] = { text = string.rep(" ", math.max(0, inner - width)) }
    line[#line + 1] = { text = chrome.SQUARE.v, style = border }
    return line
  end

  local rule = string.rep(chrome.SQUARE.h, inner)
  return {
    { { text = chrome.SQUARE.tl .. rule .. chrome.SQUARE.tr, style = border } },
    row({ { text = "No active sessions", style = { fg = theme.secondary } } }),
    row({}),
    row({
      { text = "  F1    ", style = { fg = theme.hint } },
      { text = "  Help", style = { fg = theme.muted } },
    }),
    { { text = chrome.SQUARE.bl .. rule .. chrome.SQUARE.br, style = border } },
  }
end

--- The hint box centred in the pane's inner rect, or nothing at all when the
--- pane is too small — v1 draws the bare frame rather than a squeezed box.
local function empty_body(inner_w, inner_h)
  if inner_w < HINT_W or inner_h < HINT_H then
    return { type = "text", fill = 1, text = "" }
  end
  return {
    type = "box",
    axis = "vertical",
    fill = 1,
    children = {
      { type = "text", len = math.floor((inner_h - HINT_H) / 2), text = "" },
      {
        type = "box",
        axis = "horizontal",
        len = HINT_H,
        children = {
          { type = "text", len = math.floor((inner_w - HINT_W) / 2), text = "" },
          { type = "text", len = HINT_W, text = hint_box_lines() },
          { type = "text", fill = 1, text = "" },
        },
      },
      { type = "text", fill = 1, text = "" },
    },
  }
end

--- A centred stack of lines, for the states that have something to say.
local function centered(lines)
  local children = { { type = "text", fill = 1, text = "" } }
  for _, line in ipairs(lines) do
    children[#children + 1] = { type = "text", len = 1, align = "center", text = { line } }
  end
  children[#children + 1] = { type = "text", fill = 1, text = "" }
  return { type = "box", axis = "vertical", fill = 1, children = children }
end

--- The diff tab's body: `git diff` for one file, coloured and scrolled.
---
--- Its OWN scroll offset, not the surface scrollback every other tab uses,
--- because there is no surface here — the lines are a `run`'s stdout. Sliced in
--- `render` and never written from it: the offset moves in `on_action` and
--- `on_scroll`, which is what keeps this pane `pure`.
local function diff_body(session, width, height, level, border, strip, reserved_left)
  local path, staged, untracked = diff_of(session.id)

  local function say(lines)
    local body = centered(lines)
    body.frame = border_frame(
      fit_right_title(" " .. (session.name or "") .. " (diff) ", width, reserved_left),
      level,
      border,
      strip
    )
    return body
  end

  if not (thurbox.granted or {}).run then
    return say({
      { { text = "not trusted to read git", style = { fg = theme.bad, bold = true } } },
      { { text = "F6 → ] → t grants it to this file", style = { fg = theme.muted } } },
    })
  end
  if not path then
    return say({ { { text = "no diff open", style = { fg = theme.muted } } } })
  end

  local lines = diff_lines(session.id, path, staged, untracked)
  if not lines then
    return say({ { { text = "reading the diff…", style = { fg = theme.muted } } } })
  end
  if #lines == 0 then
    return say({
      { { text = basename(path), style = { fg = theme.text, bold = true } } },
      {
        {
          text = (untracked and "a new, empty file")
            or (staged and "nothing staged for this file")
            or "no unstaged changes",
          style = { fg = theme.muted },
        },
      },
    })
  end

  local rows = math.max(1, height - 2)
  local at = math.max(0, math.min(state["diffat:" .. session.id] or 0, math.max(0, #lines - rows)))
  local children = {}
  for index = at + 1, math.min(#lines, at + rows) do
    local line = lines[index]
    children[#children + 1] = {
      type = "text",
      len = 1,
      text = { { text = widgets.truncate(line, math.max(1, width - 2)), style = diff_style(line) } },
    }
  end
  children[#children + 1] = { type = "text", fill = 1, text = "" }

  local title = " " .. basename(path) .. (staged and " (staged)" or "") .. " (diff) "
  return {
    type = "box",
    axis = "vertical",
    fill = 1,
    children = children,
    frame = border_frame(fit_right_title(title, width, reserved_left), level, border, strip),
  }
end

--- Why the latest hand-off did not reach the editor, or nil when it did or is
--- still going.
---
--- `failed` is a run the kernel could not start at all, which carries `error`
--- and no stderr. A `done` answer counts only when it names the latest pick —
--- see `next_handoff` — so a reused key's old failure is not painted over a
--- file that opened.
local function handoff_failure(id)
  local answer = (thurbox.runs or {})[state["handoff:" .. id] or ""]
  if not answer then
    return nil
  end
  if answer.state == "failed" then
    return answer.error or "the hand-off could not start"
  end
  if answer.state ~= "done" or answer.ok then
    return nil
  end
  local err = answer.stderr or ""
  if tonumber(err:match("^pick (%d+)")) ~= state["pick:" .. id] then
    return nil
  end
  return answer.timed_out and "the hand-off timed out"
    or err:match("\n([^\n]+)")
    or "the hand-off failed"
end

--- The editor tab's body: the program's cells under this pane's own border.
---
--- The frame is the SAME one the other two tabs get, strip and all, which is
--- the whole point of the tab living here — the chips stay on screen while you
--- are in the editor, so getting back to the agent is a click and not a
--- rediscovery.
local function editor_body(session, width, level, border, strip, reserved_left)
  local path = file_of(session.id)

  local function say(lines)
    local body = centered(lines)
    body.frame = border_frame(
      fit_right_title(" " .. (session.name or "") .. " (editor) ", width, reserved_left),
      level,
      border,
      strip
    )
    return body
  end

  if not (thurbox.granted or {}).program then
    -- Honest rather than blank: the pane cannot grant itself the capability and
    -- must not pretend it did.
    return say({
      { { text = "not trusted to run a program", style = { fg = theme.bad, bold = true } } },
      { { text = "F6 → ] → t grants it to this file", style = { fg = theme.muted } } },
    })
  end
  if not path then
    return say({
      { { text = "no file open", style = { fg = theme.muted } } },
    })
  end
  -- A hand-off that never reached the editor says so on the border, OVER the
  -- surface and not instead of it: `program` may have opened this same path
  -- from `args`, and a page saying the file could not be opened would then
  -- stand where the file is.
  local title = " " .. basename(path) .. " (editor) "
  local warn = nil
  local why = handoff_failure(session.id)
  if why then
    -- The warning LEADS: the title is cut from the right to fit beside the tab
    -- strip, so a reason put after the name was the first thing to go.
    title = " not opened: " .. basename(path) .. " · " .. why .. " "
    -- It replaces the focus badge, so it keeps the badge's two looks.
    warn = level == "focused" and { fg = theme.role("inverted_fg"), bg = theme.bad, bold = true }
      or { fg = theme.bad, bold = true }
  end

  return {
    type = "surface",
    program = editor_key(session.id),
    -- A share of the remaining space, not a flag: `fill` is a NUMBER, and a
    -- boolean here is the kind of key the kernel drops without a word.
    fill = 1,
    frame = border_frame(
      fit_right_title(title, width, reserved_left),
      level,
      border,
      strip,
      nil,
      warn
    ),
  }
end

-- --- selecting a tab -------------------------------------------------------

--- Show a tab, bringing the pane forward with it.
---
--- v1 `select_central_tab` focuses the centre for both terminal tabs, so the
--- chord works from wherever you were standing. The shell is opened on first
--- use (v1 `show_shell_view`); `ensure_shell_pane` behind the command is
--- idempotent, so asking again on every switch costs nothing.
---
--- `keep` leaves the focus where it was, which is what a CLICK in the file tree
--- asks for: the pane's keys are plugin-scoped, so a click that opened a file
--- and took the focus with it left the tree unable to answer its own arrow keys
--- until you clicked back into it. A key press is the other case and keeps the
--- old behaviour — your hand is already on the keyboard and the next thing you
--- do is type into the file.
local function show_tab(id, tab, keep)
  set_tab(id, tab)
  if tab == SHELL_TAB then
    command("shell", { session = id })
  end
  if not keep then
    command("focus", { text = NAME })
  end
end

--- Show `path` in this session's editor pane, starting one only if there is none.
---
--- ONE command, and the kernel decides which half of it applies: `keys` go to a
--- pane that is running, `repo`/`args` start one that is not. That is not a
--- convenience — the choice cannot be made here. Liveness is not in the snapshot,
--- and keeping it in `state` is wrong across an interface reload, which re-runs
--- this file but keeps the panes.
---
--- It replaces a close-then-open that was in this function for a day. The close
--- was reasoned from a premise that turned out to be false — that a keyed name
--- stays taken after the program in it exits — and `start_program` had been
--- replacing an exited slot all along. What the close actually bought was a fresh
--- nvim per file, which is the lag the tree made obvious.
---
--- A session's working directory, by id.
---
--- Not `selected()`: the editor is started for the session the event named, and
--- a snapshot that has moved on is the one case where those two differ.
local function session_cwd(id)
  for _, session in ipairs(thurbox and thurbox.sessions or {}) do
    if session.id == id then
      return session.cwd
    end
  end
  return nil
end

--- Start the editor for one session, with a file or with none.
---
--- Idempotent on the kernel's side — "asking for a pane that exists must be a
--- map lookup and not a second copy" — so every caller can ask without knowing
--- whether it is already running, and the first ask is the one that decides
--- whether nvim starts on a file or on an empty buffer.
--- What a warm editor opens while there is no file to open.
---
--- NOT nothing and NOT the session's directory, both measured against this
--- machine's config: with no argument at all, `argc() == 0` is what a config
--- tests on `VimEnter`, and this one opened a file tree in a split; with the
--- directory, NERDTree takes the directory buffer over (it hijacks netrw by
--- default) and then swallows the `:edit` that the first real file arrives as —
--- 20 seconds later the file was still not on screen.
---
--- `/dev/null` is a file, so neither happens, and it reads as empty. The flags
--- make it disappear the moment it is replaced: `bufhidden=wipe` drops the
--- buffer when the window stops showing it, so what is left after the first
--- file is one window and one listed buffer, measured.
---
--- They are set on the `/dev/null` buffer BY NUMBER, not with `setlocal`: `-c`
--- runs when startup ends, and a file handed over while a slow config was
--- still loading is the current buffer by then — `setlocal` marked THAT file
--- unlisted. A `/dev/null` already out of every window is deleted outright,
--- since `bufhidden` only acts when a buffer is next hidden.
local WARM_FILE = "/dev/null"
local WARM_FLAGS = " -c \"lua local b = vim.fn.bufnr('/dev/null') "
  .. "if b > 0 then vim.bo[b].buflisted = false vim.bo[b].bufhidden = 'wipe' "
  .. 'if vim.fn.bufwinnr(b) < 0 then vim.api.nvim_buf_delete(b, { force = true }) end end"'

local function start_editor(id, socket, open, cwd, warm)
  command("program", {
    text = editor_key(id),
    -- Started through `sh` so the socket directory is the shell's to expand and
    -- to create; `exec` hands the pane straight to nvim, so what exits — and
    -- what `program.exited` reports — is still the editor. The `cd` is here for
    -- the same reason: `thurbox.cmd.Program` carries no directory, so without it
    -- the editor stands wherever thurbox does.
    repo = "sh",
    args = {
      "-c",
      SOCKET_DIR
        .. '; mkdir -p "$D" && chmod 700 "$D"; '
        .. (cwd and ("cd " .. shell_quote(cwd) .. " 2>/dev/null; ") or "")
        .. "exec nvim --listen "
        .. socket
        .. (warm and WARM_FLAGS or "")
        .. ' "$1"',
      -- `$0` for the shell, then what to open as `$1` — a file when one was
      -- picked, the session's directory when this is a warm start. ALWAYS one
      -- argument: `argc()` is what a config tests to decide what an editor
      -- opened with nothing should show, and here that meant a file tree in a
      -- split.
      "thurbox-editor",
      open,
    },
  })
end

--- Start the editor before a file is picked, on the column's word that one is
--- about to be.
---
--- Silent about capabilities, unlike `ensure_editor`: warming is something the
--- user did not ask for by name, and a pane that is not trusted to run programs
--- should say so when a file is actually opened, not when the tree is entered.
local function warm_editor(id)
  if not (thurbox.granted or {}).program then
    return
  end
  -- No directory, no warm start: the editor would stand somewhere this pane
  -- cannot name, and the first file it opened would be the moment that showed.
  local cwd = session_cwd(id)
  local socket = cwd and cwd ~= "" and editor_socket(id)
  if socket then
    start_editor(id, socket, WARM_FILE, cwd, true)
  end
end

--- Nothing is TYPED at the editor, and that is the whole point of the socket.
---
--- The first version sent `CTRL-\ CTRL-N` and then `:confirm e <path>` as keys.
--- Keys reach nvim as keys, which means they go through the user's mappings, and
--- a mode reset is exactly the sequence a config is likely to have taken apart.
--- Measured 2026-09-14 against this machine's own config, outside thurbox: a
--- single `<C-Bslash>` is mapped by vim-tmux-navigator, so it fires alone; the
--- orphaned `<C-N>` then hits `map <C-n> :NERDTreeToggle<CR>` and NERDTree opens
--- a vertical split AND takes focus — `getwininfo()` after the two bytes alone
--- reads `[[1,'NERD_tree_tab_1',31],[2,'…/a.rs',88]]`. The `:confirm e` that
--- followed loaded the file into NERDTree's window, which is the "a second file
--- opens in a split" this replaced. With `nvim --clean` the same bytes are a
--- no-op, so the pane was not wrong about nvim — it was wrong to type at it.
---
--- There is no unmappable mode reset to fall back to, so the editor is started
--- with `--listen` and every later file is handed over with
--- `--server … --remote-silent`, which is RPC: no mode, no mappings, and no
--- `fnameescape` of our own to get wrong (the earlier one had already grown a
--- backtick and a bare-CR hole).
---
--- Both commands are sent every time, and neither needs to know whether the
--- editor is running: `start_program` is idempotent by contract ("asking for a
--- pane that exists must be a map lookup and not a second copy"), so the
--- `program` command starts nvim on the file the first time and does nothing
--- after; the `run` waits for nvim to finish starting and then opens the file
--- over RPC — when the `program` command started nvim on that same path, the
--- open is a no-op. See `editor_handoff` for why it waits.
---
--- `--remote-silent` and not `:confirm`: stock nvim ships `hidden` on, where a
--- modified buffer is hidden rather than refused and the question comes back at
--- `:q` as `E162`. With `hidden` off nvim refuses and says so in its own message
--- line, which is where a user is looking.
local function ensure_editor(id, path, keep)
  if type(path) ~= "string" or path == "" then
    return
  end
  set_file(id, path)
  remember_tab(id)
  -- Both, because opening the FIRST file starts a program and every one after
  -- it is an RPC call `run` makes. A grant covers the file rather than one
  -- capability of it, so these are refused and granted together.
  if not (thurbox.granted or {}).program or not run then
    command("message", {
      text = "the central pane needs the program and run capabilities — F6 → ] → t",
      level = "error",
    })
    -- Still switched to the tab: it draws the untrusted state, which is where
    -- the instruction above is repeated for anyone who missed the message band.
    show_tab(id, EDITOR_TAB, keep)
    return
  end
  local socket = editor_socket(id)
  if not socket then
    command(
      "message",
      { text = "this session's id is not one this pane can open an editor for", level = "error" }
    )
    show_tab(id, EDITOR_TAB, keep)
    return
  end
  start_editor(id, socket, path, session_cwd(id))
  -- `refresh` is what makes a second click on the same file open it again after
  -- the user wandered off in nvim.
  local key, pick = next_handoff(id)
  run(key, editor_handoff(id, path, pick), { session = id, refresh = true })
  show_tab(id, EDITOR_TAB, keep)
end

--- nvim quit: put the session back where it was standing before the editor.
---
--- The pane keeps its file, so the chip stays lit and the chord opens it again —
--- a fresh nvim, this time, which is correct: there is nothing left to type at.
local function editor_ended(name)
  local id = type(name) == "string" and name:match("^" .. EDITOR_PROGRAM .. "_(.+)$")
  if not id then
    return
  end
  if tab_of(id) == EDITOR_TAB then
    show_tab(id, previous_tab(id))
  end
end

return {
  name = NAME,
  slot = "center",
  slot_mode = "switch", -- review is still an occupant of its own
  -- Pure: the tree is a surface node naming a session, not the terminal's
  -- contents. What moves under a printing agent is the vt100 grid the surface
  -- is painted from, which is not in the tree at all — so the tree can be
  -- reused every frame and the pane still repaints.
  pure = true,
  -- Keys this plugin does not handle go straight to the pty of whichever view
  -- is showing. That is what makes this an ordinary plugin rather than a kernel
  -- special case: replace the file and the terminal behaviour goes with it.
  input = "session",
  order = 20,
  focusable = true,

  -- No `pills` here on purpose. This pane's shell view is already offered by the
  -- tab strip on its own border, and v1's footer never carried it either — a
  -- second affordance for one action is clutter, not discoverability. A pane that
  -- does want an entry declares `pills = { { action, label, priority } }` beside
  -- these keys and the action band grows a row for it.
  keys = {
    {
      key = "ctrl+t",
      action = "shell.open",
      desc = "open a shell here",
      scope = "global",
      group = "UI",
    },
    -- F8 alternate: Ctrl+T reaches the agent when a terminal has focus.
    {
      key = "f8",
      action = "shell.open",
      desc = "open a shell here",
      scope = "global",
      group = "UI",
    },
    -- No F7 here any more. It was the key v1's review tab had on this strip, and
    -- a review pane installed beside this one claims it too — with both
    -- declared, one silently shadows the other and the action band advertises a
    -- chord that does nothing. The editor tab is reached the way it is actually
    -- opened: picking a file in the files pane, the tab chip on this pane's own
    -- border, or `select the editor tab` in the palette.
    -- Pane-scoped: the page keys belong to whoever is focused, and on the shell
    -- tab the action declines them so the pty keeps them (a pager has its own
    -- idea of what a page is).
    {
      key = "pageup",
      action = SCROLL_UP,
      desc = "scroll the agent's output back",
      scope = "plugin",
      group = "Terminal",
    },
    {
      key = "pagedown",
      action = SCROLL_DOWN,
      desc = "scroll the agent's output forward",
      scope = "plugin",
      group = "Terminal",
    },
  },

  render = function(ctx)
    local width, height = ctx.width or 0, ctx.height or 0
    local level = ctx.focused and "focused" or "active"
    local border = chrome.border_style(level)
    local session = selected()

    -- No session: v1 switches to a different frame entirely — SQUARE borders,
    -- a muted left-aligned " No Session " title, and the hint box.
    if not session then
      local body = empty_body(math.max(0, width - 2), math.max(0, height - 2))
      body.frame = {
        title = { { text = " No Session " } },
        border_type = "square",
        border_style = { fg = theme.muted },
      }
      return body
    end

    -- v1 draws neither the chevron nor the tabs on the empty welcome screen, so
    -- the strip is built only once a session exists — after the branch above.
    -- It carries the active tab, so it is the SAME strip on every tab; that is
    -- the whole reason the views share one plugin.
    local tab = tab_of(session.id)
    local strip, reserved_left = border_strip(width, border, tab)
    -- Before the session surface below, because this tab shows a program rather
    -- than a session and shares none of the scrollback arithmetic.
    if tab == EDITOR_TAB then
      return editor_body(session, width, level, border, strip, reserved_left)
    end
    if tab == DIFF_TAB then
      return diff_body(session, width, height, level, border, strip, reserved_left)
    end
    -- Both views are live terminals with a scrollback each, so the offset is
    -- the one this SURFACE is holding — which is also the one the kernel will
    -- set on the parser it draws.
    local surface = surface_of(session.id, tab)
    local scroll, depth = scroll_of(surface)
    local title = fit_right_title(
      terminal_title(session, { shell = tab == SHELL_TAB, scroll = scroll }),
      width,
      reserved_left
    )

    -- A dead pane explains itself. "not attached" with no reason is the least
    -- useful thing a terminal can say. v1 has no such state, so this is a
    -- deliberate v2 addition — styled `danger`, the role for a thing that is
    -- broken, rather than the working-yellow it used to borrow.
    if session.attach_error then
      local body = centered({
        { { text = "no live terminal", style = { fg = theme.bad, bold = true } } },
        { { text = session.attach_error, style = { fg = theme.muted } } },
      })
      body.frame = border_frame(title, level, border, strip)
      return body
    end

    -- The bar overlays the right border column, so the terminal grid keeps the
    -- full inner width — v1 draws it into the pane rect inset vertically only.
    -- Its extent is the inner rows exactly, hence `height - 2`.
    local rows = nil
    if depth > 0 then
      rows = scrollbar_rows(
        math.max(0, height - 2),
        bar_content_len(depth),
        math.max(0, height - 2),
        -- Inverted, as in v1: offset 0 (live, at the bottom) puts the thumb at
        -- the end of the track; the deepest offset puts it at the start.
        depth - scroll
      )
    end

    -- The shell is a second surface over the same primitive, addressed as
    -- `<id>#shell` — no new node kind, and the kernel resolves the suffix.
    return {
      type = "surface",
      session = surface,
      scroll = scroll,
      fill = 1,
      frame = border_frame(title, level, border, strip, rows),
    }
  end,

  -- The palette's rows (Ctrl+P). None of these spends a chord: the tabs are
  -- already click targets on the border, and focusing the pane is what the
  -- session list's Enter does — but neither was reachable by name until now.
  commands = {
    { action = FOCUS, desc = "focus the agent terminal" },
    { action = SELECT_AGENT, desc = "show the agent tab" },
    { action = SELECT_SHELL, desc = "show the shell tab" },
    { action = SELECT_EDITOR, desc = "show the editor tab" },
    { action = SELECT_DIFF, desc = "show the diff tab" },
  },

  -- Running a program is the one thing this pane does that the user has to
  -- agree to. `command` is present whether or not you may, so the grant is
  -- checked before asking — see `ensure_editor`.
  -- `program` runs the editor; `run` reads `git diff` for the diff tab. Two
  -- separate grants because they are two separate decisions — one holds a
  -- process open on your keystrokes, the other is a capped, timed-out read.
  capabilities = { "program", "run" },

  -- The file tree emits this; every other scalar on an `emit` table travels as
  -- payload, which is how a path crosses from that column to this pane without
  -- a `store` key both have to remember to clear.
  -- The file tree emits this; every other scalar on an `emit` table travels as
  -- payload, which is how a path crosses from that column to this pane without
  -- a `store` key both have to remember to clear.
  --
  -- `command.done`/`command.failed` are deliberately NOT subscribed. They were,
  -- as an experiment: the question was whether a `program` command reports done
  -- when the request is accepted or when the process it started exits, since it
  -- was the last channel that could have noticed `:q`. Measured 2026-09-10 with a
  -- control — a message on `user.openfile`, which did appear — and neither
  -- command event ever arrived. They say nothing about a program's lifetime.
  -- `program.exited` does, and is delivered only to the plugin whose pane it is.
  events = { "user.openfile", "user.opendiff", "user.editorwarm", "program.exited" },

  on_event = function(name, payload)
    if name == "program.exited" then
      editor_ended(payload and payload.name)
      return
    end
    if name == "user.opendiff" then
      local path = payload and payload.path
      local id = payload and payload.session or store.selected
      if type(path) ~= "string" or path == "" or not id then
        return
      end
      set_diff(id, path, payload and payload.staged, payload and payload.untracked)
      remember_tab(id)
      show_tab(id, DIFF_TAB, payload and payload.keep == true)
      return
    end
    if name == "user.editorwarm" then
      local id = payload and payload.session or store.selected
      if id then
        warm_editor(id)
      end
      return
    end
    if name ~= "user.openfile" then
      return
    end
    local path = payload and payload.path
    local id = payload and payload.session or store.selected
    if type(path) ~= "string" or path == "" or not id then
      return
    end
    -- The tree tells us what git says about this file, so the diff tab is aimed
    -- at it in the BACKGROUND: no tab switch, just a chip that lights up and an
    -- F7 that now has somewhere to go. Cleared when the file is unchanged, which
    -- is the half that matters — a stale diff of the file you opened two files
    -- ago is worse than no diff at all.
    local diff = payload and payload.diff
    if type(diff) == "string" and diff ~= "" then
      set_diff(id, diff, payload.staged, payload.untracked)
    else
      set_diff(id, nil)
    end
    -- `keep` says the pointer asked, not a key. Only the sender knows which,
    -- and the difference is the whole of this: a click must not carry the focus
    -- out of the pane it was aimed at.
    ensure_editor(id, path, payload and payload.keep == true)
  end,

  -- A wheel tick, which is NOT the page keys above.
  --
  -- This pane hands every unclaimed key to the agent, so it is the one pane
  -- that cannot declare `up`/`down` -- and the kernel's keystroke fallback for
  -- the wheel is exactly those. Without this hook the wheel did nothing at all
  -- over a terminal unless the program inside had turned on mouse tracking, in
  -- which case the kernel forwards the tick to the pty and the pane never sees
  -- it: an agent that grabs the mouse and then ignores the wheel is what made
  -- this look like it only happened to some people.
  --
  -- One report, one line. A detent is several reports, which is the count the
  -- outer terminal means, and it is what a forwarded tick already delivers.
  on_scroll = function(wheel)
    local id = store.selected
    -- The diff tab has no surface to scroll, so the wheel goes through the same
    -- offset the page keys move — otherwise it would be inert over the one tab
    -- whose content is longer than the pane by design.
    if id and tab_of(id) == DIFF_TAB then
      return scroll_by(id, wheel.up and 1 or -1)
    end
    return scroll_surface(surface_of(id, tab_of(id)), wheel.up and 1 or -1)
  end,

  -- Every key this pane does not claim goes on to the agent, and typing
  -- belongs at the live end of the stream: the offset is dropped and the key
  -- is DECLINED, so it still reaches the pty.
  on_key = function()
    snap_to_bottom(store.selected)
    return false
  end,

  -- The scrollbar, which is the only thing this pane paints that is a control
  -- rather than a report. Everything else on the border is a chip the kernel
  -- resolves itself through a click verb.
  on_click = function(hit)
    if hit.role ~= DRAG then
      return false
    end
    return scrollbar_grab(store.selected, hit)
  end,

  on_action = function(action)
    local id = store.selected
    if action == SCROLL_UP then
      return scroll_by(id, SCROLL_LINES)
    end
    if action == SCROLL_DOWN then
      return scroll_by(id, -SCROLL_LINES)
    end
    if action == FOCUS then
      -- Where `sessions.open` sends focus too: the pane that shows the session.
      command("focus", { text = NAME })
      return true
    end
    if action == "shell.open" then
      -- v1 `toggle_shell_view`: the chord flips between the two views, where
      -- the chips select outright. Swallowed without a session, because there
      -- is no terminal for anything else to do it to either.
      if id and shell_enabled() then
        show_tab(id, tab_of(id) == SHELL_TAB and AGENT_TAB or SHELL_TAB)
      end
      return true
    end
    if not id then
      return false
    end
    if action == EDITOR_OPEN then
      -- The chord FLIPS, where the chip selects outright — the same split the
      -- shell has. With nothing open there is nothing to flip to, and the tree
      -- is where a file comes from, so say that rather than showing an empty
      -- tab.
      if not file_of(id) then
        command("message", {
          text = "no file open — pick one in the file tree (F3)",
          level = "info",
        })
        return true
      end
      -- Two views of ONE file, so the key that opens the file flips between
      -- them: the code and what changed in it are the two things you look at
      -- while editing, and they are asked for in alternation. With no diff for
      -- this file the second stop does not exist and the key keeps its older
      -- meaning — back where you came from.
      if tab_of(id) ~= EDITOR_TAB then
        -- Through the same door as a click in the tree: nvim may have quit while
        -- the tab was hidden, and this is what starts it again. That covers the
        -- way back from the diff as well as the way in from the agent.
        ensure_editor(id, file_of(id))
      elseif diff_of(id) then
        remember_tab(id)
        show_tab(id, DIFF_TAB)
      else
        show_tab(id, previous_tab(id))
      end
      return true
    end
    if action == SELECT_AGENT then
      show_tab(id, AGENT_TAB)
    elseif action == SELECT_SHELL then
      if not shell_enabled() then
        return true
      end
      show_tab(id, SHELL_TAB)
    elseif action == SELECT_DIFF then
      if not diff_of(id) then
        return true
      end
      remember_tab(id)
      show_tab(id, DIFF_TAB)
    elseif action == SELECT_EDITOR then
      if not file_of(id) then
        return true
      end
      ensure_editor(id, file_of(id))
    else
      return false
    end
    return true
  end,
}
