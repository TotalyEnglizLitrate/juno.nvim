-- Public entry point. Wires the subsystems together, exposes the module API used
-- by plugin/juno.lua, and owns the notebook lifecycle (attach/detach/setup).
local core = require("juno.core")
local nbformat = require("juno.nbformat")
local render = require("juno.render")
local lsp = require("juno.lsp")
local persist = require("juno.persist")
local watch = require("juno.watch")
local cells = require("juno.cells")
local exec = require("juno.exec")

local M = {}

-- Backward-compatible state aliases (the canonical copies live in juno.core).
-- M.config is re-pointed at the merged table in setup().
M.config = core.config
M.buf_state = core.buf_state
M.ns_src = core.ns.src
M.ns_out = core.ns.out
M.ns_num = core.ns.num

-- LSP action wrappers: M.hover, M.definition, M.references, ...
for name, fn in pairs(lsp.actions) do
    M[name] = fn
end

-- Cell navigation + structural editing.
M.current_cell      = cells.current_cell
M.goto_cell         = cells.goto_cell
M.next_cell         = cells.next_cell
M.prev_cell         = cells.prev_cell
M.new_cell          = cells.new_cell
M.delete_cell       = cells.delete_cell
M.move_cell         = cells.move_cell
M.change_cell_type  = cells.change_cell_type
M.merge_cell        = cells.merge_cell
M.split_cell        = cells.split_cell
M.clear_outputs     = cells.clear_outputs
M.clear_all_outputs = cells.clear_all_outputs
M.yank_cell         = cells.yank_cell
M.paste_cell        = cells.paste_cell

-- Cell execution: run the current cell, or "all" to run every code cell.
M.run = exec.run
M.interrupt = exec.interrupt
M.pick_kernel = exec.pick_kernel

function M.attach(file_path)
    local buf = vim.api.nvim_get_current_buf()

    local content = vim.fn.filereadable(file_path) == 1 and vim.fn.readfile(file_path) or {}
    local text = table.concat(content, "\n")

    -- A missing or blank file is a new notebook: seed base data (one empty code
    -- cell) rather than erroring. Non-blank content that fails to parse is a real
    -- error and still surfaces as one.
    local data, seeded
    if text:match("^%s*$") then
        data = nbformat.new_notebook()
        seeded = true
    else
        local ok, decoded = pcall(vim.fn.json_decode, text)
        if not ok or type(decoded) ~= "table" then
            vim.notify("Juno: Invalid notebook file", vim.log.levels.ERROR)
            return
        end
        data = decoded
    end

    nbformat.normalize(data)

    vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

    watch.stop(core.buf_state[buf])  -- re-attach: drop any prior watcher
    core.buf_state[buf] = { file_path = file_path, data = data }
    render.render(buf, data)
    -- A seeded notebook has unsaved base content; a loaded one starts clean.
    vim.api.nvim_set_option_value("modified", seeded or false, { buf = buf })
    if seeded then
        vim.notify("Juno: new notebook (unsaved) — :w to create " .. file_path, vim.log.levels.INFO)
    end

    lsp.activate(buf, data)

    -- Scope the buffer-local autocmds to a per-buffer group cleared on each
    -- attach, so re-attaching (e.g. a :edit reload re-firing BufReadCmd) replaces
    -- them instead of stacking duplicate handlers.
    local group = vim.api.nvim_create_augroup("juno_buf_" .. buf, { clear = true })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        group = group,
        callback = function() persist.sync_and_save(buf) end,
    })

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        group = group,
        callback = function()
            watch.stop(core.buf_state[buf])
            core.buf_state[buf] = nil
        end,
    })

    if core.config.watch then
        watch.start(buf, file_path)
    end
end

function M.detach()
    local buf = vim.api.nvim_get_current_buf()
    local state = core.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end

    local raw_buf = vim.api.nvim_create_buf(true, true)
    local content = vim.fn.filereadable(state.file_path) == 1 and vim.fn.readfile(state.file_path) or {}
    vim.api.nvim_buf_set_lines(raw_buf, 0, -1, false, content)
    vim.api.nvim_set_option_value("filetype", "json", { buf = raw_buf })

    vim.api.nvim_set_current_buf(raw_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
end

function M.setup(user_config)
    -- Defaults; see the Configuration section of the README for what each does.
    core.config = vim.tbl_deep_extend("force", {
        otter = { enabled = true, completion = true, diagnostics = true },
        watch = true,
        execution = {
            enabled = true,
            kernel = nil,
            attach = nil,              -- wins over `kernel` when both are set
            kernel_map = { python = "python3" },
            prompt_for_kernel = true,
            allow_env_kernel = true,
            prefer_env_python = true,
            allow_attach = true,
        },
    }, user_config or {})
    M.config = core.config  -- keep the compat alias pointing at the merged config

    -- render-markdown.nvim is a hard dependency: notebooks are rendered into a
    -- Markdown buffer and rely on it for the display.
    if not pcall(require, "render-markdown") then
        vim.notify(
            "Juno: render-markdown.nvim is required but was not found. "
                .. "Install MeanderingProgrammer/render-markdown.nvim.",
            vim.log.levels.ERROR
        )
    end

    -- python3 is a hard dependency: saves are pretty-printed to canonical
    -- nbformat JSON via `python -m json.tool`, and cell execution runs a python
    -- sidecar. (Notebook normalization itself is pure Lua — see juno.nbformat.)
    if vim.fn.executable("python3") ~= 1 and vim.fn.executable("python") ~= 1 then
        vim.notify(
            "Juno: python3 is required but was not found on $PATH. "
                .. "Install python3 (or set vim.g.python3_host_prog).",
            vim.log.levels.ERROR
        )
    end

    local group = vim.api.nvim_create_augroup("juno", { clear = true })
    -- BufReadCmd handles existing files; BufNewFile handles opening a path that
    -- doesn't exist yet (a brand-new notebook), which attach() seeds with base data.
    vim.api.nvim_create_autocmd({ "BufReadCmd", "BufNewFile" }, {
        pattern = "*.ipynb",
        group = group,
        callback = function(ev) M.attach(ev.file) end,
    })

    render.apply_highlights()
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = render.apply_highlights })
end

return M
