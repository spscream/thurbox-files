-- The file tree's context menu: the questions, and none of the answers.
--
-- This float draws the menu, takes the name you type and asks for a yes before
-- a delete. It does NOT touch the disk, and it holds no capability that could:
-- the chosen operation leaves here as a `user.fileop` event, and `90_files.lua`
-- — which already has `run` for git — is what carries it out. So the plugin
-- that draws a dialog cannot write a file, and the one that can write files has
-- no dialog to be tricked through. Splitting them costs one event and buys that.
--
-- It is a float for the reason `60_confirm.lua` is: only a plugin whose slot is
-- `float` may draw above the arrangement (`host::PluginIndex::build` collects
-- them into `floating`, and `draw_floats` paints exactly those). A pane that
-- occupies a column cannot pop anything over its neighbours, so a menu drawn by
-- the tree itself would have had to replace the tree.
--
-- The tree opens it by writing `store.filemenu`:
--
--   store.filemenu = {
--     session = "<session id>",
--     path    = "src/api/routes.rs",  -- relative to the session's directory
--     name    = "routes.rs",
--     dir     = false,
--   }
--
-- and the answer comes back as `user.fileop` with the same path plus a verb and
-- whatever was typed. The same shape as `user.openfile`: a REQUEST, addressed to
-- whoever knows how to do it, rather than a result.

local modal = require("lib.modal")
local textinput = require("lib.textinput")
local theme = require("lib.theme")
local widgets = require("lib.widgets")

local NAME = "filemenu"
local COLS = 52

--- The pending question, if the tree left one.
local function pending()
  local ask = store.filemenu
  if type(ask) ~= "table" or type(ask.path) ~= "string" or ask.path == "" then
    return nil
  end
  return ask
end

--- Everything this menu can do, in the order it offers them.
---
--- `prompt` makes an entry ask for text first; `confirm` makes it ask for a yes.
--- An entry with neither would act on `enter`, and none does — every one of
--- these either needs a name or cannot be undone.
---
--- The new file and the new folder land BESIDE the row when it is a file and
--- INSIDE it when it is a directory, which is what every tree does and what the
--- muted line under the title says out loud.
local function entries(ask)
  local name = ask.name or (ask.path:match("[^/]+$") or ask.path)
  return {
    { verb = "newfile", label = "New file…", prompt = "Name", prefill = "" },
    { verb = "newdir", label = "New folder…", prompt = "Name", prefill = "" },
    { verb = "rename", label = "Rename…", prompt = "New name", prefill = name },
    {
      verb = "duplicate",
      label = "Duplicate…",
      prompt = "Copy as",
      prefill = name .. " copy",
    },
    { verb = "move", label = "Move to…", prompt = "New path", prefill = ask.path },
    { verb = "delete", label = "Delete", confirm = true },
  }
end

local function picked(list)
  local at = state.pick
  if type(at) ~= "number" or at < 1 or at > #list then
    at = 1
  end
  return at, list[at]
end

--- Close, forgetting every half-finished step.
---
--- The question goes with them: a menu whose target is still in `store` would
--- reopen on the next frame, and one whose typed name outlived it would prefill
--- the next file's rename with the last one's.
local function close()
  store.filemenu = nil
  state.pick, state.step, state.field = nil, nil, nil
end

--- Send the chosen operation to the tree and close.
---
--- An EVENT and not a store key: the tree has a hook for one and would need a
--- reason to look at the other. `target` is always a string, empty for the verbs
--- that do not take one, because a payload field that is sometimes absent is a
--- field every reader has to test twice.
local function commit(ask, verb, target)
  command("emit", {
    text = "fileop",
    -- `sid`, not `session`: `session` is a NAMED field of the command's own
    -- argument struct (`kernel::command::Args`), so it is consumed there and
    -- never reaches the payload. A field the reader would always find nil.
    sid = ask.session,
    verb = verb,
    path = ask.path,
    dir = ask.dir == true,
    target = target or "",
  })
  close()
end

--- The path an entry would act on, spelled for the muted line under the title.
local function subject(ask, entry)
  if entry.verb == "newfile" or entry.verb == "newdir" then
    local into = ask.dir and ask.path or (ask.path:match("^(.*)/[^/]*$") or "")
    return "in " .. (into == "" and "the session's directory" or into .. "/")
  end
  return ask.path
end

