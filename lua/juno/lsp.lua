-- otter.nvim integration: expose thin LSP action wrappers, route standard
-- vim.lsp.buf_request calls from notebook buffers through otter, relay LspAttach,
-- and activate otter for a notebook's language.
local core = require("juno.core")
local nbformat = require("juno.nbformat")

local lsp = {}

-- Public LSP action wrappers (exposed on the juno module as M.hover, M.definition,
-- ...), so callers don't import otter directly.
local lsp_actions = {
    hover            = "ask_hover",
    definition       = "ask_definition",
    type_definition  = "ask_type_definition",
    references       = "ask_references",
    rename           = "ask_rename",
    format           = "ask_format",
    document_symbols = "ask_document_symbols",
}

lsp.actions = {}
for name, otter_fn in pairs(lsp_actions) do
    lsp.actions[name] = function()
        local ok, otter = pcall(require, "otter")
        if ok then otter[otter_fn]() end
    end
end

-- LSP method -> otter function name, used by the buf_request patch.
local method_to_otter = {
    ["textDocument/hover"]          = "ask_hover",
    ["textDocument/definition"]     = "ask_definition",
    ["textDocument/typeDefinition"] = "ask_type_definition",
    ["textDocument/references"]     = "ask_references",
    ["textDocument/rename"]         = "ask_rename",
    ["textDocument/formatting"]     = "ask_format",
    ["textDocument/documentSymbol"] = "ask_document_symbols",
}

-- Installed once: routes vim.lsp.buf_request calls from notebook buffers through
-- otter, so standard vim.lsp.buf.hover / gd / etc. work without any user keymap config.
local lsp_patched = false
function lsp.patch()
    if lsp_patched then return end
    lsp_patched = true
    local orig = vim.lsp.buf_request
    vim.lsp.buf_request = function(bufnr, method, params, handler)
        local b = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
        if core.buf_state[b] then
            local fn = method_to_otter[method]
            if fn then
                local ok, otter = pcall(require, "otter")
                if ok then otter[fn]() end
                return {}, function() end
            end
        end
        return orig(bufnr, method, params, handler)
    end
end

-- After otter creates its shadow buffer and a real LSP client attaches to it,
-- relay LspAttach to the notebook buffer with that client's ID so the user's
-- on_attach / LspAttach handler runs and sets up keymaps as usual.
local function relay_attach(notebook_buf, shadow_buf)
    vim.api.nvim_create_autocmd("LspAttach", {
        buffer = shadow_buf,
        once = true,
        callback = function(ev)
            if not vim.api.nvim_buf_is_valid(notebook_buf) then return end
            vim.api.nvim_exec_autocmds("LspAttach", {
                buffer = notebook_buf,
                data = { client_id = ev.data.client_id },
            })
        end,
    })
end

-- Full otter activation for a freshly attached notebook buffer.
function lsp.activate(buf, data)
    if not core.config.otter.enabled then return end
    local ok, otter = pcall(require, "otter")
    if not ok then
        vim.notify(
            "Juno: otter.nvim not found; LSP features (hover, definition, "
                .. "references, rename, format, completion, diagnostics) are unavailable.",
            vim.log.levels.ERROR
        )
        return
    end
    local cfg = core.config.otter
    local lang = nbformat.kernel_language(data)
    otter.activate({ lang }, cfg.completion, cfg.diagnostics)
    lsp.patch()

    -- otter.keeper stores shadow buffer state keyed by [notebook_buf][lang]
    local keeper_ok, keeper = pcall(require, "otter.keeper")
    if keeper_ok then
        local lang_state = keeper.otters_attached
            and keeper.otters_attached[buf]
            and keeper.otters_attached[buf][lang]
        if lang_state and lang_state.bufnr then
            relay_attach(buf, lang_state.bufnr)
        end
    end
end

-- Re-activate otter for a (possibly newly established) language, e.g. after
-- creating the first code cell in a notebook that declared no language.
function lsp.reactivate(lang)
    if not core.config.otter.enabled then return end
    local ok, otter = pcall(require, "otter")
    if ok then
        otter.activate({ lang }, core.config.otter.completion, core.config.otter.diagnostics)
    end
end

return lsp
