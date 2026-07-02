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
    elseif output.output_type == "execute_result" and output.data and output.data["text/plain"] then
        for _, line in ipairs(util.clean_lines(util.get_cell_content(output.data["text/plain"]))) do
            push(line, "JunoOutputResult")
        end
    elseif output.output_type == "error" then
        push("Error: " .. (output.evalue or "unknown"), "JunoOutputError", "JunoOutputError")
        for _, tb in ipairs(output.traceback or {}) do
            push(tb:gsub("\27%[[%d;]*m", ""), "JunoOutputError", "JunoOutputError")
        end
    end
    return vlines
end

-- Returns cell positions from ns.src extmarks, sorted by start row.
-- Each entry: { id, start_row, end_row }
function render.cell_positions(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, core.ns.src, 0, -1, { details = true })
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

function render.render(buf, data)
    local lang = nbformat.kernel_language(data)
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

        vim.api.nvim_buf_set_extmark(buf, core.ns.num, pos.phantom, 0, {
            id = i,
            virt_text = { { "[" .. i .. "]", "InlayHint" } },
            virt_text_pos = "overlay",
        })

        vim.api.nvim_buf_set_extmark(buf, core.ns.src, pos.start, 0, {
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
-- clear them. Tune contrast by overriding e.g. JunoOutput / JunoOutputMarker.
function render.apply_highlights()
    local links = {
        JunoOutputMarker = "Special",          -- the left rail / output marker
        JunoOutput       = "Normal",            -- stream (stdout/stderr) text
        JunoOutputResult = "Normal",            -- execute_result (return value) text
        JunoOutputError  = "DiagnosticError",   -- errors + tracebacks
    }
    for group, link in pairs(links) do
        vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end
end

return render
