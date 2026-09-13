-- The file column: a TREE of the SELECTED session's working directory.
--
-- A tree, not a drill-down list: the root stays the session's working directory
-- and a directory opens IN PLACE, under its own row, so the context above it
-- never leaves the screen. The first cut of this pane replaced the whole view
-- on Enter, which reads as navigating away from the thing you were looking at.
--
-- Enter on a FILE emits `user.openfile`; the central pane picks it up and runs
-- an editor on it. This pane does not run the program itself, because a program
-- has to be drawn where there is room to read it and this column is 22% wide.
--
-- `files.list` is rooted at the session's working directory and the kernel
-- refuses a path outside it, so there is no path arithmetic to get wrong here
-- and no way for this pane to wander out of the worktree.

local theme = require("lib.theme")
local ui = require("lib.ui")
local widgets = require("lib.widgets")
local hover = require("lib.hover")
local chrome = require("lib.chrome")

local CURSOR = "files"

--- The changes list keeps its OWN cursor: the two tabs are two lists over two
--- different sets, and one shared position would put the selection on whatever
--- happened to sit at that index in the other.
local GIT_CURSOR = "files.changes"

local TREE_TAB, CHANGES_TAB = "tree", "changes"

--- Open the context menu over the selected row. The menu itself is a float in
--- `95_files_menu.lua`; this pane only says WHICH row it is about, and later
--- carries out what comes back.
local FILE_MENU = "files.menu"
local SELECT_TREE, SELECT_CHANGES = "files.tab.tree", "files.tab.changes"

--- Which tab this column is showing. In `state`, not a local, so it survives
--- the hot reload that editing this file causes.
local function tab_of()
  return state.tab == CHANGES_TAB and CHANGES_TAB or TREE_TAB
end

--- The session list publishes its selection here (`10_sessions.lua`), so this
--- column follows the row you are looking at rather than growing a second,
--- disagreeing idea of "current".
local function selected_session()
  local id = store.selected
  if type(id) ~= "string" or id == "" then
    return nil
  end
  return id
end

--- Which directories are open, keyed by path relative to the session root.
---
--- Read through a local and written back WHOLE. `state` hands back a copy, so a
--- nested field set in place is silently lost — the one trap the starter pane
--- warns about, and the only mutable structure this pane keeps.
local function expanded_set()
  local open = state.expanded
  if type(open) ~= "table" then
    return {}
  end
  return open
end

local function set_expanded(open)
  state.expanded = open
end

--- Which directories of the CHANGES tree the user has shut, by row id.
---
--- The opposite polarity to the set above, on purpose. A tree of the filesystem
--- is unbounded, so it starts closed and records what was opened; a tree of the
--- changed files is the answer the tab was opened for, so it starts open and
--- records the exceptions. Keyed by the row id rather than the path, because
--- `Staged` and `Changes` can both hold a `src/` and they shut separately.
local function shut_set()
  local shut = state.shut
  if type(shut) ~= "table" then
    return {}
  end
  return shut
end

local function set_shut(shut)
  state.shut = shut
end

local function join(dir, name)
  if dir == "" then
    return name
  end
  return dir .. "/" .. name
end

local function parent_of(path)
  return path:match("^(.*)/[^/]*$") or ""
end

--- The session's own working directory, so a relative path from `files.list`
--- can be handed to the editor as an ABSOLUTE one.
---
--- `thurbox.cmd.Program` carries no session and no directory, so the program it
--- starts would otherwise begin somewhere this pane cannot name. An absolute
--- path removes the question instead of answering it.
local function session_cwd(id)
  for _, row in ipairs(thurbox.sessions or {}) do
    if row.id == id then
      return row.cwd
    end
  end
  return nil
end

-- --- git status ------------------------------------------------------------
--
-- Two `run` keys, both scoped to the session so switching sessions cannot read
-- the previous one's answer:
--
--   `prefix:<id>` — where the session's working directory sits INSIDE the repo.
--     Porcelain paths are always relative to the repository root, whatever
--     directory git was invoked from, while `files.list` is rooted at the
--     session's `cwd`. For a worktree session the two are the same and the
--     prefix is empty; for a session started in a subdirectory they are not,
--     and without this every marker would land on the wrong row. Long `ttl`:
--     a worktree does not move.
--   `status:<id>` — the statuses themselves, `ttl = 2`, which is the cadence
--     herdr-sidebar settled on for the same poll.
--
-- `run` is the kernel's background worker: it dedupes in-flight asks, holds the
-- previous answer until the new one lands (so the column never blinks back to
-- "pending" on a refresh) and does nothing at all while an answer is fresh. So
-- asking on every frame is a map lookup, which is what the docs prescribe.
--
-- NOT covered here, deliberately: `--ignored`. herdr-sidebar dims ignored files
-- from a SECOND `git status` invocation, and a plugin gets four concurrent runs
-- total — spending a third of them to grey out `node_modules` is the wrong
-- trade until someone asks for it.

local STATUS_PROGRAM = "git status --porcelain=v1 -z --untracked-files=all"
local PREFIX_PROGRAM = "git rev-parse --show-prefix"

--- The answer to one of this plugin's runs, or nil while there is not one.
---
--- `run` is ABSENT, not refusing, until the user trusts this file — rule 4 —
--- so `if not run` is the honest check and every caller degrades to "no git
--- information" rather than to an error.
--- Returns the output, or nil plus WHY there is not one: "waiting" while the
--- answer is still coming and "failed" once git has said no. The two have to be
--- told apart or a session whose directory is not a repository reads as one
--- whose git status is perpetually about to arrive.
local function ask(key, program, ttl, session, refresh)
  if not run then
    return nil, "untrusted"
  end
  local id = key .. ":" .. session
  run(id, program, { session = session, ttl = ttl, refresh = refresh or nil })
  local answer = (thurbox.runs or {})[id]
  if not answer or answer.state == "pending" then
    return nil, "waiting"
  end
  if answer.state == "done" and answer.ok then
    return answer.stdout or ""
  end
  return nil, "failed"
end

--- One letter per file, the way VS Code spells it and herdr-sidebar copied.
---
--- Derived from the porcelain PAIR, not from one half of it: `X` is the index
--- and `Y` the worktree, and a file can be both. The worktree letter wins when
--- there is one, because that is the edit you have not dealt with yet.
local CONFLICTED = {
  DD = true,
  AU = true,
  UD = true,
  UA = true,
  DU = true,
  AA = true,
  UU = true,
}

