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
    if #args == 2 then
      return vim.tbl_filter(function(item)
        return vim.startswith(item, ArgLead)
      end, { "attach", "detach", "next", "prev", "goto", "new" })
    end
    if #args == 3 and args[2] == "new" then
      return vim.tbl_filter(function(item)
        return vim.startswith(item, ArgLead)
      end, { "code", "markdown" })
    end
    return {}
  end,
})
