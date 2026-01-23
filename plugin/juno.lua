if vim.g.loaded_juno == 1 then
  return
end
vim.g.loaded_juno = 1

vim.api.nvim_create_user_command("Juno", function(opts)
  local subcommand = opts.fargs[1]
  
  if subcommand == "attach" then
    require("juno").attach(opts.fargs[2])
  elseif subcommand == "detach" then
    require("juno").detach()
  else
    vim.notify("Juno: Unknown subcommand: " .. subcommand, vim.log.levels.ERROR)
  end
end, {
  nargs = "+",
  complete = function(ArgLead, CmdLine, CursorPos)
    local subcommands = {"attach", "detach"}
    return vim.tbl_filter(function(item)
      return vim.startswith(item, ArgLead)
    end, subcommands)
  end,
})