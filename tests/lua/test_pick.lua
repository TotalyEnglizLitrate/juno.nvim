-- :Juno kernels re-picks the kernel: define a variable, switch to a fresh
-- launch-env kernel, and the variable is gone (NameError) -> the old kernel was
-- torn down and replaced. Also exercises the vim.ui.select prompt path.
local T = dofile(vim.env.JUNO_TEST_DIR .. "/harness.lua")

local ok, err = pcall(function()
    local nb = require("juno.nbformat")
    local path = vim.env.JUNO_TMP .. "/pick.ipynb"
    T.write_nb(path, { { id = "k1", src = "x = 123" }, { id = "k2", src = "x" } })
    local buf, state = T.open(path, { execution = { prompt_for_kernel = false } })

    T.goto_id(buf, "k1"); require("juno").run()
    T.check(T.wait(function() return nb.cell_by_id(state.data.cells, "k1").execution_count ~= vim.NIL end),
        "k1 ran")
    T.goto_id(buf, "k2"); require("juno").run()
    T.check(T.wait(function() return nb.cell_by_id(state.data.cells, "k2").execution_count ~= vim.NIL end),
        "k2 ran on the same kernel")
    local before = nb.cell_by_id(state.data.cells, "k2").outputs[1]
    T.eq(before.data and before.data["text/plain"], "123", "x == 123 before re-pick")

    -- Re-pick, auto-selecting the first picker entry (the launch-env kernel).
    local labels = {}
    vim.ui.select = function(items, _, on_choice)
        for _, e in ipairs(items) do labels[#labels + 1] = e.label end
        on_choice(items[1], 1)
    end
    require("juno").pick_kernel()
    T.check(T.wait(function() return state.exec and state.exec.ready end), "fresh kernel became ready")
    T.check(#labels >= 1, "picker presented at least one entry")

    T.goto_id(buf, "k2"); require("juno").run()
    T.check(T.wait(function()
        local c = nb.cell_by_id(state.data.cells, "k2")
        return c.execution_count ~= vim.NIL and c.outputs[1]
    end), "k2 ran on the fresh kernel")
    local after = nb.cell_by_id(state.data.cells, "k2").outputs[1]
    T.eq(after.output_type, "error", "fresh kernel has no x -> error")
    T.eq(after.ename, "NameError", "re-pick gave a brand new kernel state")

    require("juno.exec").stop(buf)
    T.settle(200)
end)

if not ok then T.check(false, "error: " .. tostring(err)) end
T.finish("pick")
