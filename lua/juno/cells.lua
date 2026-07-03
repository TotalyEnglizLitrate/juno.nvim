-- Cell navigation and structural editing: locate the cell under the cursor, jump
-- between cells, and create/delete/move/change-type/merge/split/clear/yank/paste.
-- Structural edits sync buffer text into the model, mutate data.cells, and re-render.
local core = require("juno.core")
local util = require("juno.util")
local render = require("juno.render")
local persist = require("juno.persist")
local nbformat = require("juno.nbformat")
local lsp = require("juno.lsp")

local cells = {}

local VALID_CELL_TYPES = { code = true, markdown = true, raw = true }

-- Juno's cell clipboard (separate from vim registers), shared across notebooks.
local clipboard = nil

-- Returns info about the cell the cursor is currently in, or nil if between cells.
-- `id` is the stable nbformat cell id (the tracking identity); `idx` is its
-- current 1-based position in data.cells (for list manipulation only).
-- { idx, id, type, start_row, end_row }
function cells.current_cell(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local state = core.buf_state[buf]
    if not state then return nil end
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local positions = render.cell_positions(buf)
    for list_idx, pos in ipairs(positions) do
        if cursor_row >= pos.start_row and cursor_row < pos.end_row then
            local cell = state.data.cells[list_idx]
            return { idx = list_idx, id = cell.id, type = cell.cell_type, start_row = pos.start_row, end_row = pos.end_row }
        end
    end
    return nil
end

-- The stable nbformat id of the cell at 1-based position n (its cell number),
-- or nil. Bridges a displayed cell number to the tracking identity.
function cells.id_at(buf, n)
    local state = core.buf_state[buf]
    local cell = state and state.data.cells[n]
    return cell and cell.id or nil
end

-- The 1-based position of the cell with the given nbformat id, or nil. The
-- inverse of id_at, for turning a tracked identity back into a list index.
function cells.index_of(buf, id)
    local state = core.buf_state[buf]
    return state and nbformat.index_by_id(state.data.cells, id) or nil
end

-- Jump to the nth cell (1-indexed).
function cells.goto_cell(n)
    local buf = vim.api.nvim_get_current_buf()
    if not core.buf_state[buf] then return end
    local pos = render.cell_positions(buf)[n]
    if pos then
        vim.api.nvim_win_set_cursor(0, { pos.start_row + 1, 0 })
    else
        vim.notify("Juno: No cell " .. n, vim.log.levels.WARN)
    end
end

function cells.next_cell()
    local buf = vim.api.nvim_get_current_buf()
    if not core.buf_state[buf] then return end
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local positions = render.cell_positions(buf)

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

function cells.prev_cell()
    local buf = vim.api.nvim_get_current_buf()
    if not core.buf_state[buf] then return end
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local positions = render.cell_positions(buf)

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

-- Place the cursor on the first editable line of the cell with the given
-- nbformat id.
local function focus_cell(buf, id)
    for list_idx, pos in ipairs(render.cell_positions(buf)) do
        if pos.id == id then
            local cell = core.buf_state[buf].data.cells[list_idx]
            local row = pos.start_row + (cell.cell_type == "code" and 1 or 0)
            vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
            return
        end
    end
end

-- Create a new cell. opts = { cell_type = "code"|"markdown"|"raw", language = string, where = "below"|"above" }.
-- cell_type is prompted for when omitted; for code cells the language is a
-- notebook-level property (juno supports one language per notebook), so it's only
-- prompted for when the notebook doesn't already declare one.
function cells.new_cell(opts)
    opts = opts or {}
    if opts.cell_type ~= nil and not VALID_CELL_TYPES[opts.cell_type] then
        vim.notify("Juno: invalid cell type: " .. tostring(opts.cell_type), vim.log.levels.ERROR)
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    local state = core.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end

    persist.sync_buffer(buf)

    local list = state.data.cells or {}
    state.data.cells = list

    -- Resolve insertion index (1-based) relative to the current cell.
    local current = cells.current_cell(buf)
    local at
    if current then
        at = current.idx + (opts.where == "above" and 0 or 1)
    else
        at = (opts.where == "above") and 1 or (#list + 1)
    end

    local function insert(cell_type, lang)
        if lang then nbformat.set_declared_language(state.data, lang) end
        local cell = nbformat.make_cell(cell_type, nbformat.gen_id(nbformat.taken_ids(list)))
        table.insert(list, at, cell)
        render.render(buf, state.data)
        vim.api.nvim_set_option_value("modified", true, { buf = buf })
        focus_cell(buf, cell.id)
        vim.cmd("startinsert")

        -- Re-activate otter when we just established/changed the language so
        -- completion and diagnostics target it.
        if lang then lsp.reactivate(lang) end
    end

    local function with_type(cell_type)
        if cell_type ~= "code" then
            insert(cell_type, nil)
        elseif opts.language then
            insert("code", opts.language)
        elseif nbformat.declared_language(state.data) then
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
        vim.ui.select({ "code", "markdown", "raw" }, { prompt = "New cell type:" }, function(choice)
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
-- marks the buffer modified. fn returns the nbformat id of the cell to focus
-- afterward (or nil). `current.idx` is the position; `current.id` the identity.
local function edit_current_cell(fn)
    local buf = vim.api.nvim_get_current_buf()
    local state = core.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end
    persist.sync_buffer(buf)
    local current = cells.current_cell(buf)
    if not current then
        vim.notify("Juno: Cursor is not in a cell", vim.log.levels.WARN)
        return
    end
    local focus = fn(state.data.cells, current, state)
    render.render(buf, state.data)
    vim.api.nvim_set_option_value("modified", true, { buf = buf })
    if focus then focus_cell(buf, focus) end
end

-- Delete the cell under the cursor.
function cells.delete_cell()
    edit_current_cell(function(list, current)
        table.remove(list, current.idx)
        local focus = math.min(current.idx, #list)
        return list[focus] and list[focus].id or nil
    end)
end

-- Move the current cell up (dir = -1) or down (dir = 1), swapping with its neighbor.
function cells.move_cell(dir)
    edit_current_cell(function(list, current)
        local i = current.idx
        local j = i + dir
        if j < 1 or j > #list then
            vim.notify("Juno: Cannot move cell further", vim.log.levels.WARN)
            return current.id
        end
        list[i], list[j] = list[j], list[i]
        return current.id  -- the moved cell (now at j) keeps its identity
    end)
end

-- Change the current cell's type ("code", "markdown", or "raw"); nil toggles
-- between code and markdown.
function cells.change_cell_type(new_type)
    if new_type ~= nil and not VALID_CELL_TYPES[new_type] then
        vim.notify("Juno: invalid cell type: " .. tostring(new_type), vim.log.levels.ERROR)
        return
    end
    edit_current_cell(function(list, current)
        local cell = list[current.idx]
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
function cells.merge_cell(dir)
    dir = dir or 1
    edit_current_cell(function(list, current)
        local upper = (dir < 0) and (current.idx - 1) or current.idx
        local lower = upper + 1
        if upper < 1 or lower > #list then
            vim.notify("Juno: No adjacent cell to merge with", vim.log.levels.WARN)
            return current.id
        end
        local top = util.get_cell_content(list[upper].source)
        if #top > 0 and top:sub(-1) ~= "\n" then top = top .. "\n" end
        local merged = top .. util.get_cell_content(list[lower].source)
        list[upper].source = util.lines_to_source(vim.split(merged, "\n"))
        clear_cell_outputs(list[upper])
        local survivor = list[upper].id
        table.remove(list, lower)
        return survivor
    end)
end

-- Split the current cell at the cursor line into two cells of the same type.
function cells.split_cell()
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    edit_current_cell(function(list, current)
        local cell = list[current.idx]
        local src = util.clean_lines(util.get_cell_content(cell.source))
        -- Buffer row of the cell's first source line (code cells open with a fence).
        local first = current.start_row + (cell.cell_type == "code" and 1 or 0)
        local at = math.max(0, math.min(cursor_row - first, #src))

        local top, bottom = {}, {}
        for k = 1, at do top[k] = src[k] end
        for k = at + 1, #src do bottom[#bottom + 1] = src[k] end

        cell.source = util.lines_to_source(top)
        clear_cell_outputs(cell)

        local new_cell = nbformat.make_cell(cell.cell_type, nbformat.gen_id(nbformat.taken_ids(list)))
        new_cell.source = util.lines_to_source(bottom)
        table.insert(list, current.idx + 1, new_cell)
        return new_cell.id
    end)
end

-- Clear outputs of the current cell.
function cells.clear_outputs()
    edit_current_cell(function(list, current)
        clear_cell_outputs(list[current.idx])
        return current.id
    end)
end

-- Clear outputs of every cell in the notebook.
function cells.clear_all_outputs()
    local buf = vim.api.nvim_get_current_buf()
    local state = core.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end
    persist.sync_buffer(buf)
    for _, cell in ipairs(state.data.cells) do
        clear_cell_outputs(cell)
    end
    render.render(buf, state.data)
    vim.api.nvim_set_option_value("modified", true, { buf = buf })
end

-- Copy the current cell into juno's cell clipboard (separate from vim registers).
function cells.yank_cell()
    local buf = vim.api.nvim_get_current_buf()
    local state = core.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end
    persist.sync_buffer(buf)
    local current = cells.current_cell(buf)
    if not current then
        vim.notify("Juno: Cursor is not in a cell", vim.log.levels.WARN)
        return
    end
    clipboard = vim.deepcopy(state.data.cells[current.idx])
    vim.notify("Juno: cell yanked", vim.log.levels.INFO)
end

-- Paste the yanked cell below (default) or above the current cell. Between cells
-- (or in an empty notebook) it appends/prepends. The paste gets a fresh id.
function cells.paste_cell(where)
    if not clipboard then
        vim.notify("Juno: no yanked cell", vim.log.levels.WARN)
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    local state = core.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end
    persist.sync_buffer(buf)
    local list = state.data.cells
    local current = cells.current_cell(buf)
    local at
    if current then
        at = current.idx + (where == "above" and 0 or 1)
    else
        at = (where == "above") and 1 or (#list + 1)
    end

    local cell = vim.deepcopy(clipboard)
    cell.id = nbformat.gen_id(nbformat.taken_ids(list))
    -- deepcopy can drop the empty-dict marker; keep metadata a JSON object.
    if type(cell.metadata) ~= "table" or vim.tbl_isempty(cell.metadata) then
        cell.metadata = vim.empty_dict()
    end
    table.insert(list, at, cell)
    render.render(buf, state.data)
    vim.api.nvim_set_option_value("modified", true, { buf = buf })
    focus_cell(buf, cell.id)
end

return cells
