    -- The file column, LAST so it sits against the right edge with the agent
    -- between it and the session list. Gated on `filled` so a slot no plugin
    -- can fill does not reserve a rect for nothing.
    if filled(ctx, "files") then
      columns[#columns + 1] = { slot = "files", pct = 22, min = 18 }
    end
