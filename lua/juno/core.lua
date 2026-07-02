-- Shared mutable state for the juno subsystems. Every other module requires this
-- and reads config/buf_state/ns through it, so there is a single source of truth.
--
-- Note: setup() reassigns core.config to the merged table. Modules must therefore
-- read `core.config.<key>` at call time (indexing the core table), never cache
-- `local cfg = core.config` at load time, or they would capture the pre-setup {}.
local core = {}

-- Populated by juno.setup(); {} until then.
core.config = {}

-- Notebook buffers keyed by bufnr: { file_path, data, watcher, disk_mtime }.
core.buf_state = {}

-- Extmark namespaces: source regions, outputs, and cell-number inlay hints.
core.ns = {
    src = vim.api.nvim_create_namespace("juno_src"),
    out = vim.api.nvim_create_namespace("juno_out"),
    num = vim.api.nvim_create_namespace("juno_num"),
}

return core
