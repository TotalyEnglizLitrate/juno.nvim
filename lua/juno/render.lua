-- Rendering: lay a notebook's cells out as buffer lines (code cells fenced,
-- markdown/raw plain), place the cell-number and source-region extmarks, and
-- attach outputs as virtual lines. Also owns the output highlight groups.
local core = require("juno.core")
local util = require("juno.util")
local nbformat = require("juno.nbformat")

local render = {}

-- Render a mime bundle (execute_result/display_data `data`) as output lines.
--
-- Priority: text/markdown (produced by the sidecar's markdownify pass or
-- already present in the notebook) → text/plain → mime-type marker.
-- The sidecar's augment_html converts text/html to text/markdown at execution
-- time; notebooks opened from disk that only carry text/html will show the
-- plain-text fallback (or the mime marker when that is absent too).
-- Inline image/png rendering is a planned follow-up (image.nvim).
local function push_data_bundle(push, data)
    -- 1. Prefer the markdown rendering (produced by the sidecar's augment_html
    --    or already present in the notebook).
    local md = data["text/markdown"]
    if md then
        for _, line in ipairs(util.clean_lines(util.get_cell_content(md))) do
            push(line, "JunoOutputResult")
        end
        return "text/markdown"
    end
    -- 2. Fall back to text/plain.
    local plain = data["text/plain"]
    if plain then
        push("```text", "JunoOutputResult")
        for _, line in ipairs(util.clean_lines(util.get_cell_content(plain))) do
            push(line, "JunoOutputResult")
        end
        push("```", "JunoOutputResult")
        return "text/plain"
    end
    -- 3. No text representation at all — show the mime types so the user knows
    --    something was produced.
    local mimes = vim.tbl_keys(data)
    table.sort(mimes)
    if #mimes > 0 then
        push("```text", "JunoOutput")
        push("[" .. table.concat(mimes, ", ") .. "]", "JunoOutput")
        push("```", "JunoOutput")
        return "mimes"
    end
    return "empty"
end

local function output_to_lines(output, cell_num)
    local lines = {}
    local function push(text, text_hl)
        table.insert(lines, { text = text, text_hl = text_hl })
    end
    
    local header_idx = #lines + 2
    table.insert(lines, { text = ""})
    table.insert(lines, { text = "", is_header = true, label = "" })
    table.insert(lines, { text = "" })
    
    local out_type = output.output_type
    local out_details = ""
    
    if output.output_type == "stream" then
        out_details = ":" .. (output.name or "stdout")
        push("```text", "JunoOutput")
        for _, line in ipairs(util.clean_lines(util.get_cell_content(output.text))) do
            push(line, "JunoOutput")
        end
        push("```", "JunoOutput")
    elseif output.output_type == "execute_result" or output.output_type == "display_data" then
        local mime = push_data_bundle(push, output.data or {})
        out_details = ":" .. (mime or "")
    elseif output.output_type == "error" then
        push("```text", "JunoOutputError")
        for _, e_line in ipairs(util.clean_lines("Error: " .. (output.evalue or "unknown"))) do
            push(e_line, "JunoOutputError")
        end
        for _, tb in ipairs(output.traceback or {}) do
            for _, tb_line in ipairs(util.clean_lines(tb:gsub("\27%[[%d;]*m", ""))) do
                push(tb_line, "JunoOutputError")
            end
        end
        push("```", "JunoOutputError")
    end
    
    lines[header_idx].text = ""
    lines[header_idx].label = string.format("[%d:output:%s%s]", cell_num, out_type, out_details)
    lines[header_idx].text_hl = "InlayHint"
    
    return lines
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

