-- Rendering: lay a notebook's cells out as buffer lines (code cells fenced,
-- markdown/raw plain), place the cell-number and source-region extmarks, and
-- attach outputs as virtual lines. Also owns the output highlight groups.
local core = require("juno.core")
local util = require("juno.util")
local nbformat = require("juno.nbformat")

local render = {}

-- A left rail on every output line marks the block as output (distinct from
-- source) while leaving the text itself in a high-contrast group. The glyph is
-- configurable via config.output_rail; this is the default.
render.OUTPUT_RAIL = "▎ "

-- Render a mime bundle (execute_result/display_data `data`) as output lines.
-- Terminals only show text, so prefer a text representation; when the bundle is
-- rich-only (image/*, html-only, ...) fall back to a marker naming the mimes so
-- the output isn't silently blank. Inline image/png rendering is a planned
-- follow-up (image.nvim).
local function push_data_bundle(push, data)
    local text = data["text/plain"] or data["text/markdown"]
    if text then
        for _, line in ipairs(util.clean_lines(util.get_cell_content(text))) do
            push(line, "JunoOutputResult")
        end
        return
    end
    local mimes = vim.tbl_keys(data)
    table.sort(mimes)
    if #mimes > 0 then
        push("[" .. table.concat(mimes, ", ") .. "]", "JunoOutput")
    end
end

local function output_to_virt_lines(output)
    local vlines = {}
    local rail = core.config.output_rail or render.OUTPUT_RAIL
    local function push(text, text_hl, rail_hl)
        table.insert(vlines, { { rail, rail_hl or "JunoOutputMarker" }, { text, text_hl } })
    end
    if output.output_type == "stream" then
        for _, line in ipairs(util.clean_lines(util.get_cell_content(output.text))) do
            push(line, "JunoOutput")
        end
    elseif output.output_type == "execute_result" or output.output_type == "display_data" then
        push_data_bundle(push, output.data or {})
    elseif output.output_type == "error" then
        push("Error: " .. (output.evalue or "unknown"), "JunoOutputError", "JunoOutputError")
        for _, tb in ipairs(output.traceback or {}) do
            push(tb:gsub("\27%[[%d;]*m", ""), "JunoOutputError", "JunoOutputError")
        end
    end
    return vlines
end

-- Returns cell positions from ns.src extmarks, in document order.
-- Each entry: { id = <stable nbformat cell id>, mark = <extmark int id>,
--               start_row, end_row }.
-- Cells are tracked by their stable string id (via the per-buffer mark registry
-- render builds), not by list position, so callers survive reordering.
function render.cell_positions(buf)
    local state = core.buf_state[buf]
    local mark_cell = state and state.mark_cell or {}
    local marks = vim.api.nvim_buf_get_extmarks(buf, core.ns.src, 0, -1, { details = true })
    local positions = {}
    for _, mark in ipairs(marks) do
        -- mark = { extmark_id, start_row, start_col, details }
        table.insert(positions, {
            id = mark_cell[mark[1]],
            mark = mark[1],
            start_row = mark[2],
            end_row = mark[4].end_row,
        })
    end
    return positions
end

-- Stable integer extmark id for a cell's nbformat id, allocated once per cell and
-- reused across renders so the ns.src/ns.num extmarks keep the same handle as the
-- cell moves. Also records the reverse (mark -> cell id) that cell_positions reads.
local function mark_for(state, cell_id)
    state.mark_ids = state.mark_ids or {}
    state.mark_seq = state.mark_seq or 0
    local m = state.mark_ids[cell_id]
    if not m then
        state.mark_seq = state.mark_seq + 1
        m = state.mark_seq
        state.mark_ids[cell_id] = m
    end
    state.mark_cell[m] = cell_id
    return m
end

function render.render(buf, data)
    local lang = nbformat.kernel_language(data)
    local state = core.buf_state[buf]
    -- Rebuild the mark -> cell-id reverse map each render; mark_ids (cell-id ->
    -- mark) persists on state so a cell keeps its extmark handle as it moves.
    if state then state.mark_cell = {} end
    local lines = {}
    local cell_pos = {}
    local idx = 0

    for i, cell in ipairs(data.cells or {}) do
        local phantom_row = idx
        local start = idx + 1
        local src = util.clean_lines(util.get_cell_content(cell.source))
        local h

        table.insert(lines, "")  -- phantom line for cell number
        -- Only code cells are fenced; markdown and raw cells render as plain lines.
        -- (sync_buffer strips fences for code cells only, so fencing a raw cell would
        -- bake the ``` lines into its source on save.)
        if cell.cell_type == "code" then
            table.insert(lines, "```" .. lang)
            vim.list_extend(lines, src)
            table.insert(lines, "```")
            h = #src + 2
        else
            vim.list_extend(lines, src)
            h = #src
        end

        table.insert(lines, "")
        idx = idx + 1 + h + 1
        cell_pos[i] = { start = start, h = h, phantom = phantom_row }
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- Clear prior extmarks so render() is idempotent (it's re-run when cells
    -- are added). ns.out extmarks use auto-ids, so without this they'd stack up.
    vim.api.nvim_buf_clear_namespace(buf, core.ns.src, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, core.ns.out, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, core.ns.num, 0, -1)

    for i, cell in ipairs(data.cells or {}) do
        local pos = cell_pos[i]
        -- Stable per-cell extmark handle (falls back to position if this buffer
        -- has no state, which shouldn't happen for a rendered notebook). The
        -- displayed [n] stays positional so cell numbers read 1..N as before.
        local mark = state and mark_for(state, cell.id) or i

        vim.api.nvim_buf_set_extmark(buf, core.ns.num, pos.phantom, 0, {
            id = mark,
            virt_text = { { "[" .. i .. "]", "InlayHint" } },
            virt_text_pos = "overlay",
        })

        vim.api.nvim_buf_set_extmark(buf, core.ns.src, pos.start, 0, {
            end_row = pos.start + pos.h,
            id = mark,
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
                vim.api.nvim_buf_set_extmark(buf, core.ns.out, pos.start + pos.h, 0, {
                    virt_lines = vlines,
                    virt_lines_above = true,
                })
            end
        end
    end
end

-- Define juno's output highlight groups as overridable links (default = true, so a
-- user's own definition wins). Re-applied on ColorScheme since a theme switch can
-- clear them. See the README Highlights table for what each group is used for.
function render.apply_highlights()
    local links = {
        JunoOutputMarker = "Special",
        JunoOutput       = "Normal",
        JunoOutputResult = "Normal",
        JunoOutputError  = "DiagnosticError",
    }
    for group, link in pairs(links) do
        vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end
end

return render
