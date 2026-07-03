-- In-editor cell execution. Spawns the juno_kernel.py sidecar (juno.persist's
-- launch-env python) once per notebook buffer, drives it over the line-delimited
-- JSON protocol, and folds results back into the notebook model so they render
-- through the normal output pipeline (render.render) and persist on :w.
--
-- The sidecar owns the Jupyter wire protocol; this module owns process
-- lifecycle, kernel resolution (attach / named / prompt / env-python), and
-- id-keyed capture (outputs re-locate their cell by stable nbformat id, so they
-- land correctly even if cells are edited or inserted mid-run).
local core = require("juno.core")
local render = require("juno.render")
local persist = require("juno.persist")
local nbformat = require("juno.nbformat")
local cells = require("juno.cells")
local util = require("juno.util")

local uv = vim.uv or vim.loop
local exec = {}

-- Per-buffer session lives on core.buf_state[buf].exec:
--   { handle, stdin, stdout, stderr, rbuf, ready, dead,
--     on_ready = { <fn> }, pending = { [nb_id] = <done_cb> },
--     kernel_name, attached }

local _leave_hooked = false

local function notify(msg, level)
    vim.notify("Juno: " .. msg, level or vim.log.levels.INFO)
end

-- Resolve the shipped sidecar script off the runtimepath, falling back to a
-- path relative to this file (covers being run straight from a checkout).
local function script_path()
    local found = vim.api.nvim_get_runtime_file("python/juno_kernel.py", false)
    if found and found[1] then return found[1] end
    local src = debug.getinfo(1, "S").source:sub(2)
    local guess = src:gsub("lua/juno/exec%.lua$", "python/juno_kernel.py")
    if vim.fn.filereadable(guess) == 1 then return guess end
    return nil
end

local function send(sess, obj)
    if sess and sess.stdin and not sess.stdin:is_closing() then
        sess.stdin:write(vim.json.encode(obj) .. "\n")
    end
end

local function find_cell_by_id(state, id)
    for _, c in ipairs(state.data.cells or {}) do
        if c.id == id then return c end
    end
    return nil
end

-- Shut a session's kernel down and close its handles. Captures the session
-- directly (not via buf_state) so teardown works even after the buffer's own
-- BufWipeout handler has cleared buf_state.
local function stop_session(sess)
    if not sess or sess.dead then return end
    sess.dead = true
    sess.ready = false
    sess.on_ready = {}
    send(sess, { op = "shutdown" })
    -- Give the sidecar a moment to exit cleanly (its own exit handler closes
    -- the pipes); force-kill if it's still around.
    vim.defer_fn(function()
        if sess.handle and not sess.handle:is_closing() then
            pcall(function() sess.handle:kill("sigterm") end)
        end
    end, 2000)
end

local function apply_output(buf, cell_id, output)
    local state = core.buf_state[buf]
    if not state or not vim.api.nvim_buf_is_valid(buf) then return end
    local cell = find_cell_by_id(state, cell_id)
    if not cell then return end
    persist.sync_buffer(buf)  -- capture in-progress edits before we rewrite the buffer
    cell.outputs = cell.outputs or {}
    table.insert(cell.outputs, output)
    render.render(buf, state.data)
    vim.api.nvim_set_option_value("modified", true, { buf = buf })
end

local function apply_done(buf, cell_id, execution_count)
    local state = core.buf_state[buf]
    if not state or not vim.api.nvim_buf_is_valid(buf) then return end
    local cell = find_cell_by_id(state, cell_id)
    if not cell then return end
    persist.sync_buffer(buf)
    if execution_count == nil or execution_count == vim.NIL then
        cell.execution_count = vim.NIL
    else
        cell.execution_count = execution_count
    end
    render.render(buf, state.data)
    vim.api.nvim_set_option_value("modified", true, { buf = buf })
end

local function fail(buf, sess, msg)
    notify(msg, vim.log.levels.WARN)
    stop_session(sess)
    local state = core.buf_state[buf]
    if state and state.exec == sess then state.exec = nil end
end

-- Match execution.attach (a connection-file path, or a bare kernel id) against
-- the discovered running kernels; returns a connection file or nil.
local function resolve_attach(spec, running)
    if spec:find("/") then return spec end
    for _, r in ipairs(running or {}) do
        local base = (r.connection_file or ""):match("([^/]+)$") or ""
        if base == spec
            or base == ("kernel-" .. spec .. ".json")
            or base:gsub("%.json$", "") == spec then
            return r.connection_file
        end
    end
    return nil
end

-- Pick a registered kernelspec name for the notebook language: the mapped name
-- if it exists, else the first spec whose language matches.
local function find_spec(specs, want, lang)
    for _, s in ipairs(specs or {}) do
        if want and s.name == want then return s.name end
    end
    for _, s in ipairs(specs or {}) do
        if s.language == lang then return s.name end
    end
    return nil
end

