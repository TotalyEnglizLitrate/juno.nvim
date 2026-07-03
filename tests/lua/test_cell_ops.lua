-- Structural cell operations (yank/paste, move, delete, change-type, split) after
-- the id-based refactor: positions come from current.idx, identity from current.id.
local T = dofile(vim.env.JUNO_TEST_DIR .. "/harness.lua")

local ok, err = pcall(function()
    local nb = require("juno.nbformat")
    local cells, render = require("juno.cells"), require("juno.render")
    local path = vim.env.JUNO_TMP .. "/ops.ipynb"
    T.write_nb(path, {
        { id = "A0", src = "AAA" },
        { id = "B0", src = "BBB" },
        { id = "C0", src = "CCC" },
    })
    local buf, state = T.open(path)

    -- yank B, paste below C -> [A, B, C, B'] with a fresh id.
    T.goto_id(buf, "B0"); cells.yank_cell()
    T.goto_id(buf, "C0"); cells.paste_cell("below")
    T.eq(#state.data.cells, 4, "paste added a cell")
    local pasted = state.data.cells[4]
    T.eq(table.concat(pasted.source), "BBB", "pasted cell keeps content")
    T.check(pasted.id ~= "A0" and pasted.id ~= "B0" and pasted.id ~= "C0", "pasted cell got a fresh id")

    -- move A down -> [B, A, C, B'].
    T.goto_id(buf, "A0"); cells.move_cell(1)
    T.eq(T.ids(state), { "B0", "A0", "C0", pasted.id }, "order after moving A down")

    -- delete A -> [B, C, B'].
    T.goto_id(buf, "A0"); cells.delete_cell()
    T.eq(T.ids(state), { "B0", "C0", pasted.id }, "order after deleting A")

    -- change C to markdown -> code-only fields drop.
    T.goto_id(buf, "C0"); cells.change_cell_type("markdown")
    local c = nb.cell_by_id(state.data.cells, "C0")
    T.eq(c.cell_type, "markdown", "C is now markdown")
    T.check(c.outputs == nil, "markdown cell carries no outputs")

    -- split B at its first source line -> B keeps the top (empty), a new cell
    -- after it takes the body.
    for _, pos in ipairs(render.cell_positions(buf)) do
        if pos.id == "B0" then vim.api.nvim_win_set_cursor(0, { pos.start_row + 2, 0 }) end
    end
    cells.split_cell()
    local bi = nb.index_by_id(state.data.cells, "B0")
    T.check(bi ~= nil, "B0 survives the split")
    local after = state.data.cells[bi + 1]
    T.check(after ~= nil and after.id ~= "B0", "split inserted a new cell after B0")
    T.eq(table.concat(after.source), "BBB", "split moved the body into the new cell")
end)

if not ok then T.check(false, "error: " .. tostring(err)) end
T.finish("cell_ops")
