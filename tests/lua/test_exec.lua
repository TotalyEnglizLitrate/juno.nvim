-- Execution end to end: run current + run all, capture stream/execute_result/
-- error as nbformat outputs, ascending execution_count, inline render, persistence.
local T = dofile(vim.env.JUNO_TEST_DIR .. "/harness.lua")

local ok, err = pcall(function()
    local nb, core = require("juno.nbformat"), require("juno.core")
    local path = vim.env.JUNO_TMP .. "/exec.ipynb"
    T.write_nb(path, {
        { id = "e1", src = "print('hello juno')" },
        { id = "e2", src = "21*2" },
        { id = "e3", src = "1/0" },
    })
    local buf, state = T.open(path, { execution = { prompt_for_kernel = false } })

    -- Run the first cell.
    T.goto_id(buf, "e1")
    require("juno").run()
    T.check(T.wait(function()
        return nb.cell_by_id(state.data.cells, "e1").execution_count ~= vim.NIL
    end), "cell e1 completed")

    -- Run all cells; wait until every code cell has a count.
    require("juno").run("all")
    T.check(T.wait(function()
        for _, c in ipairs(state.data.cells) do
            if c.execution_count == vim.NIL then return false end
        end
        return true
    end), "run all completed")

    local c1 = nb.cell_by_id(state.data.cells, "e1")
    local c2 = nb.cell_by_id(state.data.cells, "e2")
    local c3 = nb.cell_by_id(state.data.cells, "e3")
    T.eq(c1.outputs[1].output_type, "stream", "e1 -> stream")
    T.eq(c2.outputs[1].output_type, "execute_result", "e2 -> execute_result")
    T.eq(c2.outputs[1].data["text/plain"], "42", "e2 value is 42")
    T.eq(c3.outputs[1].output_type, "error", "e3 -> error")
    T.check(c1.execution_count < c2.execution_count and c2.execution_count < c3.execution_count,
        "execution_count ascends across run all")

    -- Outputs are rendered inline (ns.out virt_lines).
    local marks = vim.api.nvim_buf_get_extmarks(buf, core.ns.out, 0, -1, {})
    T.check(#marks >= 3, "each cell's output rendered inline")

    -- Save and reload from disk.
    require("juno.persist").sync_and_save(buf)
    T.settle(200)
    local data = T.read_nb(path)
    local with_outputs = 0
    for _, c in ipairs(data.cells) do
        if c.outputs and #c.outputs > 0 then with_outputs = with_outputs + 1 end
    end
    T.eq(with_outputs, 3, "all three cells persisted their outputs")

    require("juno.exec").stop(buf)
    T.settle(200)
end)

if not ok then T.check(false, "error: " .. tostring(err)) end
T.finish("exec")
