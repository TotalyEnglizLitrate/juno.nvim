local M = {}

M.config = {}
M.ns_src = vim.api.nvim_create_namespace("juno_src")
M.ns_out = vim.api.nvim_create_namespace("juno_out")
M.buf_state = {}

-- Public API: thin wrappers around otter so callers don't import otter directly.
local lsp_actions = {
    hover            = "ask_hover",
    definition       = "ask_definition",
    type_definition  = "ask_type_definition",
    references       = "ask_references",
    rename           = "ask_rename",
    format           = "ask_format",
    document_symbols = "ask_document_symbols",
}

for name, otter_fn in pairs(lsp_actions) do
    M[name] = function()
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

-- Installed once: routes vim.lsp.buf_request calls from notebook buffers through otter,
-- so standard vim.lsp.buf.hover / gd / etc. work without any user keymap config.
local lsp_patched = false
local function patch_lsp()
    if lsp_patched then return end
    lsp_patched = true
    local orig = vim.lsp.buf_request
    vim.lsp.buf_request = function(bufnr, method, params, handler)
        local b = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
        if M.buf_state[b] then
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
local function relay_lsp_attach(notebook_buf, shadow_buf)
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

local function get_cell_content(source)
    if type(source) == "table" then
        return table.concat(source, "")
    end
    return source or ""
end

local function clean_lines(text)
    if text:sub(-1) == "\n" then
        text = text:sub(1, -2)
    end
    return vim.split(text, "\n")
end

local function kernel_language(data)
    local m = data.metadata
    return (m and (
        (m.kernelspec and m.kernelspec.language) or
        (m.language_info and m.language_info.name)
    )) or "python"
end

local function output_to_virt_lines(output)
    local vlines = {}
    if output.output_type == "stream" then
        for _, line in ipairs(clean_lines(get_cell_content(output.text))) do
            table.insert(vlines, { { line, "Comment" } })
        end
    elseif output.output_type == "execute_result" and output.data and output.data["text/plain"] then
        for _, line in ipairs(clean_lines(get_cell_content(output.data["text/plain"]))) do
            table.insert(vlines, { { line, "String" } })
        end
    elseif output.output_type == "error" then
        table.insert(vlines, { { "Error: " .. (output.evalue or "unknown"), "ErrorMsg" } })
        for _, tb in ipairs(output.traceback or {}) do
            table.insert(vlines, { { tb:gsub("\27%[[%d;]*m", ""), "ErrorMsg" } })
        end
    end
    return vlines
end

-- Returns cell positions from ns_src extmarks, sorted by start row.
-- Each entry: { id, start_row, end_row }
local function cell_positions(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, M.ns_src, 0, -1, { details = true })
    local positions = {}
    for _, mark in ipairs(marks) do
        -- mark = { id, start_row, start_col, details }
        table.insert(positions, {
            id = mark[1],
            start_row = mark[2],
            end_row = mark[4].end_row,
        })
    end
    return positions
end

local function render(buf, data)
    local lang = kernel_language(data)
    local lines = {}
    local cell_pos = {}
    local idx = 0

    for i, cell in ipairs(data.cells or {}) do
        local start = idx
        local src = clean_lines(get_cell_content(cell.source))
        local h

        if cell.cell_type == "markdown" then
            vim.list_extend(lines, src)
            h = #src
        else
            table.insert(lines, "```" .. lang)
            vim.list_extend(lines, src)
            table.insert(lines, "```")
            h = #src + 2
        end

        table.insert(lines, "")
        idx = idx + h + 1
        cell_pos[i] = { start = start, h = h }
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    for i, cell in ipairs(data.cells or {}) do
        local pos = cell_pos[i]
        local label = (cell.cell_type == "markdown") and " [md]" or (" [" .. lang .. "]")

        vim.api.nvim_buf_set_extmark(buf, M.ns_src, pos.start, 0, {
            end_row = pos.start + pos.h,
            id = i,
            virt_text = { { label, "NonText" } },
            virt_text_pos = "eol",
        })

        if cell.cell_type == "code" and cell.outputs and #cell.outputs > 0 then
            local vlines = {}
            for _, out in ipairs(cell.outputs) do
                vim.list_extend(vlines, output_to_virt_lines(out))
            end
            if #vlines > 0 then
                vim.api.nvim_buf_set_extmark(buf, M.ns_out, pos.start + pos.h - 1, 0, {
                    virt_lines = vlines,
                })
            end
        end
    end
end

