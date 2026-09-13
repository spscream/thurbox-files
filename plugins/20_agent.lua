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

--- Vim's `fnameescape()` set, because `:e` takes a command LINE and a path is
--- whatever someone named a directory.
---
--- Written out rather than asked for: there is no round trip to nvim here, the
--- keys just arrive. This is the set vim escapes with a backslash, minus the two
--- control bytes in it (`\t` and `\n`) — typed, those are not characters a
--- command line reads but keys it acts on, so they are handled below instead.
local FNAME_SPECIAL = [[ *?[{`$\%#'"|!<]]

--- A path as `:e` will read it, which is not a path as the filesystem holds one.
---
--- Escaping the obvious characters is not enough, and the gap is not cosmetic.
--- Measured upstream on nvim 0.12.5 against the earlier version of this function,
--- which escaped ` \t\\%#|"*?[`:
---
---   * `` r`date>PWNED-tick`.txt `` — the backtick expanded and the file was created;
---   * `s<CR>:!date>PWNED-cr<CR>.txt` — the raw `\r` ENDED the command line and ran
---     what followed as an Ex command.
---
--- So two halves. Every character in `FNAME_SPECIAL` gets a backslash, and every
--- control byte gets a literal CTRL-V (`\22`) in front of it, which is how a
--- command line takes a byte it would otherwise act on. Bytes above 127 are left
--- alone: they are UTF-8 continuation bytes, and a backslash inside one would
--- rename the file being opened.
local function escape_for_edit(path)
  local out = {}
  for index = 1, #path do
    local char = path:sub(index, index)
    local byte = path:byte(index)
    if byte < 32 or byte == 127 then
      out[#out + 1] = "\22" .. char
    elseif FNAME_SPECIAL:find(char, 1, true) then
      out[#out + 1] = "\\" .. char
    else
      out[#out + 1] = char
    end
  end
  local escaped = table.concat(out)
  -- Special at the START of an `:edit` argument, where vim escapes them for the
  -- same reason: `+cmd` is a command to run and `>>` is a redirection.
  local first = escaped:sub(1, 1)
  if first == "-" or first == "+" or first == ">" then
    escaped = "\\" .. escaped
  end
  return escaped
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
local function border_frame(title, level, border, strip, bar)
  return {
    title = { { text = title, style = chrome.title_style(level) } },
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

  return {
    type = "surface",
    program = editor_key(session.id),
    -- A share of the remaining space, not a flag: `fill` is a NUMBER, and a
    -- boolean here is the kind of key the kernel drops without a word.
    fill = 1,
    frame = border_frame(
      fit_right_title(" " .. basename(path) .. " (editor) ", width, reserved_left),
      level,
      border,
      strip
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
--- The keys lead with CTRL-\ CTRL-N because we do not know what mode nvim is in:
--- typed in insert mode, `:confirm e ...` would go into the file. Two Escapes did
--- that job until a measurement upstream (nvim 0.12.5) found the mode they cannot
--- leave: with a `:confirm` prompt already up — the one THIS command raises when
--- the buffer is modified and `hidden` is off — the first Escape answers the
--- prompt, the second is swallowed, and `nfirm e <path>` is typed into the buffer.
--- CTRL-\ CTRL-N left every mode tried, prompt included.
---
--- `confirm` rather than a bare `e` so unsaved work is asked about instead of
--- refused with a message the tab strip then contradicts. Note stock nvim ships
--- `hidden` on, where `:confirm` never asks and the modified buffer is simply
--- hidden — the question then comes back at `:q` as `E162`, which is nvim
--- protecting the work rather than this call going wrong.
local function ensure_editor(id, path, keep)
  if type(path) ~= "string" or path == "" then
    return
  end
  set_file(id, path)
  remember_tab(id)
  if not (thurbox.granted or {}).program then
    command("message", {
      text = "the central pane needs the program capability — F6 → ] → t",
      level = "error",
    })
    -- Still switched to the tab: it draws the untrusted state, which is where
    -- the instruction above is repeated for anyone who missed the message band.
    show_tab(id, EDITOR_TAB, keep)
    return
  end
  command("program", {
    text = editor_key(id),
    -- An ABSOLUTE path, built by the tree from the session's own `cwd`:
    -- `thurbox.cmd.Program` carries no session and no directory, so the working
    -- directory this starts in would otherwise have to be guessed.
    repo = "nvim",
    args = { path },
    keys = "\28\14:confirm e " .. escape_for_edit(path) .. "\r",
  })
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
    -- F7, which is the key v1's review tab had on this same strip. An F-key and
    -- not a letter chord for the reason the other two are: a focused terminal
    -- keeps the bare `ctrl+<letter>` chords for the program inside it, and this
    -- pane is a focused terminal nearly all the time.
    {
      key = "f7",
      action = EDITOR_OPEN,
      desc = "open the editor tab",
      scope = "global",
      group = "UI",
    },
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
  events = { "user.openfile", "user.opendiff", "program.exited" },

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
