if vim.g.loaded_juno == 1 then
  return
end
vim.g.loaded_juno = 1

vim.api.nvim_create_user_command("Juno", function(opts)
  local sub = opts.fargs[1]

  if sub == "attach" then
    require("juno").attach(opts.fargs[2])
  elseif sub == "detach" then
    require("juno").detach()
  elseif sub == "next" then
    require("juno").next_cell()
  elseif sub == "prev" then
    require("juno").prev_cell()
  elseif sub == "new" then
    require("juno").new_cell({ cell_type = opts.fargs[2] })
  elseif sub == "delete" then
    require("juno").delete_cell()
  elseif sub == "move" then
    require("juno").move_cell(opts.fargs[2] == "up" and -1 or 1)
  elseif sub == "type" then
    require("juno").change_cell_type(opts.fargs[2])
  elseif sub == "merge" then
    require("juno").merge_cell(opts.fargs[2] == "up" and -1 or 1)
  elseif sub == "split" then
    require("juno").split_cell()
  elseif sub == "clear" then
    if opts.fargs[2] == "all" then
      require("juno").clear_all_outputs()
    else
      require("juno").clear_outputs()
    end
  elseif sub == "yank" then
    require("juno").yank_cell()
  elseif sub == "paste" then
    require("juno").paste_cell(opts.fargs[2])
  elseif sub == "run" then
    require("juno").run(opts.fargs[2])
  elseif sub == "goto" then
    local n = tonumber(opts.fargs[2])
    if n then
      require("juno").goto_cell(n)
    else
      vim.notify("Juno: goto requires a cell number", vim.log.levels.ERROR)
    end
  else
    vim.notify("Juno: Unknown subcommand: " .. (sub or ""), vim.log.levels.ERROR)
  end
end, {
  nargs = "+",
  complete = function(ArgLead, CmdLine, CursorPos)
    local args = vim.split(CmdLine, "%s+")
    local function filter(items)
      return vim.tbl_filter(function(item)
        return vim.startswith(item, ArgLead)
      end, items)
    end
    if #args == 2 then
      return filter({
        "attach", "detach", "next", "prev", "goto", "new",
        "delete", "move", "type", "merge", "split", "clear", "yank", "paste", "run",
      })
    end
    if #args == 3 then
      local second = ({
        new = { "code", "markdown", "raw" },
        type = { "code", "markdown", "raw" },
        move = { "up", "down" },
        merge = { "up", "down" },
        clear = { "all" },
        paste = { "above", "below" },
        run = { "all" },
      })[args[2]]
      if second then return filter(second) end
    end
    return {}
  end,
})