local function letter_for(x, y)
  if CONFLICTED[x .. y] then
    return "!"
  end
  if x == "?" then
    return "U"
  end
  if y ~= " " and y ~= "" then
    return y
  end
  return x
end

--- One table, read by BOTH the tree and the changes list.
---
--- The single decision worth copying from herdr-sidebar outright: a letter has
--- one colour everywhere, so the two views cannot disagree about what a file's
--- state means. Roles, never literal colours, so this survives all thirty-six
--- palettes.
local function color_for(letter)
  if letter == "!" then
    return theme.bad
  elseif letter == "A" then
    return theme.role("diff_added")
  elseif letter == "D" then
    return theme.role("diff_removed")
  elseif letter == "U" then
    return theme.info
  elseif letter == "R" or letter == "C" then
    return theme.accent
  end
  return theme.warn
end

--- Porcelain v1, NUL-separated: `XY <path>\0`, and for a rename or a copy the
--- ORIGINAL path follows as a field of its own. That trailing field is consumed
--- here rather than parsed as another entry — read as one it would become a
--- phantom row whose status letter is the first two characters of a filename.
local function parse_status(out, prefix)
  local files_by_path, staged, unstaged = {}, {}, {}
  local at, size = 1, #out
  while at <= size do
    local stop = out:find("\0", at, true)
    if not stop then
      break
    end
    local entry = out:sub(at, stop - 1)
    at = stop + 1
    if #entry > 3 then
      local x, y = entry:sub(1, 1), entry:sub(2, 2)
      local path = entry:sub(4)
      if x == "R" or x == "C" then
        local origin = out:find("\0", at, true)
        if origin then
          at = origin + 1
        end
      end
      -- Repo-root-relative to column-relative. A path outside the session's own
      -- directory belongs to no row here and is dropped rather than shown at a
      -- made-up depth.
      local local_path = path
      if prefix ~= "" then
        if path:sub(1, #prefix) ~= prefix then
          local_path = nil
        else
          local_path = path:sub(#prefix + 1)
        end
      end
      if local_path and local_path ~= "" then
        local letter = letter_for(x, y)
        local row = { path = local_path, letter = letter, x = x, y = y }
        files_by_path[local_path] = letter
        if CONFLICTED[x .. y] then
          unstaged[#unstaged + 1] = row
        else
          if x ~= " " and x ~= "?" then
            staged[#staged + 1] = { path = local_path, letter = letter_for(x, " ") }
          end
          if y ~= " " then
            unstaged[#unstaged + 1] =
              { path = local_path, letter = letter_for(x == "?" and "?" or " ", y) }
          end
        end
      end
    end
  end
  local function by_path(a, b)
    return a.path < b.path
  end
  table.sort(staged, by_path)
  table.sort(unstaged, by_path)
  return files_by_path, staged, unstaged
end

--- A directory is marked by its LOUDEST descendant, collapsed to three buckets:
--- a conflict anywhere beneath it beats any change, and any tracked change
--- beats untracked-only. Straight from herdr-sidebar, and the reason is the
--- question a folder badge answers — "is this worth opening?" — which a folder
--- carrying seven different letters does not answer at all.
local RANK = { ["!"] = 3, U = 1 }
local function rank_of(letter)
  return RANK[letter] or 2
end

local function fold_directories(files_by_path)
  local dirs = {}
  for path, letter in pairs(files_by_path) do
    local rank = rank_of(letter)
    local at = path:find("/", 1, true)
    while at do
      local dir = path:sub(1, at - 1)
      if (dirs[dir] or 0) < rank then
        dirs[dir] = rank
      end
      at = path:find("/", at + 1, true)
    end
  end
  return dirs
end

--- The whole index for one session, memoized on the raw git output.
---
--- Rebuilt only when the bytes change: `run` hands back the same string while
--- an answer is fresh, so without this the parse and the fold would run on
--- every frame for an answer that had not moved.
local git_cache = {}

local function git_index(session, refresh)
  if not run or not session then
    return nil, "untrusted"
  end
  local prefix, why = ask("prefix", PREFIX_PROGRAM, 300, session)
  if not prefix then
    return nil, why
  end
  prefix = prefix:gsub("%s+$", "")
  local out
  out, why = ask("status", STATUS_PROGRAM, 2, session, refresh)
  if not out then
    return nil, why
  end
  if git_cache.session == session and git_cache.raw == out and git_cache.prefix == prefix then
    return git_cache.index
  end
  local files_by_path, staged, unstaged = parse_status(out, prefix)
  local index = {
    files = files_by_path,
    dirs = fold_directories(files_by_path),
    staged = staged,
    unstaged = unstaged,
  }
  git_cache.session, git_cache.raw, git_cache.prefix, git_cache.index = session, out, prefix, index
  return index
end

--- Rows the kernel called files and this pane has since seen list like
--- directories: symlinks to directories, keyed `session\0path`.
---
--- `files.list` reports `dir` from the directory ENTRY — `DirEntry::file_type`,
--- which by definition does not follow a symlink — so a link to a directory
--- arrives here as a leaf. Drawn as a file it is only odd; ACTED on as a file it
--- is the bug this answers, because Enter hands a leaf's path to the editor and
--- the editor opened a directory listing in the tab.
---
--- The pane has no filesystem and cannot look. It can ASK, though: `files.list`
--- on the row's own path succeeds exactly when that path is a directory once
--- the link is followed, and the kernel still refuses anything outside the
--- session. So the question is put once per row, on the press, and remembered —
--- a directory read per frame is what the memo below exists to avoid.
---
--- A link pointing OUTSIDE the session is not covered and cannot be from here:
--- the kernel refuses to read it at all, and its refusal is the same whether the
--- target is a file or a directory. Such a row still goes to the editor, which
--- is what it did before.
local linked = {}

local function link_key(session, path)
  return session .. "\0" .. path
end

--- Directories first, then names, both case-insensitively — the order a file
--- tree is read in, not the order the filesystem happened to hand back.
local function listing(session, path)
  local ok, listed = pcall(files.list, session, path)
  if not ok then
    -- A session on a remote or WSL backend can be one this thurbox cannot read
    -- from here. Saying so is better than an empty column that looks like an
    -- empty directory.
    return nil, tostring(listed)
  end
  local rows = {}
  for _, entry in ipairs(listed or {}) do
    rows[#rows + 1] = { name = entry.name, dir = entry.dir }
  end
  table.sort(rows, function(a, b)
    if a.dir ~= b.dir then
      return a.dir
    end
    return a.name:lower() < b.name:lower()
  end)
  return rows
end

--- The walk, memoized — and the memo is the whole reason this pane is usable
--- with a mouse.
---
--- `files.list` is not a snapshot lookup. It is a directory read that goes
--- through the session's backend, which for a remote or WSL session leaves this
--- machine. A `render` that calls it once per open directory pays that on EVERY
--- frame, and moving the pointer across the column is a stream of frames — the
--- symptom being a column that stutters under the mouse while nothing about it
--- has changed.
---
--- The kernel cannot invalidate this for us: `pure` keys a cached tree on the
--- snapshot values a render read, and a directory listing is not one of them.
--- So the key is built here from the only two things that change what the walk
--- produces — which session, and which directories are open — plus a stamp this
--- pane bumps when it wants a re-read on purpose. Memoizing on an upvalue is
--- what `10_sessions` does with its row cache and does not cost purity: purity
--- is about writing `store`/`state` or calling `command` from `render`, and this
--- writes neither.
---
--- The cost of the trade is honest and bounded: a file created by something
--- else does not appear until you open or close a directory, or press `r`.
local cache = {}

local function signature(session, open)
  local keys = {}
  for path in pairs(open) do
    keys[#keys + 1] = path
  end
  table.sort(keys)
  -- The pending operation's STATE rides along: `invalidate` fires when the ask
  -- is made, which is before the file exists, so without this the tree would be
  -- re-walked once — too early — and then hold that answer. The state moves
  -- exactly once more, when the run lands.
  local op = state.opkey
  local answer = type(op) == "string" and (thurbox.runs or {})[op] or nil
  -- A NUL joiner rather than a comma: it cannot occur in a path, so two
  -- different sets can never spell the same signature.
  return session
    .. "\0"
    .. table.concat(keys, "\0")
    .. "\0"
    .. tostring(op)
    .. (answer and answer.state or "")
end

--- The tree flattened to the rows actually visible: every entry of the root,
--- and every entry of a directory that is open, in place under it.
---
--- Depth-first and recursive, because that IS the display order — a second pass
--- to sort it would only be re-deriving what the walk already knows. Only open
--- directories are listed, so the cost is the rows on screen, not the worktree.
local function visible_rows(session)
  local open = expanded_set()
  local stamp = state.stamp or 0
  local sig = signature(session, open)
  if cache.sig == sig and cache.stamp == stamp then
    return cache.rows, cache.err
  end

  local rows = {}
  local first_error

  local function walk(path, depth)
    local listed, err = listing(session, path)
    if not listed then
      first_error = first_error or err
      return
    end
    for _, entry in ipairs(listed) do
      local full = join(path, entry.name)
      -- A symlinked directory is corrected HERE and not in `listing`, so it
      -- keeps the place among the files that the kernel's sort gave it.
      -- Correcting it before the sort was measured first and is worse: the row
      -- moves up into the directories the moment it is discovered, the cursor
      -- stays at the index it was on, and the next Enter lands on whatever slid
      -- into that place — `src`, in the run that showed it.
      local dir = entry.dir or linked[link_key(session, full)] or false
      local is_open = dir and open[full] or false
      rows[#rows + 1] = {
        -- The identity is the PATH, not the name: two directories may both
        -- hold a `README.md`, and a cursor keyed by name would jump between
        -- them when one of them opened.
        path = full,
        name = entry.name,
        dir = dir,
        depth = depth,
        open = is_open,
      }
      if is_open then
        walk(full, depth + 1)
      end
    end
  end

  walk("", 0)
  if first_error and #rows == 0 then
    rows = nil
  else
    first_error = nil
  end

  cache.sig, cache.stamp, cache.rows, cache.err = sig, stamp, rows, first_error
  return rows, first_error
end

--- Throw the memo away and let the next render walk the filesystem again.
local function invalidate()
  state.stamp = (state.stamp or 0) + 1
end

--- Built the same way in `render`, `on_action` and `on_click`, which is the
--- point of `ui.cursor`: several call sites, one cursor, no state passed around.
local function cursor_for(session)
  local rows = session and visible_rows(session) or {}
  return ui.cursor(CURSOR, rows or {}, { id = "path" }), rows
end

--- What a row DOES: a directory opens or closes, a file goes to the editor.
---
--- Split out because the pointer and `Enter` must not disagree about it. The
--- first cut had `on_click` only move the selection — which is what the session
--- list does, and correct there, because a session row has nowhere further to
--- go and Enter is what opens it. A tree row does: clicking a directory that
--- then just sits there reads as a pane ignoring the mouse, and that is exactly
--- how it was reported.
--- Which side of the index has something to say about this path, if either.
---
--- The worktree first: a file you are about to edit is nearly always asked
--- "what have I changed since I last staged", and a path that sits in both
--- lists is being asked about the half that is still moving.
---
--- A linear scan over the two lists rather than a third lookup table built for
--- it — this runs on one keypress, over a list whose length is "how much is
--- changed", and a table built every frame to save it would cost more.
local function diff_side(index, path)
  if not index then
    return nil
  end
  for _, row in ipairs(index.unstaged) do
    if row.path == path then
      return false, row.letter == "U"
    end
  end
  for _, row in ipairs(index.staged) do
    if row.path == path then
      return true, false
    end
  end
  return nil
end

--- Tell the central pane a file is about to be picked, so the editor it starts
--- is already up by the time one is.
---
--- Measured on this machine's own config: nvim takes ~1.8s to start (1766, 1911
--- and 1766 ms over three runs, against 139 ms for `nvim --clean`), and until
--- this event that cost was paid by the first Enter. Reaching the column is the
--- earliest honest signal of intent — a key that focuses it or a press inside
--- it — and it is early by seconds, not milliseconds.
---
--- Sent on every such moment rather than once: starting a program that is
--- already running is a map lookup on the other side, so there is no state here
--- to keep right. A pane that cannot start programs ignores it.
---
--- Carries the session and nothing else: WHERE that editor should stand is a
--- question the pane that starts it answers, from the same snapshot this one
--- would have read.
local function warm_editor()
  local session = selected_session()
  if not session then
    return
  end
  command("emit", { text = "editorwarm", session = session })
end

--- Does a row the kernel called a file list like a directory?
---
--- Asked only about leaves, only on a press, and remembered either way: `false`
--- is the answer for every ordinary file, and caching it is what keeps a second
--- click on the same file from paying for the question again.
local function lists_as_dir(session, path)
  local key = link_key(session, path)
  local known = linked[key]
  if known ~= nil then
    return known
  end
  local ok = pcall(files.list, session, path)
  linked[key] = ok
  if ok then
    -- The row is about to draw as a directory, and the walk that decides that
    -- is memoized on a signature this discovery is not part of.
    invalidate()
  end
  return ok
end

local function activate(session, item, clicked)
  if not item then
    return true
  end
  if item.dir or lists_as_dir(session, item.path) then
    local open = expanded_set()
    -- Not `= not open[...]`: the set is written back WHOLE, and `false` in it
    -- would be a key present with a falsy value — `nil` is what "closed" means
    -- to the walk and to the signature.
    open[item.path] = (not open[item.path]) or nil
    set_expanded(open)
    return true
  end
  -- A file: hand it to the central pane, which has the room to show an editor
  -- and already owns the surface there. Every other scalar on an `emit` table
  -- travels as payload, so the path rides along without a `store` key both
  -- panes would have to remember to clear.
  local root = session_cwd(session)
  if not root then
    command("message", {
      text = "this session has no working directory to open from",
      level = "error",
    })
    return true
  end
  -- The git side rides along on the SAME event, so the editor and the diff tab
  -- can never disagree about which file is open. Two emits would be two
  -- moments, and the second one is the one that would be missing when a file
  -- stops being changed.
  --
  -- `path` is absolute because the editor is started with it as an argument and
  -- has no session to be relative to; `diff` is the SAME file spelled the way
  -- `git diff` is asked about it — relative to the session's directory, which
  -- is where `run` starts. One of the two is always wrong for the other job,
  -- which is why both travel.
  local index = git_index(session)
  local staged, untracked = diff_side(index, item.path)
  command("emit", {
    text = "openfile",
    path = root .. "/" .. item.path,
    session = session,
    -- The pointer opens the file and leaves the focus here; a key press takes
    -- it with you. The tree's own keys are plugin-scoped, so a click that
    -- focused the editor left this column unable to answer its arrows until it
    -- was clicked back into — which is exactly how it was reported.
    keep = clicked == true,
    diff = staged ~= nil and item.path or "",
    staged = staged == true,
    untracked = untracked == true,
  })
  return true
end

-- --- file operations ------------------------------------------------------

--- Single quotes for `sh -c`, which is what `run` hands the program to.
---
--- `run` takes ONE string, not an argv the multiplexer quotes for you, so a path
--- with a space, a quote or a `$` in it is this function's problem. The `'\''`
--- dance is the only escape a single-quoted POSIX string has.
local function shell_quote(text)
  -- Parenthesised: `gsub` returns the count as a second value, and a bare call
  -- at the END of a concatenation would drag it in.
  return "'" .. (tostring(text):gsub("'", "'\\''")) .. "'"
end

--- The path, or nil if it would leave the session's directory.
---
--- `files.list` is rooted at that directory and the kernel refuses to read
--- outside it (`install_files`: "It never gets a filesystem"). `run` is a SHELL
--- and has no such root, so the check the kernel performs for every read has to
--- be performed HERE for every write — by the one plugin that can write. An
--- absolute path, a `~`, or a `..` segment is refused rather than cleaned up:
--- the caller typed something that means somewhere else, and quietly acting on
--- a different path is worse than declining.
local function inside(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" or path:sub(1, 1) == "~" then
    return nil
  end
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      return nil
    end
  end
  return (path:gsub("/+$", ""))
end

--- The shell one-liner for one operation, or nil and why not.
---
--- Every one of them refuses to clobber: `mv`, `cp` and `>` all overwrite in
--- silence, and a rename that ate the file it landed on would be this menu's
--- first bug report. The test is in the SHELL and not here because only the
--- shell is standing in the session's directory — this pane can see the tree it
--- listed, not the file that appeared a second ago.
local function op_program(op)
  local path = inside(op.path)
  if not path then
    return nil, "that path is not inside the session"
  end
  local parent = path:match("^(.*)/[^/]*$") or ""
  local q = shell_quote

  if op.verb == "delete" then
    -- `-r` because a directory is one of the things offered; `--` because a
    -- name starting with `-` is a name, not a flag.
    return "rm -rf -- " .. q(path)
  end

  local target = inside(op.target)
  if not target then
    return nil, "that name is not inside the session"
  end

  local dest
  if op.verb == "newfile" or op.verb == "newdir" then
    local into = op.dir and path or parent
    dest = into == "" and target or (into .. "/" .. target)
  elseif op.verb == "move" then
    dest = target
  else
    -- Rename and duplicate take a NAME, and land beside the row. A name with a
    -- slash in it is taken at its word and treated as a path, so `Rename…` can
    -- move a file without anyone having to guess which entry does that.
    dest = (target:find("/") or parent == "") and target or (parent .. "/" .. target)
  end

  local dest_parent = dest:match("^(.*)/[^/]*$") or ""
  local mkparent = dest_parent ~= "" and ("mkdir -p -- " .. q(dest_parent) .. " && ") or ""
  local refuse = "if [ -e " .. q(dest) .. " ]; then echo 'already exists' >&2; exit 1; fi; "

  if op.verb == "newfile" then
    return refuse .. mkparent .. "touch -- " .. q(dest)
  end
  if op.verb == "newdir" then
    return refuse .. mkparent .. "mkdir -p -- " .. q(dest)
  end
  if op.verb == "duplicate" then
    return refuse .. mkparent .. "cp -R -- " .. q(path) .. " " .. q(dest)
  end
  if op.verb == "rename" then
    return refuse .. mkparent .. "mv -- " .. q(path) .. " " .. q(dest)
  end
  if op.verb == "move" then
    -- Moving ONTO an existing directory means moving INTO it, which is what
    -- `mv` already does and what "Move to… src/api" is asking for. Only a
    -- non-directory in the way is a refusal.
    return "if [ -d "
      .. q(dest)
      .. " ]; then mv -- "
      .. q(path)
      .. " "
      .. q(dest)
      .. "/; elif [ -e "
      .. q(dest)
      .. " ]; then echo 'already exists' >&2; exit 1; else "
      .. mkparent
      .. "mv -- "
      .. q(path)
      .. " "
      .. q(dest)
      .. "; fi"
  end
  return nil, "unknown file operation"
end

--- What the last operation is doing, or what went wrong with it.
---
--- Read from `thurbox.runs`, which keeps an answer until the plugin goes away —
--- so a one-shot ask made in `on_event` is still readable here, frames later.
--- Nothing is written: the banner is derived, which is what keeps this pane
--- `pure` while still reporting.
local function op_alert()
  local key = state.opkey
  if type(key) ~= "string" then
    return nil
  end
  local answer = (thurbox.runs or {})[key]
  if not answer then
    return nil
  end
  if answer.state ~= "done" then
    return (state.oplabel or "working") .. "…", theme.muted
  end
  if answer.ok then
    return nil
  end
  local said = (answer.stderr or ""):match("^[^\n]*") or ""
  said = said:gsub("^%s+", ""):gsub("%s+$", "")
  return (state.oplabel or "failed") .. ": " .. (said ~= "" and said or "failed"), theme.bad
end

-- --- the two tabs ---------------------------------------------------------

--- The tab strip, painted on this column's own top border.
---
--- Border cells, not a content row: a 22%-wide column cannot spend a line on
--- chrome, and `ui.panel`'s `overlay_left` paints onto cells the frame already
--- owns. Each chip carries a `role`, which is what makes it a click target —
--- a run inside a line is a hitbox without being a sized node of its own.
---
--- The labels SHRINK before anything is dropped. At 18 columns
--- `Files`+`Changes 12` does not fit, and a strip that overflowed would be
--- clipped at the corner, cutting a chip in half rather than saying less.
local function tab_chips(width, tab, index)
  local count = index and (#index.staged + #index.unstaged) or 0
  local changes = count > 0 and ("Changes " .. count) or "Changes"
  local function fits(second)
    return (widgets.len("Files") + 2) + 1 + (widgets.len(second) + 2) <= math.max(0, width - 2)
  end
  if not fits(changes) then
    changes = count > 0 and ("Git " .. count) or "Git"
  end
  local specs = {
    { label = "Files", active = tab == TREE_TAB, role = "action:" .. SELECT_TREE },
    { label = changes, active = tab == CHANGES_TAB, role = "action:" .. SELECT_CHANGES },
  }

  local runs = {}
  for order, spec in ipairs(specs) do
    if order > 1 then
      runs[#runs + 1] = { text = "─", style = chrome.border_style("active") }
    end
    runs[#runs + 1] = {
      text = " " .. spec.label .. " ",
      style = hover.style(spec.role, {
        fg = theme.role("inverted_fg"),
        bg = theme.role("accent_bright"),
        bold = true,
      }, spec.active and {
        fg = theme.role("inverted_fg"),
        bg = theme.role("accent"),
        bold = true,
      } or {
        fg = theme.role("selection_fg"),
        bg = theme.role("selection_bg"),
        bold = true,
      }),
      role = spec.role,
    }
  end
  return runs
end

--- One section of the changes tab, as tree rows appended to `rows`.
---
--- A tree and not a flat list because the paths repeat: twenty files under
--- `src/api` spend twenty rows saying `src/api` in the muted half of a column
--- 22 cells wide, and the shared prefix is the thing a reader groups by anyway.
---
--- Directory rows are built from the CHANGED paths only, so every directory
--- here holds something — which is why they carry no marker of their own. A
--- chain with one child and no files of its own is compressed onto a single row
--- (`a/b/c`), the trick editors call a compact folder: without it a deep repo
--- spends most of the column on indent.
local function change_tree(files, section, shut, rows)
  local root = { kids = {}, order = {}, files = {} }
  for _, file in ipairs(files) do
    local node = root
    local dir = file.path:match("^(.*)/[^/]*$")
    if dir then
      for part in dir:gmatch("[^/]+") do
        local kid = node.kids[part]
        if not kid then
          kid = { kids = {}, order = {}, files = {} }
          node.kids[part] = kid
          node.order[#node.order + 1] = part
        end
        node = kid
      end
    end
    node.files[#node.files + 1] = file
  end

  local function by_path(a, b)
    return a.path < b.path
  end

  local function emit(node, prefix, depth)
    -- Directories first and each side alphabetical — the order the tree tab
    -- already shows, so the two tabs do not disagree about where a name sits.
    table.sort(node.order)
    for _, name in ipairs(node.order) do
      local kid, label, path = node.kids[name], name, join(prefix, name)
      while #kid.order == 1 and #kid.files == 0 do
        local only = kid.order[1]
        label, path, kid = label .. "/" .. only, join(path, only), kid.kids[only]
      end
      -- `/` after the section marks this id as a directory's, so a file and the
      -- directory that holds it can never collide in the shut set.
      local id = section .. "\0/" .. path
      local open = not shut[id]
      rows[#rows + 1] = {
        id = id,
        section = section,
        path = path,
        name = label,
        dir = true,
        depth = depth,
        open = open,
      }
      if open then
        emit(kid, path, depth + 1)
      end
    end
    table.sort(node.files, by_path)
    for _, file in ipairs(node.files) do
      rows[#rows + 1] = {
        id = section .. "\0" .. file.path,
        section = section,
        path = file.path,
        name = file.path:match("[^/]+$") or file.path,
        letter = file.letter,
        staged = section == "staged",
        depth = depth,
      }
    end
  end

  emit(root, "", 0)
end

--- Both sections as ONE row list with group headings.
---
--- In herdr-sidebar's order and with its rule: `Staged` is drawn only when
--- something is staged, `Changes` always. The id carries the section as well as
--- the path, because one file can be in both — staged hunks and newer unstaged
--- ones — and two rows sharing an identity would be one row to the cursor.
---
--- The heading counts FILES, not rows: it answers "how much is changed", and
--- the directories the tree adds are not changes.
local function change_rows(index)
  local rows = {}
  local shut = shut_set()
  local at = 1
  change_tree(index.staged, "staged", shut, rows)
  if rows[at] then
    rows[at].head = "Staged " .. #index.staged
  end
  at = #rows + 1
  change_tree(index.unstaged, "changes", shut, rows)
  if rows[at] then
    rows[at].head = "Changes " .. #index.unstaged
  end
  return rows
end

--- One row of EITHER tree: indent, glyph, name, and a marker on the right.
---
--- Shared by the two tabs so they cannot drift apart — the whole point of
--- giving the changes its own tree is that a path sits where the eye already
--- learned to look for it. The caller supplies the marker because that is the
--- one thing the two tabs disagree about: the tree tab folds a directory's
--- worst letter into a dot, the changes tab leaves directories unmarked.
---
--- Indent carries the depth and the glyph carries the state: `▾` open, `▸`
--- closed, two spaces for a file so its name lines up with the names of the
--- directories beside it. Colour is a THEME ROLE, so this reads correctly under
--- all thirty-six palettes and hardcodes nothing.
---
--- The marker is RIGHT-aligned and the name is what gets eaten when the two
--- collide — herdr-sidebar's rule, and the right one: a truncated filename is
--- still recognisable, a clipped status letter is a lie.
local function tree_span(item, width, mark, mark_style)
  local glyph = "  "
  if item.dir then
    glyph = item.open and "▾ " or "▸ "
  end
  local lead = " " .. string.rep("  ", item.depth) .. glyph

  -- One cell shy of the right border, so the marker never sits against the
  -- frame and never lands under the overflow count.
  local target = math.max(0, width - 3)
  local budget = math.max(1, target - widgets.len(lead) - (mark and 2 or 0))
  local name = widgets.truncate(item.name, budget)
  local spans = {
    {
      text = lead .. name,
      style = { fg = item.dir and theme.accent or theme.text },
    },
  }
  if mark then
    local pad = math.max(1, target - widgets.len(lead) - widgets.len(name) - 1)
    spans[#spans + 1] = { text = string.rep(" ", pad) }
    spans[#spans + 1] = { text = mark, style = mark_style }
  end
  return spans
end

--- A row in the changes tab: the status letter on the right of a file, nothing
--- on the right of a directory — every directory in this tree holds a change,
--- so a marker on all of them would say the same thing on every row.
local function change_span(item, width)
  if item.dir then
    return tree_span(item, width)
  end
  return tree_span(item, width, item.letter, { fg = color_for(item.letter), bold = true })
end

--- The cursor over the changes list, built the same way in every call site.
local function change_cursor(index)
  local rows = index and change_rows(index) or {}
  return ui.cursor(GIT_CURSOR, rows, { id = "id" }), rows
end

--- Enter or a click on a changed file: show its diff in the central pane.
---
--- A diff is a wide thing and this column is 22% of the screen, so the same
--- split the editor already uses applies — this pane names the file, the pane
--- with room draws it. `staged` rides along because `git diff` and
--- `git diff --cached` are two different answers about the same path, and the
--- row the user clicked is the one that says which they meant.
---
--- `untracked` rides along for the same reason and one more: `git diff` has
--- NOTHING to say about a file git has never seen, so the plain command answers
--- an untracked path with silence — which reads as "no changes" when the truth
--- is "all of it is new". The other side needs `--no-index` there, and only
--- this side knows which rows those are: `letter_for` sends `?` to `U` and
--- sends every conflict to `!`, so `U` names untracked and nothing else.
local function open_diff(session, item, clicked)
  if not item or item.dir then
    return true
  end
  command("emit", {
    text = "opendiff",
    -- Same rule as the tree's: see `activate`.
    keep = clicked == true,
    path = item.path,
    session = session,
    staged = item.staged and true or false,
    untracked = item.letter == "U",
  })
  return true
end

--- Shut a directory row or open it again, writing the set back WHOLE.
---
--- `nil` and not `false` for an open one, the same trap the expanded set
--- documents: a key present with a falsy value is still a key, and `pairs`
--- would carry it forever.
local function shut_change_dir(item, shut_it)
  local shut = shut_set()
  shut[item.id] = shut_it or nil
  set_shut(shut)
  return true
end

--- What a row of the changes tab DOES: a directory folds, a file shows a diff.
---
--- Split out for the same reason the tree tab's `activate` is: the pointer and
--- `Enter` must not disagree about it.
local function activate_change(session, item, clicked)
  if not item then
    return true
  end
  if item.dir then
    return shut_change_dir(item, item.open)
  end
  return open_diff(session, item, clicked)
end

return {
  name = "files",

  -- Its own column, placed LAST in `layout.lua` so it sits against the right
  -- edge with the agent between it and the session list.
  slot = "files",
  order = 90,
  focusable = true,

  -- Reads `store.selected`, `state`, `files.list` and the theme; every write is
  -- in `on_action`. Same bargain `10_sessions` takes.
  pure = true,

  keys = {
    -- An F-key, and deliberately: a focused terminal keeps the bare
    -- `ctrl+<letter>` chords for the program running in it, so a letter chord
    -- would be unreachable from exactly the pane you want to leave. `toggle`
    -- makes it the way back out as well as in.
    {
      key = "f3",
      action = "files.focus",
      desc = "the selected session's files",
      scope = "global",
      group = "UI",
    },
    -- Navigation is DECLARED, not inherited: `ui.cursor` holds the position but
    -- nothing moves it until a key says so.
    { key = "j", action = "files.next", desc = "next row", group = "Files" },
    { key = "k", action = "files.previous", desc = "previous row", group = "Files" },
    { key = "down", action = "files.next", desc = "next row", group = "Files" },
    { key = "up", action = "files.previous", desc = "previous row", group = "Files" },
    -- The tree pair, in both the vim spelling and the arrows. `right`/`l` opens
    -- a directory, `left`/`h` closes it — and on a row that is already closed,
    -- `left` goes to its parent, which is what makes a deep tree climbable
    -- without hunting for the parent row by eye.
    { key = "enter", action = "files.toggle", desc = "open/close a directory", group = "Files" },
    { key = "l", action = "files.expand", desc = "open a directory", group = "Files" },
    { key = "right", action = "files.expand", desc = "open a directory", group = "Files" },
    {
      key = "h",
      action = "files.collapse",
      desc = "close it, or go to the parent",
      group = "Files",
    },
    {
      key = "left",
      action = "files.collapse",
      desc = "close it, or go to the parent",
      group = "Files",
    },
    -- The listing is cached between expands, so re-reading it is a key rather
    -- than something that happens on its own. It forces the git poll too: `r`
    -- means "you are looking at something stale", and which half is stale is
    -- not a distinction worth making the user hold.
    { key = "r", action = "files.reload", desc = "re-read the tree", group = "Files" },
    -- One key for both chips, because there are two of them: a pair of keys
    -- for a two-state toggle is a key spent saying what the user can already
    -- see on the border.
    { key = "tab", action = "files.tab", desc = "files / changes", group = "Files" },
    -- `m` and not the right mouse button, which the coordinator drops before any
    -- plugin sees it: `on_mouse` matches `Down/Drag/Up(Left)`, the wheel and
    -- `Moved`, and everything else falls into `_ => {}`. A context menu on the
    -- pointer is a kernel patch; this is the same menu with a key on it.
    { key = "m", action = FILE_MENU, desc = "new / rename / delete…", group = "Files" },
  },

  -- The palette's rows, so both tabs are reachable by name as well as by the
  -- chip and the toggle.
  commands = {
    { action = SELECT_TREE, desc = "show the file tree" },
    { action = SELECT_CHANGES, desc = "show the changed files" },
  },

  -- `git status` and `git diff`, in the SESSION's working directory and on the
  -- session's host — which is what makes the column right for a session that
  -- does not live on this machine. `run` is absent until the user trusts this
  -- file, and every read of it above degrades rather than fails.
  capabilities = { "run" },

  -- The context menu's answer. The menu holds no capability of its own, so the
  -- verb travels to the one plugin that does — see `95_files_menu.lua`.
  events = { "user.fileop" },

  render = function(ctx)
    local width = ctx.width or 0
    local height = math.max(0, (ctx.height or 0) - 2)
    local session = selected_session()
    local tab = tab_of()
    -- Asked for on EVERY frame, which `run` turns into a map lookup while the
    -- answer is fresh. Nil until the user trusts this file with `run`, and both
    -- views degrade to "no git information" rather than to an error.
    local index, why
    if session then
      index, why = git_index(session)
    end

    --- The title is EMPTY and right-aligned: the chips are on the same border,
    --- and at 18 columns there is no room for both. The pane says what it is
    --- through the lit chip instead.
    local function framed(body)
      return ui.panel({
        title = "",
        title_align = "right",
        focused = ctx.focused,
        body = body,
        overlay_left = tab_chips(width, tab, index),
      })
    end

    local function nothing(title, hint, hint_action)
      return framed(ui.list({
        items = {},
        width = width,
        height = height,
        empty = ui.empty({
          title = title,
          width = width,
          hint = hint,
          hint_action = hint_action,
        }),
        pad = true,
      }))
    end

    if not session then
      return nothing("no session selected", "%s to come back", "files.focus")
    end

    if tab == CHANGES_TAB then
      if not run then
        -- Honest rather than empty: this pane cannot grant itself the
        -- capability, and an empty "Changes" tab is indistinguishable from a
        -- clean tree.
        return nothing("not trusted to read git", "F6 → ] → t grants it")
      end
      if not index then
        return nothing(why == "failed" and "not a git repository" or "reading git status…")
      end
      local cursor, rows = change_cursor(index)
      return framed(ui.list({
        items = rows,
        cursor = cursor,
        width = width,
        height = height,
        header = function(item)
          if not item.head then
            return nil
          end
          return ui.rule(item.head, math.max(0, width - 2))
        end,
        row = function(item)
          return change_span(item, width)
        end,
        empty = ui.empty({ title = "no changes", width = width }),
        on_overflow = "border",
        pad = true,
      }))
    end

    local rows, err = visible_rows(session)
    if not rows then
      return nothing("unreadable: " .. err)
    end

    local cursor = ui.cursor(CURSOR, rows, { id = "path" })

    -- A row of the column and not a message in the band: the band is shared and
    -- transient, and "rm: Permission denied" is an answer to something you did
    -- HERE that should still be on screen when you look back at the tree.
    local alert, alert_fg = op_alert()

    local body = ui.list({
      items = rows,
      cursor = cursor,
      width = width,
      height = alert and math.max(0, height - 1) or height,
      fill = alert and 1 or nil,
      -- The git marker, which is the one thing this tab paints that the
      -- changes tab does not: a letter on a file, a dot on a directory.
      row = function(item)
        local mark, mark_style
        if index then
          if item.dir then
            local rank = index.dirs[item.path]
            if rank then
              -- A dot, not a letter: a folder holding seven different letters
              -- cannot answer "which one", and the question it is actually
              -- asked is "is this worth opening".
              local fg = theme.warn
              if rank == 3 then
                fg = theme.bad
              elseif rank == 1 then
                fg = theme.info
              end
              mark, mark_style = "●", { fg = fg, bold = true }
            end
          else
            local letter = index.files[item.path]
            if letter then
              mark, mark_style = letter, { fg = color_for(letter), bold = true }
            end
          end
        end
        return tree_span(item, width, mark, mark_style)
      end,
      empty = ui.empty({ title = "empty directory", width = width }),
      -- The hidden-row counts ride the frame rather than eating a row each.
      on_overflow = "border",
      pad = true,
    })

    if not alert then
      return framed(body)
    end
    return framed({
      type = "box",
      children = {
        {
          type = "text",
          len = 1,
          text = {
            {
              {
                text = " " .. widgets.truncate(alert, math.max(1, width - 3)),
                style = { fg = alert_fg },
              },
            },
          },
        },
        body,
      },
    })
  end,

  --- Carry out what the context menu chose.
  ---
  --- The ask is made ONCE, from here, rather than every frame from `render` the
  --- way the git reads are: a read may be repeated for free and a `mv` may not.
  --- `run` keeps an answer until the plugin goes away, so `op_alert` can still
  --- read it frames later without anyone re-asking. The key carries a counter
  --- for the same reason: `run` dedupes on the key and would hand back the
  --- previous answer for a command it never ran.
  on_event = function(name, payload)
    if name ~= "user.fileop" then
      return
    end
    local op = payload or {}
    local session = op.sid or store.selected
    if type(op.path) ~= "string" or type(session) ~= "string" or session == "" then
      return
    end
    if not run then
      command("message", { text = "not trusted to change files", level = "error" })
      return
    end
    local program, why = op_program(op)
    if not program then
      command("message", { text = why or "that file operation is not possible", level = "error" })
      return
    end
    local seq = (state.opseq or 0) + 1
    local key = "op\0" .. seq
    state.opseq, state.opkey = seq, key
    local said = type(op.target) == "string" and op.target ~= "" and op.target or op.path
    state.oplabel = tostring(op.verb) .. " " .. said
    -- An hour, because this answer is a RECEIPT and not a reading: nothing asks
    -- for this key again, and a short ttl would only decide when the receipt
    -- stops being readable.
    run(key, program, { session = session, ttl = 3600 })
    invalidate()
  end,

  on_action = function(action)
    if action == "files.focus" then
      command("focus", { text = "files", toggle = true })
      warm_editor()
      return true
    end

    local session = selected_session()
    if not session then
      return false
    end

    if action == SELECT_TREE then
      state.tab = nil
      return true
    end
    if action == SELECT_CHANGES then
      state.tab = CHANGES_TAB
      return true
    end
    if action == "files.tab" then
      state.tab = tab_of() == CHANGES_TAB and nil or CHANGES_TAB
      return true
    end

    if action == FILE_MENU then
      -- The tree only: the changes tab lists paths that git decides, and a
      -- rename there would be a file operation aimed at a row that exists
      -- because of what it says about the file, not where it is.
      if tab_of() ~= TREE_TAB then
        return true
      end
      local cursor, rows = cursor_for(session)
      local item = rows and cursor:item()
      if not item then
        return true
      end
      store.filemenu = {
        session = session,
        path = item.path,
        name = item.name,
        dir = item.dir == true,
      }
      return true
    end

    if action == "files.reload" then
      -- The banner goes with the reload: `r` is the key that means "you are
      -- looking at something stale", and a failure still on screen after it
      -- would be exactly that.
      state.opkey, state.oplabel = nil, nil
      -- Including what this pane worked out about symlinks: `r` means "read it
      -- again", and a link that has since become an ordinary file is exactly
      -- the kind of stale this key is pressed about.
      linked = {}
      invalidate()
      -- `refresh` overrides freshness, which is the whole difference between
      -- this and the poll: the poll is asking, this is insisting.
      git_index(session, true)
      return true
    end

    -- The changes tab is a different list over a different set, so it answers
    -- the navigation keys itself rather than letting them move a tree cursor
    -- nobody is looking at.
    if tab_of() == CHANGES_TAB then
      local index = git_index(session)
      local cursor = change_cursor(index)
      if action == "files.next" or action == "files.previous" then
        cursor:move(action == "files.next" and 1 or -1)
        return true
      end
      local item = cursor:item()
      if not item then
        -- An empty list still swallows the key: a pane that acted on nothing
        -- would be indistinguishable from one that failed.
        return true
      end
      -- The same three keys the tree tab answers, over this tree. They were
      -- swallowed while this list was flat; now they have somewhere to go.
      if action == "files.expand" then
        if item.dir then
          shut_change_dir(item, false)
        end
        return true
      end
      if action == "files.collapse" then
        if item.dir and item.open then
          shut_change_dir(item, true)
        else
          -- Already shut, or a file: climb. The parent's id is derivable
          -- because a compressed row keeps the WHOLE path it stands for.
          local parent = parent_of(item.path)
          if parent ~= "" then
            cursor:select_by_id(item.section .. "\0/" .. parent)
          end
        end
        return true
      end
      if action == "files.toggle" then
        return activate_change(session, item)
      end
      return true
    end

    if action == "files.next" or action == "files.previous" then
      local cursor = cursor_for(session)
      cursor:move(action == "files.next" and 1 or -1)
      return true
    end

    local cursor = cursor_for(session)
    local item = cursor:item()
    if not item then
      -- An empty tree still swallows the key: a pane that acted on nothing
      -- would be indistinguishable from one that failed.
      return true
    end

    local open = expanded_set()

    if action == "files.expand" or (action == "files.toggle" and item.dir and not item.open) then
      if item.dir then
        open[item.path] = true
        set_expanded(open)
      end
      return true
    end

    if action == "files.collapse" then
      if item.dir and item.open then
        open[item.path] = nil
        set_expanded(open)
      else
        -- Already closed (or a file): climb. Selecting the parent by id is what
        -- makes `left` usable as "back out of here" at any depth.
        local parent = parent_of(item.path)
        if parent ~= "" then
          cursor:select_by_id(parent)
        end
      end
      return true
    end

    if action == "files.toggle" then
      return activate(session, item)
    end

    return false
  end,

  --- A click selects the row it landed on AND acts on it: a directory opens or
  --- closes, a file goes to the editor. One press, the thing a file tree does.
  ---
  --- `hit.id` is the row's path. It is there without this pane asking for it:
  --- `ui.list` takes a row's identity from the cursor when no `id_of` overrides
  --- it, and a row with an identity is given `role = "row"` — which is what
  --- makes it a target the kernel has no verb of its own for, so the hit
  --- arrives here (`thurbox.Hit`: "Reached only for identity the kernel has no
  --- verb for").
  on_click = function(hit)
    local session = selected_session()
    if not session or not hit.id then
      return false
    end
    warm_editor()
    if tab_of() == CHANGES_TAB then
      local cursor = change_cursor(git_index(session))
      if not cursor:select_by_id(hit.id) then
        return false
      end
      return activate_change(session, cursor:item(), true)
    end
    local cursor = cursor_for(session)
    if not cursor:select_by_id(hit.id) then
      return false
    end
    return activate(session, cursor:item(), true)
  end,

  --- A RIGHT press opens the context menu on the row it landed on.
  ---
  --- Its own hook, so a pane that has not been taught this never answers one —
  --- and so a right press cannot accidentally do what a left press does. It
  --- selects first, for the reason the menu needs it to: the menu acts on the
  --- row the cursor is standing on, and a press that opened a menu aimed at
  --- some other row would be this feature's first bug report.
  ---
  --- The tree only, the same restriction the `m` key has: the changes tab lists
  --- paths that git decided, and a rename there would be aimed at a row that
  --- exists because of what it says about the file, not where it is.
  on_context = function(hit)
    local session = selected_session()
    if not session or not hit.id or tab_of() ~= TREE_TAB then
      return false
    end
    local cursor = cursor_for(session)
    if not cursor:select_by_id(hit.id) then
      return false
    end
    local item = cursor:item()
    if not item then
      return false
    end
    store.filemenu = {
      session = session,
      path = item.path,
      name = item.name,
      dir = item.dir == true,
    }
    return true
  end,
}