local function sync_and_save(buf)
    local state = M.buf_state[buf]
    if not state then return end

    for i, cell in ipairs(state.data.cells or {}) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns_src, i, { details = true })
        if mark and #mark > 0 then
            local start_row = mark[1]
            local end_row = mark[3].end_row
            local raw = vim.api.nvim_buf_get_lines(buf, start_row, end_row, false)

            if cell.cell_type == "code" then
                if #raw >= 1 and raw[1]:match("^```") then table.remove(raw, 1) end
                if #raw >= 1 and raw[#raw]:match("^```") then table.remove(raw) end
            end

            local source = {}
            for k, line in ipairs(raw) do
                source[k] = (k < #raw) and (line .. "\n") or line
            end
            cell.source = source
        end
    end

    local ok, json_str = pcall(vim.fn.json_encode, state.data)
    if not ok then
        vim.notify("Juno: JSON encode failed", vim.log.levels.ERROR)
        return
    end

    local python = (vim.g.python3_host_prog and vim.g.python3_host_prog ~= "") and vim.g.python3_host_prog or "python3"
    local pretty = vim.fn.system({ python, "-m", "json.tool" }, json_str)
    if vim.v.shell_error == 0 and pretty and #pretty > 0 then
        json_str = pretty
    end

    local f = io.open(state.file_path, "w")
    if not f then
        vim.notify("Juno: Cannot write to " .. state.file_path, vim.log.levels.ERROR)
        return
    end
    f:write(json_str)
    f:close()

    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.notify("Juno: Notebook saved", vim.log.levels.INFO)
end

-- Returns info about the cell the cursor is currently in, or nil if between cells.
-- { idx, id, type, start_row, end_row }
function M.current_cell(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    if not M.buf_state[buf] then return nil end
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local positions = cell_positions(buf)
    for list_idx, pos in ipairs(positions) do
        if cursor_row >= pos.start_row and cursor_row < pos.end_row then
            local cell = M.buf_state[buf].data.cells[pos.id]
            return { idx = list_idx, id = pos.id, type = cell.cell_type, start_row = pos.start_row, end_row = pos.end_row }
        end
    end
    return nil
end

-- Jump to the nth cell (1-indexed).
function M.goto_cell(n)
    local buf = vim.api.nvim_get_current_buf()
    if not M.buf_state[buf] then return end
    local pos = cell_positions(buf)[n]
    if pos then
        vim.api.nvim_win_set_cursor(0, { pos.start_row + 1, 0 })
    else
        vim.notify("Juno: No cell " .. n, vim.log.levels.WARN)
    end
end

function M.next_cell()
    local buf = vim.api.nvim_get_current_buf()
    if not M.buf_state[buf] then return end
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local positions = cell_positions(buf)

    for list_idx, pos in ipairs(positions) do
        if cursor_row >= pos.start_row and cursor_row < pos.end_row then
            local next_pos = positions[list_idx + 1]
            if next_pos then vim.api.nvim_win_set_cursor(0, { next_pos.start_row + 1, 0 }) end
            return
        end
    end

    -- Cursor is in a spacer; jump to the next cell start after cursor.
    for _, pos in ipairs(positions) do
        if pos.start_row > cursor_row then
            vim.api.nvim_win_set_cursor(0, { pos.start_row + 1, 0 })
            return
        end
    end
end

function M.prev_cell()
    local buf = vim.api.nvim_get_current_buf()
    if not M.buf_state[buf] then return end
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local positions = cell_positions(buf)

    for list_idx, pos in ipairs(positions) do
        if cursor_row >= pos.start_row and cursor_row < pos.end_row then
            local prev_pos = positions[list_idx - 1]
            if prev_pos then vim.api.nvim_win_set_cursor(0, { prev_pos.start_row + 1, 0 }) end
            return
        end
    end

    -- Cursor is in a spacer; jump to the last cell start before cursor.
    local prev_pos = nil
    for _, pos in ipairs(positions) do
        if pos.start_row < cursor_row then prev_pos = pos else break end
    end
    if prev_pos then vim.api.nvim_win_set_cursor(0, { prev_pos.start_row + 1, 0 }) end
end

function M.attach(file_path)
    local buf = vim.api.nvim_get_current_buf()

    local content = vim.fn.filereadable(file_path) == 1 and vim.fn.readfile(file_path) or {}
    local ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
    if not ok or type(data) ~= "table" then
        vim.notify("Juno: Invalid notebook file", vim.log.levels.ERROR)
        return
    end

    vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

    M.buf_state[buf] = { file_path = file_path, data = data }
    render(buf, data)
    vim.api.nvim_set_option_value("modified", false, { buf = buf })

    if M.config.otter.enabled then
        local otter_ok, otter = pcall(require, "otter")
        if otter_ok then
            local cfg = M.config.otter
            local lang = kernel_language(data)
            otter.activate({ lang }, cfg.completion, cfg.diagnostics)
            patch_lsp()

            -- otter.keeper stores shadow buffer state keyed by [notebook_buf][lang]
            local keeper_ok, keeper = pcall(require, "otter.keeper")
            if keeper_ok then
                local lang_state = keeper.otters_attached
                    and keeper.otters_attached[buf]
                    and keeper.otters_attached[buf][lang]
                if lang_state and lang_state.bufnr then
                    relay_lsp_attach(buf, lang_state.bufnr)
                end
            end
        end
    end

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function() sync_and_save(buf) end,
    })

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        callback = function() M.buf_state[buf] = nil end,
    })
end

function M.detach()
    local buf = vim.api.nvim_get_current_buf()
    local state = M.buf_state[buf]
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
    M.config = vim.tbl_deep_extend("force", {
        otter = { enabled = true, completion = true, diagnostics = true },
    }, user_config or {})

    local group = vim.api.nvim_create_augroup("juno", { clear = true })
    vim.api.nvim_create_autocmd("BufReadCmd", {
        pattern = "*.ipynb",
        group = group,
        callback = function(ev) M.attach(ev.file) end,
    })
end

return M
