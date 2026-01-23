if vim.g.loaded_juno == 1 then
  return
end
vim.g.loaded_juno = 1

vim.api.nvim_create_user_command("JunoAttach", function()
  require("juno").attach()
end, {})