return {
  name = NAME,

  -- A slot the arrangement never places: this only ever floats.
  slot = "float",
  order = 95,
  floats = true,

  -- Reads `store.filemenu`, `state` and the theme; every write is in `on_key`
  -- and `on_click`. The same bargain `60_confirm` takes, and for the same
  -- reason: a float renders every frame even while closed, so a render the
  -- kernel may not reuse would cost a Lua call per frame forever.
  pure = true,

  -- Never a tab stop: it is up only while it has a question, and it takes every
  -- key while it is.
  focusable = false,

  render = function(_)
    local ask = pending()
    if not ask then
      return { type = "text", text = "" }
    end

    local list = entries(ask)
    local at, entry = picked(list)
    local step = state.step
    local children = {}

    local function muted(text)
      children[#children + 1] = {
        type = "text",
        len = 1,
        text = { { { text = widgets.truncate(text, COLS - 4), style = { fg = theme.muted } } } },
      }
    end

    if step == "name" then
      local field = state.field or textinput.new(entry.prefill or "")
      muted(subject(ask, entry))
      children[#children + 1] = { type = "text", len = 1, text = "" }
      children[#children + 1] = textinput.node(field, {
        label = entry.prompt,
        focused = true,
      })
      children[#children + 1] = { type = "text", len = 1, text = "" }
      children[#children + 1] = modal.footer({}, "Apply", { cancel = "Back" })
      return modal.frame(entry.label:gsub("…$", ""), { cols = COLS, children = children })
    end

    if step == "confirm" then
      muted(ask.dir and "the folder and everything in it" or "this file")
      children[#children + 1] = { type = "text", len = 1, text = "" }
      children[#children + 1] = {
        type = "text",
        len = 1,
        text = {
          {
            { text = " " },
            {
              text = widgets.truncate(ask.path, COLS - 6),
              style = { fg = theme.bad, bold = true },
            },
          },
        },
      }
      children[#children + 1] = { type = "text", len = 1, text = "" }
      -- `rm` is `rm`: there is no trash to fish it out of, so the question says
      -- so rather than leaving it to be discovered.
      muted("deleted with rm — this cannot be undone")
      children[#children + 1] = modal.footer({ { "y", "delete" } }, "Delete", {
        cancel = "Back",
        style = { fg = theme.bad, bold = true },
      })
      return modal.frame("Delete", {
        cols = COLS,
        children = children,
        border = { fg = theme.bad },
      })
    end

    muted(ask.path .. (ask.dir and "/" or ""))
    children[#children + 1] = { type = "text", len = 1, text = "" }
    for index, item in ipairs(list) do
      local style = { fg = item.verb == "delete" and theme.bad or theme.text }
      if index == at then
        style = {
          fg = theme.role("selection_fg"),
          bg = theme.role("selection_bg"),
          bold = true,
        }
      end
      children[#children + 1] = {
        type = "text",
        len = 1,
        text = { { { text = " " .. item.label, style = style } } },
        -- An id makes the row a click target the kernel has no verb of its own
        -- for, which is what brings the hit to `on_click` below.
        id = item.verb,
        role = "row",
      }
    end
    children[#children + 1] = { type = "text", len = 1, text = "" }
    children[#children + 1] = modal.footer({ { "↑↓", "pick" } }, "Choose")
    return modal.frame("File", { cols = COLS, children = children })
  end,

  on_key = function(key)
    local ask = pending()
    if not ask then
      -- Closed: the keys belong to whatever is underneath.
      return false
    end
    local list = entries(ask)
    local at, entry = picked(list)
    local step = state.step

    if step == "name" then
      local field = state.field or textinput.new(entry.prefill or "")
      -- Offered to the field FIRST, and written back whole — `state` hands back
      -- a copy, so a field mutated in place and not stored is a keystroke lost.
      if textinput.key(field, key) then
        state.field = field
        return true
      end
      if key.key == "enter" then
        local target = (field.value or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if target == "" then
          -- Nothing typed is not a request. Swallowed rather than committed:
          -- an empty name would reach the tree as a path of its own.
          return true
        end
        commit(ask, entry.verb, target)
        return true
      end
      if key.key == "esc" then
        state.step, state.field = nil, nil
        return true
      end
      return true
    end

    if step == "confirm" then
      if key.key == "enter" or key.key == "y" then
        commit(ask, entry.verb, "")
        return true
      end
      if key.key == "esc" or key.key == "n" then
        state.step = nil
        return true
      end
      return true
    end

    if key.key == "esc" then
      close()
      return true
    end
    if key.key == "down" or key.key == "j" then
      state.pick = at % #list + 1
      return true
    end
    if key.key == "up" or key.key == "k" then
      state.pick = (at - 2) % #list + 1
      return true
    end
    if key.key == "enter" or key.key == "right" or key.key == "l" then
      state.pick = at
      if entry.confirm then
        state.step = "confirm"
      else
        state.step, state.field = "name", textinput.new(entry.prefill or "")
      end
      return true
    end
    -- Everything else is swallowed: a modal that let keys through to the pane
    -- underneath would be a modal in appearance only.
    return true
  end,

  --- A click on a row picks it AND opens it, the rule the tree itself follows:
  --- a row that only highlighted would read as a menu ignoring the mouse.
  on_click = function(hit)
    local ask = pending()
    if not ask then
      return false
    end
    if state.step or not hit.id then
      -- A click anywhere else on the float is swallowed so it cannot fall
      -- through to the pane beneath — the float's whole rect is a target.
      return true
    end
    local list = entries(ask)
    for index, item in ipairs(list) do
      if item.verb == hit.id then
        state.pick = index
        if item.confirm then
          state.step = "confirm"
        else
          state.step, state.field = "name", textinput.new(item.prefill or "")
        end
        return true
      end
    end
    return true
  end,
}
