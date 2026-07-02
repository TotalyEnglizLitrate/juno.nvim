local M = {}

M.config = {}
M.ns_src = vim.api.nvim_create_namespace("juno_src")
M.ns_out = vim.api.nvim_create_namespace("juno_out")
M.ns_num = vim.api.nvim_create_namespace("juno_num")
M.buf_state = {}

local uv = vim.uv or vim.loop
local nbformat = require("juno.nbformat")

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

-- The declared kernel language, or nil if the notebook doesn't specify one.
local function declared_language(data)
    local m = data.metadata
    return m and (
        (m.kernelspec and m.kernelspec.language) or
        (m.language_info and m.language_info.name)
    ) or nil
end

local function kernel_language(data)
    return declared_language(data) or "python"
end

-- Record a notebook-level kernel language into metadata so render()'s fences and
-- otter activation stay consistent. juno supports a single language per notebook.
local function set_declared_language(data, lang)
    data.metadata = data.metadata or {}
    data.metadata.language_info = data.metadata.language_info or {}
    data.metadata.language_info.name = lang
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
        local phantom_row = idx
        local start = idx + 1
        local src = clean_lines(get_cell_content(cell.source))
        local h

        table.insert(lines, "")  -- phantom line for cell number
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
        idx = idx + 1 + h + 1
        cell_pos[i] = { start = start, h = h, phantom = phantom_row }
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- Clear prior extmarks so render() is idempotent (it's re-run when cells
    -- are added). ns_out extmarks use auto-ids, so without this they'd stack up.
    vim.api.nvim_buf_clear_namespace(buf, M.ns_src, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, M.ns_out, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, M.ns_num, 0, -1)

    for i, cell in ipairs(data.cells or {}) do
        local pos = cell_pos[i]

        vim.api.nvim_buf_set_extmark(buf, M.ns_num, pos.phantom, 0, {
            id = i,
            virt_text = { { "[" .. i .. "]", "InlayHint" } },
            virt_text_pos = "overlay",
        })

        vim.api.nvim_buf_set_extmark(buf, M.ns_src, pos.start, 0, {
            end_row = pos.start + pos.h,
            id = i,
        })

        if cell.cell_type == "code" and cell.outputs and #cell.outputs > 0 then
            local vlines = {}
            for _, out in ipairs(cell.outputs) do
                vim.list_extend(vlines, output_to_virt_lines(out))
            end
            if #vlines > 0 then
                -- Anchor to the trailing spacer (a real blank line), not the
                -- closing ``` fence: markdown treesitter conceals fence lines
                -- with `conceal_lines`, which collapses the line and takes any
                -- attached virt_lines with it whenever conceallevel > 0.
                vim.api.nvim_buf_set_extmark(buf, M.ns_out, pos.start + pos.h, 0, {
                    virt_lines = vlines,
                    virt_lines_above = true,
                })
            end
        end
    end
end

-- Convert a list of plain lines into an nbformat `source` array: every line but
-- the last carries a trailing newline.
local function lines_to_source(lines)
    local source = {}
    for k, line in ipairs(lines) do
        source[k] = (k < #lines) and (line .. "\n") or line
    end
    return source
end

-- Pull the current buffer text back into state.data.cells[].source, stripping the
-- fences juno adds around code cells. Run before re-rendering so unsaved edits survive.
local function sync_buffer(buf)
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

            cell.source = lines_to_source(raw)
        end
    end
end

-- Find a usable python interpreter. Prefer the one on $PATH (the project's active
-- venv/nix-shell/devbox that nvim was launched in, which is where notebook packages
-- like nbformat live) over g:python3_host_prog, which is typically a dedicated
-- pynvim venv and often lacks project dependencies. Returns nil if none exist.
local function find_python()
    local candidates = { "python3", "python" }
    if vim.g.python3_host_prog and vim.g.python3_host_prog ~= "" then
        table.insert(candidates, vim.g.python3_host_prog)
    end
    for _, exe in ipairs(candidates) do
        if vim.fn.executable(exe) == 1 then return exe end
    end
    return nil
end

-- Pretty-print JSON via python's json.tool for Jupyter-compatible formatting.
-- Falls back to the (compact but valid) input if python is missing or errors,
-- warning the user that the notebook was saved without pretty formatting.
local warned_no_python = false
local function pretty_json(json_str)
    local python = find_python()
    if not python then
        if not warned_no_python then
            warned_no_python = true
            vim.notify(
                "Juno: no python interpreter found; saving notebook without pretty formatting. "
                    .. "Set vim.g.python3_host_prog or install python3 to enable it.",
                vim.log.levels.WARN
            )
        end
        return json_str
    end

    local pretty = vim.fn.system({ python, "-m", "json.tool" }, json_str)
    if vim.v.shell_error == 0 and pretty and #pretty > 0 then
        return pretty
    end

    vim.notify(
        "Juno: json.tool formatting failed; saved without pretty formatting."
            .. (pretty and #pretty > 0 and ("\n" .. vim.trim(pretty)) or ""),
        vim.log.levels.WARN
    )
    return json_str
end

local function mtime_eq(a, b)
    return a ~= nil and b ~= nil and a.sec == b.sec and a.nsec == b.nsec
end

-- Record the file's current mtime so the watcher can tell our own writes apart
-- from external changes. Call after every save.
local function stamp_disk_mtime(state)
    local st = uv.fs_stat(state.file_path)
    state.disk_mtime = st and st.mtime or nil
end

local function stop_watcher(state)
    if state and state.watcher then
        state.watcher:stop()
        if not state.watcher:is_closing() then state.watcher:close() end
        state.watcher = nil
    end
end

-- Re-read the notebook from disk into an already-attached buffer and re-render.
-- Unlike attach() this doesn't touch otter or autocmds; it just refreshes content
-- (render() is idempotent), so it's safe for a background buffer.
local function reload(buf)
    local state = M.buf_state[buf]
    if not state or not vim.api.nvim_buf_is_valid(buf) then return end

    local content = vim.fn.filereadable(state.file_path) == 1 and vim.fn.readfile(state.file_path) or {}
    local ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
    if not ok or type(data) ~= "table" then
        vim.notify("Juno: notebook changed on disk but is not valid JSON; not reloading.", vim.log.levels.WARN)
        return
    end

    nbformat.normalize(data)
    state.data = data
    render(buf, data)
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    stamp_disk_mtime(state)
    vim.notify("Juno: reloaded notebook from disk", vim.log.levels.INFO)
end

local function on_disk_change(buf, curr)
    local state = M.buf_state[buf]
    if not state or not vim.api.nvim_buf_is_valid(buf) then return end

    -- Ignore our own writes (and no-op stat changes): sync_and_save re-stamps
    -- disk_mtime after writing, so a matching mtime means nothing external changed.
    local st = curr or uv.fs_stat(state.file_path)
    if st and mtime_eq(st.mtime, state.disk_mtime) then return end

    -- Deferred: no 3-way merge yet, so don't clobber unsaved work.
    if vim.api.nvim_get_option_value("modified", { buf = buf }) then
        vim.notify(
            "Juno: notebook changed on disk but the buffer has unsaved edits; not reloading. "
                .. "Save (:w overwrites disk) or discard and :edit to reload.",
            vim.log.levels.WARN
        )
        -- Update the stamp so we don't nag again for this same on-disk version.
        state.disk_mtime = st and st.mtime or state.disk_mtime
        return
    end

    reload(buf)
end

local function start_watcher(buf, file_path)
    local state = M.buf_state[buf]
    if not state then return end
    stop_watcher(state)
    stamp_disk_mtime(state)

    local poll = uv.new_fs_poll()
    if not poll then return end
    state.watcher = poll
    -- fs_poll (stat-based) rather than fs_event so we survive atomic-rename
    -- writes (nbconvert/jupyter replace the file, which breaks inode watches).
    poll:start(file_path, 1000, function(err, _prev, curr)
        if err then return end
        vim.schedule(function() on_disk_change(buf, curr) end)
    end)
end

local function sync_and_save(buf)
    local state = M.buf_state[buf]
    if not state then return end

    sync_buffer(buf)

    local ok, json_str = pcall(vim.fn.json_encode, state.data)
    if not ok then
        vim.notify("Juno: JSON encode failed", vim.log.levels.ERROR)
        return
    end

    json_str = pretty_json(json_str)

    local f = io.open(state.file_path, "w")
    if not f then
        vim.notify("Juno: Cannot write to " .. state.file_path, vim.log.levels.ERROR)
        return
    end
    f:write(json_str)
    f:close()

    -- Record the mtime we just wrote so the file watcher doesn't treat our own
    -- save as an external change and reload over it.
    stamp_disk_mtime(state)

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

-- Place the cursor on the first editable line of the cell with the given data id.
local function focus_cell(buf, id)
    for _, pos in ipairs(cell_positions(buf)) do
        if pos.id == id then
            local cell = M.buf_state[buf].data.cells[id]
            local row = pos.start_row + (cell.cell_type == "code" and 1 or 0)
            vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
            return
        end
    end
end

-- Create a new cell. opts = { cell_type = "code"|"markdown", language = string, where = "below"|"above" }.
-- cell_type is prompted for when omitted; for code cells the language is a
-- notebook-level property (juno supports one language per notebook), so it's only
-- prompted for when the notebook doesn't already declare one.
function M.new_cell(opts)
    opts = opts or {}
    local buf = vim.api.nvim_get_current_buf()
    local state = M.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end

    sync_buffer(buf)

    local cells = state.data.cells or {}
    state.data.cells = cells

    -- Resolve insertion index (1-based) relative to the current cell.
    local current = M.current_cell(buf)
    local at
    if current then
        at = current.id + (opts.where == "above" and 0 or 1)
    else
        at = (opts.where == "above") and 1 or (#cells + 1)
    end

    local function insert(cell_type, lang)
        if lang then set_declared_language(state.data, lang) end
        local cell = nbformat.make_cell(cell_type, nbformat.gen_id(nbformat.taken_ids(cells)))
        table.insert(cells, at, cell)
        render(buf, state.data)
        vim.api.nvim_set_option_value("modified", true, { buf = buf })
        focus_cell(buf, at)
        vim.cmd("startinsert")

        -- Re-activate otter when we just established/changed the language so
        -- completion and diagnostics target it.
        if lang and M.config.otter.enabled then
            local ok, otter = pcall(require, "otter")
            if ok then
                otter.activate({ lang }, M.config.otter.completion, M.config.otter.diagnostics)
            end
        end
    end

    local function with_type(cell_type)
        if cell_type ~= "code" then
            insert(cell_type, nil)
        elseif opts.language then
            insert("code", opts.language)
        elseif declared_language(state.data) then
            insert("code", nil)
        else
            vim.ui.input({ prompt = "Cell language: ", default = "python" }, function(lang)
                if not lang or lang == "" then return end
                insert("code", lang)
            end)
        end
    end

    if opts.cell_type then
        with_type(opts.cell_type)
    else
        vim.ui.select({ "code", "markdown" }, { prompt = "New cell type:" }, function(choice)
            if choice then with_type(choice) end
        end)
    end
end

-- Reset a code cell's outputs (no-op for markdown/raw, which carry none).
local function clear_cell_outputs(cell)
    if cell.cell_type == "code" then
        cell.outputs = {}
        cell.execution_count = vim.NIL
    end
end

-- Run a structural edit on the cell under the cursor: syncs buffer edits into the
-- model, calls fn(cells, current, state) to mutate data.cells, then re-renders and
-- marks the buffer modified. fn returns the cell index to focus afterward (or nil).
local function edit_current_cell(fn)
    local buf = vim.api.nvim_get_current_buf()
    local state = M.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end
    sync_buffer(buf)
    local current = M.current_cell(buf)
    if not current then
        vim.notify("Juno: Cursor is not in a cell", vim.log.levels.WARN)
        return
    end
    local focus = fn(state.data.cells, current, state)
    render(buf, state.data)
    vim.api.nvim_set_option_value("modified", true, { buf = buf })
    if focus then focus_cell(buf, focus) end
end

-- Delete the cell under the cursor.
function M.delete_cell()
    edit_current_cell(function(cells, current)
        table.remove(cells, current.id)
        return math.min(current.id, #cells)
    end)
end

-- Move the current cell up (dir = -1) or down (dir = 1), swapping with its neighbor.
function M.move_cell(dir)
    edit_current_cell(function(cells, current)
        local i = current.id
        local j = i + dir
        if j < 1 or j > #cells then
            vim.notify("Juno: Cannot move cell further", vim.log.levels.WARN)
            return i
        end
        cells[i], cells[j] = cells[j], cells[i]
        return j
    end)
end

-- Change the current cell's type. new_type is "code" or "markdown"; nil toggles.
function M.change_cell_type(new_type)
    edit_current_cell(function(cells, current)
        local cell = cells[current.id]
        new_type = new_type or (cell.cell_type == "code" and "markdown" or "code")
        if cell.cell_type == new_type then return current.id end
        cell.cell_type = new_type
        if new_type == "code" then
            cell.outputs = {}
            cell.execution_count = vim.NIL
        else
            cell.outputs = nil
            cell.execution_count = nil
        end
        return current.id
    end)
end

-- Merge the current cell with a neighbor (dir = 1 below, dir = -1 above). The upper
-- cell survives, keeping its type; its outputs are cleared since the source changed.
function M.merge_cell(dir)
    dir = dir or 1
    edit_current_cell(function(cells, current)
        local upper = (dir < 0) and (current.id - 1) or current.id
        local lower = upper + 1
        if upper < 1 or lower > #cells then
            vim.notify("Juno: No adjacent cell to merge with", vim.log.levels.WARN)
            return current.id
        end
        local top = get_cell_content(cells[upper].source)
        if #top > 0 and top:sub(-1) ~= "\n" then top = top .. "\n" end
        local merged = top .. get_cell_content(cells[lower].source)
        cells[upper].source = lines_to_source(vim.split(merged, "\n"))
        clear_cell_outputs(cells[upper])
        table.remove(cells, lower)
        return upper
    end)
end

-- Split the current cell at the cursor line into two cells of the same type.
function M.split_cell()
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    edit_current_cell(function(cells, current)
        local cell = cells[current.id]
        local src = clean_lines(get_cell_content(cell.source))
        -- Buffer row of the cell's first source line (code cells open with a fence).
        local first = current.start_row + (cell.cell_type == "code" and 1 or 0)
        local at = math.max(0, math.min(cursor_row - first, #src))

        local top, bottom = {}, {}
        for k = 1, at do top[k] = src[k] end
        for k = at + 1, #src do bottom[#bottom + 1] = src[k] end

        cell.source = lines_to_source(top)
        clear_cell_outputs(cell)

        local new_cell = nbformat.make_cell(cell.cell_type, nbformat.gen_id(nbformat.taken_ids(cells)))
        new_cell.source = lines_to_source(bottom)
        table.insert(cells, current.id + 1, new_cell)
        return current.id + 1
    end)
end

-- Clear outputs of the current cell.
function M.clear_outputs()
    edit_current_cell(function(cells, current)
        clear_cell_outputs(cells[current.id])
        return current.id
    end)
end

-- Clear outputs of every cell in the notebook.
function M.clear_all_outputs()
    local buf = vim.api.nvim_get_current_buf()
    local state = M.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end
    sync_buffer(buf)
    for _, cell in ipairs(state.data.cells) do
        clear_cell_outputs(cell)
    end
    render(buf, state.data)
    vim.api.nvim_set_option_value("modified", true, { buf = buf })
end

-- Copy the current cell into juno's cell clipboard (separate from vim registers).
function M.yank_cell()
    local buf = vim.api.nvim_get_current_buf()
    local state = M.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end
    sync_buffer(buf)
    local current = M.current_cell(buf)
    if not current then
        vim.notify("Juno: Cursor is not in a cell", vim.log.levels.WARN)
        return
    end
    M.cell_clipboard = vim.deepcopy(state.data.cells[current.id])
    vim.notify("Juno: cell yanked", vim.log.levels.INFO)
end

-- Paste the yanked cell below (default) or above the current cell. Between cells
-- (or in an empty notebook) it appends/prepends. The paste gets a fresh id.
function M.paste_cell(where)
    if not M.cell_clipboard then
        vim.notify("Juno: no yanked cell", vim.log.levels.WARN)
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    local state = M.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end
    sync_buffer(buf)
    local cells = state.data.cells
    local current = M.current_cell(buf)
    local at
    if current then
        at = current.id + (where == "above" and 0 or 1)
    else
        at = (where == "above") and 1 or (#cells + 1)
    end

    local cell = vim.deepcopy(M.cell_clipboard)
    cell.id = nbformat.gen_id(nbformat.taken_ids(cells))
    -- deepcopy can drop the empty-dict marker; keep metadata a JSON object.
    if type(cell.metadata) ~= "table" or vim.tbl_isempty(cell.metadata) then
        cell.metadata = vim.empty_dict()
    end
    table.insert(cells, at, cell)
    render(buf, state.data)
    vim.api.nvim_set_option_value("modified", true, { buf = buf })
    focus_cell(buf, at)
end

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

    stop_watcher(M.buf_state[buf])  -- re-attach: drop any prior watcher
    M.buf_state[buf] = { file_path = file_path, data = data }
    render(buf, data)
    -- A seeded notebook has unsaved base content; a loaded one starts clean.
    vim.api.nvim_set_option_value("modified", seeded or false, { buf = buf })
    if seeded then
        vim.notify("Juno: new notebook (unsaved) — :w to create " .. file_path, vim.log.levels.INFO)
    end

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
        else
            vim.notify(
                "Juno: otter.nvim not found; LSP features (hover, definition, "
                    .. "references, rename, format, completion, diagnostics) are unavailable.",
                vim.log.levels.ERROR
            )
        end
    end

    -- Scope the buffer-local autocmds to a per-buffer group cleared on each
    -- attach, so re-attaching (e.g. a :edit reload re-firing BufReadCmd) replaces
    -- them instead of stacking duplicate handlers.
    local group = vim.api.nvim_create_augroup("juno_buf_" .. buf, { clear = true })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        group = group,
        callback = function() sync_and_save(buf) end,
    })

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        group = group,
        callback = function()
            stop_watcher(M.buf_state[buf])
            M.buf_state[buf] = nil
        end,
    })

    if M.config.watch then
        start_watcher(buf, file_path)
    end
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
        -- Poll the notebook file and reload it when it changes on disk (e.g. after
        -- `jupyter run`). Set to false to disable.
        watch = true,
    }, user_config or {})

    local group = vim.api.nvim_create_augroup("juno", { clear = true })
    -- BufReadCmd handles existing files; BufNewFile handles opening a path that
    -- doesn't exist yet (a brand-new notebook), which attach() seeds with base data.
    vim.api.nvim_create_autocmd({ "BufReadCmd", "BufNewFile" }, {
        pattern = "*.ipynb",
        group = group,
        callback = function(ev) M.attach(ev.file) end,
    })
end

return M