local function auto_kernel(buf, sess, ev, lang)
    local cfg = core.config.execution
    if lang == "python" and cfg.allow_env_kernel and cfg.prefer_env_python then
        send(sess, { op = "start", env_python = true })
        return
    end
    local want = cfg.kernel_map and cfg.kernel_map[lang]
    local pick = find_spec(ev.specs, want, lang)
    if pick then
        send(sess, { op = "start", kernel_name = pick })
        return
    end
    if lang == "python" and cfg.allow_env_kernel then
        send(sess, { op = "start", env_python = true })
        return
    end
    fail(buf, sess, "no kernel found for language '" .. lang
        .. "'. Set execution.kernel or install a matching kernelspec.")
end

local function prompt_kernel(buf, sess, ev, lang)
    local cfg = core.config.execution
    local entries = {}
    -- The launch-env kernel goes first for python so a bare <Enter> accepts the
    -- zero-config default.
    if cfg.allow_env_kernel and lang == "python" then
        entries[#entries + 1] = {
            label = "Launch env (" .. (persist.find_python() or "python") .. ")",
            act = function() send(sess, { op = "start", env_python = true }) end,
        }
    end
    for _, s in ipairs(ev.specs or {}) do
        entries[#entries + 1] = {
            label = string.format("%s (%s)", s.display_name or s.name, s.name),
            act = function() send(sess, { op = "start", kernel_name = s.name }) end,
        }
    end
    if cfg.allow_attach then
        for _, r in ipairs(ev.running or {}) do
            local base = (r.connection_file or ""):match("([^/]+)$") or r.connection_file
            local kn = (r.kernel_name and r.kernel_name ~= "") and r.kernel_name or "?"
            local la = r.last_activity and (", " .. r.last_activity) or ""
            entries[#entries + 1] = {
                label = string.format("Attach: %s (%s%s)", base, kn, la),
                act = function() send(sess, { op = "attach", connection_file = r.connection_file }) end,
            }
        end
    end
    if #entries == 0 then
        fail(buf, sess, "no kernels available. Install a kernelspec or ipykernel.")
        return
    end
    vim.ui.select(entries, {
        prompt = "Juno: select kernel",
        format_item = function(e) return e.label end,
    }, function(choice)
        if not choice then
            fail(buf, sess, "kernel selection cancelled")
            return
        end
        choice.act()
    end)
end

local function resolve_kernel(buf, sess, ev)
    local state = core.buf_state[buf]
    if not state then return end
    local cfg = core.config.execution
    local lang = nbformat.kernel_language(state.data)

    if cfg.attach and cfg.attach ~= "" then
        local cf = resolve_attach(cfg.attach, ev.running)
        if cf then
            send(sess, { op = "attach", connection_file = cf })
            return
        end
        notify("execution.attach matched no running kernel: " .. cfg.attach, vim.log.levels.WARN)
    end
    if cfg.kernel and cfg.kernel ~= "" then
        send(sess, { op = "start", kernel_name = cfg.kernel })
        return
    end
    if cfg.prompt_for_kernel then
        prompt_kernel(buf, sess, ev, lang)
        return
    end
    auto_kernel(buf, sess, ev, lang)
end

local function dispatch(buf, sess, ev)
    local name = ev.ev
    if name == "output" then
        apply_output(buf, ev.cell_id, ev.output)
    elseif name == "done" then
        apply_done(buf, ev.cell_id, ev.execution_count)
        local cb = sess.pending[ev.cell_id]
        sess.pending[ev.cell_id] = nil
        if cb then pcall(cb, ev) end
    elseif name == "kernels" then
        resolve_kernel(buf, sess, ev)
    elseif name == "ready" then
        sess.ready = true
        sess.kernel_name = ev.kernel_name
        sess.attached = ev.attached
        notify(ev.attached and ("attached to kernel " .. (ev.kernel_name ~= "" and ev.kernel_name or ""))
            or ("kernel ready (" .. (ev.kernel_name or "?") .. ")"))
        local cbs = sess.on_ready
        sess.on_ready = {}
        for _, cb in ipairs(cbs) do pcall(cb) end
    elseif name == "fatal" then
        fail(buf, sess, ev.message or "kernel sidecar failed to start")
    elseif name == "error" then
        notify(ev.message or "kernel error", vim.log.levels.WARN)
    end
end


