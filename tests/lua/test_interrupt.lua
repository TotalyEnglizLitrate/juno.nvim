-- :Juno interrupt stops an in-flight cell, which surfaces as a KeyboardInterrupt.
local T = dofile(vim.env.JUNO_TEST_DIR .. "/harness.lua")

local ok, err = pcall(function()
    local nb = require("juno.nbformat")
    local path = vim.env.JUNO_TMP .. "/int.ipynb"
    T.write_nb(path, { { id = "loop1", src = "import time\nwhile True:\n    time.sleep(0.05)" } })
    local buf, state = T.open(path, { execution = { prompt_for_kernel = false } })

    T.goto_id(buf, "loop1")
    require("juno").run()
    T.check(T.wait(function() return state.exec and state.exec.ready end), "kernel became ready")
    T.settle(1000)  -- let the loop actually be running

    require("juno").interrupt()
    T.check(T.wait(function()
        local c = nb.cell_by_id(state.data.cells, "loop1")
        return c.execution_count ~= vim.NIL and c.outputs and #c.outputs > 0
    end, 15000), "interrupted cell finished")

    local o = nb.cell_by_id(state.data.cells, "loop1").outputs[1]
    T.eq(o.output_type, "error", "interrupt produced an error output")
    T.eq(o.ename, "KeyboardInterrupt", "interrupt raised KeyboardInterrupt")

    require("juno.exec").stop(buf)
    T.settle(200)
end)

if not ok then T.check(false, "error: " .. tostring(err)) end
T.finish("interrupt")
