-- Pure nbformat helpers plus the cells id<->number bridges.
local T = dofile(vim.env.JUNO_TEST_DIR .. "/harness.lua")

local ok, err = pcall(function()
    local nb = require("juno.nbformat")

    -- normalize fills required fields and per-cell ids in place.
    local data = { cells = {
        { cell_type = "code", source = "print(1)" },
        { cell_type = "markdown", source = { "# h" } },
    } }
    nb.normalize(data)
    T.eq(data.nbformat, 4, "nbformat major")
    T.eq(data.nbformat_minor, 5, "nbformat minor")
    T.check(type(data.cells[1].id) == "string" and #data.cells[1].id > 0, "code cell got a string id")
    T.check(type(data.cells[1].source) == "table", "string source coerced to a list")
    T.check(data.cells[1].outputs ~= nil, "code cell has an outputs list")
    T.check(data.cells[2].outputs == nil, "markdown cell has no outputs")

    -- cell_by_id / index_by_id.
    local cs = { { id = "x" }, { id = "y" }, { id = "z" } }
    T.eq(nb.cell_by_id(cs, "y").id, "y", "cell_by_id hit")
    T.eq(nb.index_by_id(cs, "z"), 3, "index_by_id position")
    T.check(nb.cell_by_id(cs, "nope") == nil, "cell_by_id miss is nil")
    T.check(nb.index_by_id(cs, "nope") == nil, "index_by_id miss is nil")

    -- gen_id avoids taken ids.
    local taken = nb.taken_ids(cs)
    T.check(not taken[nb.gen_id(taken)], "gen_id avoids taken ids")

    -- cells.id_at / index_of over a real buffer.
    local path = vim.env.JUNO_TMP .. "/nbf.ipynb"
    T.write_nb(path, { { id = "p1", src = "A" }, { id = "p2", src = "B" } })
    local buf = T.open(path)
    local cells = require("juno.cells")
    T.eq(cells.id_at(buf, 2), "p2", "id_at maps position -> id")
    T.eq(cells.index_of(buf, "p1"), 1, "index_of maps id -> position")
    T.check(cells.id_at(buf, 99) == nil, "id_at out of range is nil")
    T.check(cells.index_of(buf, "missing") == nil, "index_of miss is nil")
end)

if not ok then T.check(false, "error: " .. tostring(err)) end
T.finish("nbformat")
