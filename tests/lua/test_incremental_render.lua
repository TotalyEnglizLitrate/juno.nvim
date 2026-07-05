-- Unit tests for incremental rendering: verify targeted cell block updates,
-- line shifting, extmark correctness, and fallback to full render.
local T = dofile(vim.env.JUNO_TEST_DIR .. "/harness.lua")

local ok, err = pcall(function()
    local render = require("juno.render")
    local core = require("juno.core")
    local nb = require("juno.nbformat")
    
    local path = vim.env.JUNO_TMP .. "/incremental.ipynb"
    T.write_nb(path, {
        { id = "c1", src = "print('cell 1')" },
        { id = "c2", src = "print('cell 2')" },
        { id = "c3", src = "print('cell 3')" },
    })
    local buf, state = T.open(path)

    -- Retrieve initial positions.
    local pos1 = render.cell_positions(buf)
    T.eq(#pos1, 3, "three cells loaded initially")
    
    -- Verify initial line count.
    local initial_line_count = vim.api.nvim_buf_line_count(buf)
    
    -- Test 1: Modify cell 2 source in data, and perform an incremental render.
    local cell2 = nb.cell_by_id(state.data.cells, "c2")
    cell2.source = { "print('cell 2 modified')\n", "second line" }
    
    render.render(buf, state.data, "c2")
    
    -- Verify only cell 2 and lines after it shifted.
    local pos2 = render.cell_positions(buf)
    T.eq(pos2[1].start_row, pos1[1].start_row, "cell 1 position untouched")
    T.eq(pos2[2].start_row, pos1[2].start_row, "cell 2 starts at same row")
    
    -- Cell 2 source changed from 1 line to 2 lines. So its height increased by 1.
    -- Therefore, cell 3 should be shifted down by 1 row.
    T.eq(pos2[3].start_row, pos1[3].start_row + 1, "cell 3 shifted down by 1 row")
    
    -- Verify the line count increased by 1.
    local next_line_count = vim.api.nvim_buf_line_count(buf)
    T.eq(next_line_count, initial_line_count + 1, "line count increased by 1")
    
    -- Test 2: Add outputs to cell 1 and render incrementally.
    local cell1 = nb.cell_by_id(state.data.cells, "c1")
    cell1.outputs = {
        {
            output_type = "stream",
            name = "stdout",
            text = "hello output\n"
        }
    }
    
    render.render(buf, state.data, "c1")
    
    -- Adding outputs to cell 1 (output header + output spacer + fence + content + fence)
    -- should increase cell 1's block size, shifting cell 2 and cell 3 down.
    local pos3 = render.cell_positions(buf)
    
    -- Check that cell 1's position is still correct
    T.eq(pos3[1].start_row, pos1[1].start_row, "cell 1 start row remains 3")
    
    -- Cell 2 and cell 3 should be shifted down
    T.check(pos3[2].start_row > pos2[2].start_row, "cell 2 shifted down after cell 1 outputs added")
    T.check(pos3[3].start_row > pos2[3].start_row, "cell 3 shifted down after cell 1 outputs added")
    
    -- Test 3: Fallback path: verify it correctly falls back to full render if ID is invalid.
    render.render(buf, state.data, "invalid_id")
    local pos4 = render.cell_positions(buf)
    T.eq(#pos4, 3, "fallback full render still renders all cells")
end)

if not ok then T.check(false, "error: " .. tostring(err)) end
T.finish("incremental_render")