local function render_cell_block(cell, cell_num, lang)
    local cell_lines = {}
    local out_objs = {}

    table.insert(cell_lines, "")  -- spacer line before cell content
    table.insert(cell_lines, "")  -- phantom line for cell number
    table.insert(cell_lines, "")  -- spacer line so cell content is not immediately below the marker
    -- Only code cells are fenced; markdown and raw cells render as plain lines.
    -- (sync_buffer strips fences for code cells only, so fencing a raw cell would
    -- bake the ``` lines into its source on save.)
    local src = util.clean_lines(util.get_cell_content(cell.source))
    local h
    if cell.cell_type == "code" then
        table.insert(cell_lines, "```" .. lang)
        vim.list_extend(cell_lines, src)
        table.insert(cell_lines, "```")
        h = #src + 2
    else
        vim.list_extend(cell_lines, src)
        h = #src
    end

    if cell.cell_type == "code" and cell.outputs and #cell.outputs > 0 then
        for _, out in ipairs(cell.outputs) do
            vim.list_extend(out_objs, output_to_lines(out, cell_num))
        end
        for _, obj in ipairs(out_objs) do
            table.insert(cell_lines, obj.text)
        end
    end

    table.insert(cell_lines, "")  -- trailing empty line
    return cell_lines, h, out_objs
end

local function set_cell_extmarks(buf, state, cell_id, cell_num, pos, mark)
    vim.api.nvim_buf_set_extmark(buf, core.ns.num, pos.phantom, 0, {
        id = mark,
        virt_text = { { "[" .. cell_num .. "]", "InlayHint" } },
        virt_text_pos = "overlay",
    })

    vim.api.nvim_buf_set_extmark(buf, core.ns.src, pos.start, 0, {
        end_row = pos.start + pos.h,
        id = mark,
    })

    if #pos.out_objs > 0 then
        local out_start = pos.start + pos.h
        for offset, obj in ipairs(pos.out_objs) do
            local cur_row = out_start + offset - 1
            if obj.is_header then
                vim.api.nvim_buf_set_extmark(buf, core.ns.out, cur_row, 0, {
                    virt_text = { { obj.label, obj.text_hl } },
                    virt_text_pos = "overlay",
                })
            elseif obj.text_hl then
                vim.api.nvim_buf_set_extmark(buf, core.ns.out, cur_row, 0, {
                    end_row = cur_row,
                    end_col = #obj.text,
                    hl_group = obj.text_hl,
                })
            end
        end
    end
end

function render.render(buf, data, target_cell_id)
    local lang = nbformat.kernel_language(data)
    local state = core.buf_state[buf]

    -- Incremental render path
    if target_cell_id and state and state.mark_ids and state.mark_ids[target_cell_id] then
        local list_idx = nbformat.index_by_id(data.cells or {}, target_cell_id)
        if list_idx then
            local cell = data.cells[list_idx]
            local mark = state.mark_ids[target_cell_id]
            local old_mark = vim.api.nvim_buf_get_extmark_by_id(buf, core.ns.src, mark, { details = true })

            if old_mark and #old_mark > 0 then
                local old_start_row = old_mark[1]
                local block_start = old_start_row - 3

                -- Find block_end by querying the next cell's start row
                local block_end
                if list_idx < #(data.cells or {}) then
                    local next_cell = data.cells[list_idx + 1]
                    local next_mark_id = state.mark_ids[next_cell.id]
                    local next_mark = next_mark_id
                        and vim.api.nvim_buf_get_extmark_by_id(buf, core.ns.src, next_mark_id, { details = true })
                    if next_mark and #next_mark > 0 then
                        block_end = next_mark[1] - 3
                    end
                end
                if not block_end then
                    block_end = vim.api.nvim_buf_line_count(buf)
                end

                -- Render the cell block
                local cell_lines, h_new, out_objs = render_cell_block(cell, list_idx, lang)

                -- Replace only the cell's lines in the buffer
                vim.api.nvim_buf_set_lines(buf, block_start, block_end, false, cell_lines)

                -- Clear old extmarks in the output namespace range for this block
                vim.api.nvim_buf_clear_namespace(buf, core.ns.out, block_start, block_end)

                -- Re-register in mark_cell
                state.mark_cell[mark] = target_cell_id

                -- Place the new extmarks
                local pos = {
                    phantom = block_start + 1,
                    start = block_start + 3,
                    h = h_new,
                    out_objs = out_objs,
                }
                set_cell_extmarks(buf, state, target_cell_id, list_idx, pos, mark)
                return
            end
        end
    end

    -- Fallback: Full Re-render path
    if state then state.mark_cell = {} end
    local lines = {}
    local cell_pos = {}
    local idx = 0

    for i, cell in ipairs(data.cells or {}) do
        local cell_lines, h, out_objs = render_cell_block(cell, i, lang)

        local phantom_row = idx + 1
        local start = idx + 3

        vim.list_extend(lines, cell_lines)
        cell_pos[i] = { start = start, h = h, out_objs = out_objs, phantom = phantom_row }

        local out_h = #out_objs
        idx = idx + 3 + h + out_h + 1
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.api.nvim_buf_clear_namespace(buf, core.ns.src, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, core.ns.out, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, core.ns.num, 0, -1)

    for i, cell in ipairs(data.cells or {}) do
        local pos = cell_pos[i]
        local mark = state and mark_for(state, cell.id) or i
        set_cell_extmarks(buf, state, cell.id, i, pos, mark)
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
