-- Minimal assert harness for the headless-nvim lua tests. Each test file does
--   local T = dofile(vim.env.JUNO_TEST_DIR .. "/harness.lua")
-- records checks with T.check/T.eq, and ends with T.finish(name), which prints a
-- summary and os.exit()s 0 (all passed) or 1 (any failed) for the shell runner.
local T = { failures = {}, n = 0 }

function T.check(cond, msg)
    T.n = T.n + 1
    if not cond then T.failures[#T.failures + 1] = msg or ("check #" .. T.n) end
    return cond
end

function T.eq(got, want, msg)
    return T.check(vim.deep_equal(got, want),
        string.format("%s: got %s, want %s", msg or "eq", vim.inspect(got), vim.inspect(want)))
end

-- vim.wait that pumps the loop (uv callbacks + scheduled fns) until cond is true.
function T.wait(cond, ms)
    return vim.wait(ms or 30000, cond, 50)
end

-- Pump the event loop for ms (a cooperative sleep for async settling).
function T.settle(ms)
    vim.wait(ms or 200, function() return false end, 20)
end

-- Write a notebook fixture. cells = { { type=, src=, id= }, ... } (type defaults
-- to "code"). Returns the path.
function T.write_nb(path, cells)
    local nb = { cells = {}, metadata = vim.empty_dict(), nbformat = 4, nbformat_minor = 5 }
    for i, c in ipairs(cells) do
        local cell = {
            id = c.id or string.format("cell%04d", i),
            cell_type = c.type or "code",
            metadata = vim.empty_dict(),
            source = { c.src or "" },
        }
        if cell.cell_type == "code" then
            cell.outputs = {}
            cell.execution_count = vim.NIL
        end
        nb.cells[i] = cell
    end
    vim.fn.writefile({ vim.json.encode(nb) }, path)
    return path
end

-- setup juno (otter off, watch off) and open a notebook; returns buf, state.
function T.open(path, cfg)
    require("juno").setup(vim.tbl_deep_extend("force",
        { otter = { enabled = false }, watch = false }, cfg or {}))
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    return buf, require("juno.core").buf_state[buf]
end

-- Move the cursor into the cell with nbformat id `id` (its first buffer line,
-- which current_cell counts as inside the cell). Returns true if found.
function T.goto_id(buf, id)
    for _, pos in ipairs(require("juno.render").cell_positions(buf)) do
        if pos.id == id then
            vim.api.nvim_win_set_cursor(0, { pos.start_row + 1, 0 })
            return true
        end
    end
    return false
end

-- The ordered list of cell ids in the model.
function T.ids(state)
    local t = {}
    for i, c in ipairs(state.data.cells) do t[i] = c.id end
    return t
end

-- Read a notebook back from disk (post-save) as a decoded table.
function T.read_nb(path)
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

function T.finish(name)
    if #T.failures == 0 then
        io.write("PASS " .. name .. "\n")
        os.exit(0)
    end
    io.write("FAIL " .. name .. "\n")
    for _, f in ipairs(T.failures) do io.write("  - " .. f .. "\n") end
    os.exit(1)
end

return T
