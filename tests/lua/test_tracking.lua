-- Cell-id tracking: an edit made in the buffer must follow its cell through a
-- reorder, keyed by stable nbformat id rather than list position.
local T = dofile(vim.env.JUNO_TEST_DIR .. "/harness.lua")

local ok, err = pcall(function()
    local path = vim.env.JUNO_TMP .. "/tracking.ipynb"
    T.write_nb(path, {
        { id = "aaaa1111", src = "AAA" },
        { id = "bbbb2222", src = "BBB" },
        { id = "cccc3333", src = "CCC" },
    })
    local buf = T.open(path)
    local render, cells, persist = require("juno.render"), require("juno.cells"), require("juno.persist")

    -- Edit cell B's source line in the buffer, then move B up.
    local posB = render.cell_positions(buf)[2]
    local srcrow = posB.start_row + 1  -- first source line (after the ``` fence)
    vim.api.nvim_buf_set_lines(buf, srcrow, srcrow + 1, false, { "B_EDITED" })
    vim.api.nvim_win_set_cursor(0, { posB.start_row + 2, 0 })
    cells.move_cell(-1)
    persist.sync_and_save(buf)

    local data = T.read_nb(path)
    local order = {}
    for i, c in ipairs(data.cells) do order[i] = c.id end
    T.eq(order, { "bbbb2222", "aaaa1111", "cccc3333" }, "order after moving B up")

    local function src(id)
        for _, c in ipairs(data.cells) do if c.id == id then return table.concat(c.source) end end
    end
    T.eq(src("bbbb2222"), "B_EDITED", "the edit followed cell B by id across the move")
    T.eq(src("aaaa1111"), "AAA", "cell A's source is untouched")
end)

if not ok then T.check(false, "error: " .. tostring(err)) end
T.finish("tracking")