local function start_session(buf)
    local python = persist.find_python()
    if not python then
        notify("no python interpreter found; cannot start kernel.", vim.log.levels.ERROR)
        return nil
    end
    local script = script_path()
    if not script then
        notify("kernel sidecar (python/juno_kernel.py) not found on runtimepath.", vim.log.levels.ERROR)
        return nil
    end

    local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    local sess = {
        rbuf = "", ready = false, dead = false,
        on_ready = {}, pending = {},
        stdin = stdin, stdout = stdout, stderr = stderr,
    }

    local handle
    handle = uv.spawn(python, {
        args = { script },
        stdio = { stdin, stdout, stderr },
    }, function()
        vim.schedule(function()
            sess.ready = false
            sess.dead = true
            for _, p in ipairs({ stdin, stdout, stderr }) do
                if p and not p:is_closing() then p:close() end
            end
            if handle and not handle:is_closing() then handle:close() end
            local st = core.buf_state[buf]
            if st and st.exec == sess then st.exec = nil end
        end)
    end)

    if not handle then
        notify("failed to spawn python sidecar.", vim.log.levels.ERROR)
        for _, p in ipairs({ stdin, stdout, stderr }) do
            if p and not p:is_closing() then p:close() end
        end
        return nil
    end
    sess.handle = handle

    stdout:read_start(function(err, data)
        if err or not data then return end
        sess.rbuf = sess.rbuf .. data
        while true do
            local nl = sess.rbuf:find("\n")
            if not nl then break end
            local line = sess.rbuf:sub(1, nl - 1)
            sess.rbuf = sess.rbuf:sub(nl + 1)
            if #line > 0 then
                local ok, decoded = pcall(vim.json.decode, line)
                if ok then
                    vim.schedule(function() dispatch(buf, sess, decoded) end)
                end
            end
        end
    end)
    -- Drain stderr so the pipe never blocks the child (debug text only).
    stderr:read_start(function() end)

    -- Tear the kernel down with its buffer, and on exit. Captures sess directly
    -- so it survives buf_state being cleared by the buffer's own handler.
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function() stop_session(sess) end,
    })
    if not _leave_hooked then
        _leave_hooked = true
        vim.api.nvim_create_autocmd("VimLeavePre", {
            callback = function()
                for _, st in pairs(core.buf_state) do
                    if st.exec then stop_session(st.exec) end
                end
            end,
        })
    end

    return sess
end

-- Ensure a ready kernel for buf, then run cb. Queues cb if a kernel is still
-- being provisioned; kicks off spawn + discovery on first call.
local function ensure_kernel(buf, cb)
    local state = core.buf_state[buf]
    if not state then return end
    local sess = state.exec
    if sess and not sess.dead then
        if sess.ready then
            cb()
        else
            table.insert(sess.on_ready, cb)
        end
        return
    end
    sess = start_session(buf)
    if not sess then return end
    state.exec = sess
    table.insert(sess.on_ready, cb)
    send(sess, { op = "discover" })
end

local function gate(buf)
    local cfg = core.config.execution
    if not (cfg and cfg.enabled) then
        notify("execution is disabled (execution.enabled = false).", vim.log.levels.WARN)
        return false
    end
    if not core.buf_state[buf] then
        notify("not a notebook buffer.", vim.log.levels.WARN)
        return false
    end
    if not persist.find_python() then
        notify("python3 is required for execution but was not found on $PATH.", vim.log.levels.ERROR)
        return false
    end
    return true
end

-- Submit one cell's code, clearing its old outputs first. done_cb (optional)
-- fires on that cell's ev:done — used by run_all to sequence cells.
local function submit(buf, nb_id, code, done_cb)
    local state = core.buf_state[buf]
    local sess = state.exec
    local cell = find_cell_by_id(state, nb_id)
    if cell then
        cell.outputs = {}
        cell.execution_count = vim.NIL
        render.render(buf, state.data)
        vim.api.nvim_set_option_value("modified", true, { buf = buf })
    end
    sess.pending[nb_id] = done_cb or function() end
    send(sess, { op = "execute", cell_id = nb_id, code = code })
end

function exec.run_current(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    if not gate(buf) then return end
    local state = core.buf_state[buf]
    persist.sync_buffer(buf)
    local cur = cells.current_cell(buf)
    if not cur or cur.type ~= "code" then
        notify("cursor is not in a code cell.", vim.log.levels.WARN)
        return
    end
    local cell = state.data.cells[cur.id]
    local nb_id = cell.id
    local code = util.get_cell_content(cell.source)
    ensure_kernel(buf, function()
        submit(buf, nb_id, code)
    end)
end

function exec.run_all(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    if not gate(buf) then return end
    local state = core.buf_state[buf]
    persist.sync_buffer(buf)
    local ids = {}
    for _, c in ipairs(state.data.cells or {}) do
        if c.cell_type == "code" then ids[#ids + 1] = c.id end
    end
    if #ids == 0 then
        notify("no code cells to run.", vim.log.levels.WARN)
        return
    end
    ensure_kernel(buf, function()
        local i = 0
        local function step()
            i = i + 1
            local id = ids[i]
            if not id then
                notify("ran " .. #ids .. " code cell(s).")
                return
            end
            local cell = find_cell_by_id(state, id)
            local code = cell and util.get_cell_content(cell.source) or ""
            submit(buf, id, code, function() step() end)
        end
        step()
    end)
end

-- Dispatcher for :Juno run [all] and require("juno").run(arg).
function exec.run(arg)
    if arg == "all" then
        exec.run_all()
    else
        exec.run_current()
    end
end

function exec.stop(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local state = core.buf_state[buf]
    if state and state.exec then
        stop_session(state.exec)
        state.exec = nil
    end
end

return exec
