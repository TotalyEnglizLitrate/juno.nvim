-- Persistence: pull buffer edits back into the model (sync_buffer), and encode +
-- pretty-print + write the notebook to disk (sync_and_save). Also owns the on-disk
-- mtime helpers the watcher uses to distinguish our own writes from external ones.
local core = require("juno.core")
local util = require("juno.util")

local uv = vim.uv or vim.loop

local persist = {}

-- Pull the current buffer text back into state.data.cells[].source, stripping the
-- fences juno adds around code cells. Run before re-rendering so unsaved edits survive.
function persist.sync_buffer(buf)
    local state = core.buf_state[buf]
    if not state then return end

    for i, cell in ipairs(state.data.cells or {}) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(buf, core.ns.src, i, { details = true })
        if mark and #mark > 0 then
            local start_row = mark[1]
            local end_row = mark[3].end_row
            local raw = vim.api.nvim_buf_get_lines(buf, start_row, end_row, false)

            if cell.cell_type == "code" then
                if #raw >= 1 and raw[1]:match("^```") then table.remove(raw, 1) end
                if #raw >= 1 and raw[#raw]:match("^```") then table.remove(raw) end
            end

            cell.source = util.lines_to_source(raw)
        end
    end
end

-- Find a usable python interpreter. Prefer the one on $PATH (the project's active
-- venv/nix-shell/devbox that nvim was launched in, which is where notebook packages
-- like nbformat live) over g:python3_host_prog, which is typically a dedicated
-- pynvim venv and often lacks project dependencies. Returns nil if none exist.
local function find_python()
    local candidates = { "python3", "python" }
    if vim.g.python3_host_prog and vim.g.python3_host_prog ~= "" then
        table.insert(candidates, vim.g.python3_host_prog)
    end
    for _, exe in ipairs(candidates) do
        if vim.fn.executable(exe) == 1 then return exe end
    end
    return nil
end

-- Exposed so the execution sidecar (juno.exec) spawns the same launch-env
-- interpreter used for json.tool, keeping env resolution in one place.
persist.find_python = find_python

-- Pretty-print JSON via python's json.tool for Jupyter-compatible formatting.
-- Falls back to the (compact but valid) input if python is missing or errors,
-- warning the user that the notebook was saved without pretty formatting.
local warned_no_python = false
local function pretty_json(json_str)
    local python = find_python()
    if not python then
        if not warned_no_python then
            warned_no_python = true
            vim.notify(
                "Juno: no python interpreter found; saving notebook without pretty formatting. "
                    .. "Set vim.g.python3_host_prog or install python3 to enable it.",
                vim.log.levels.WARN
            )
        end
        return json_str
    end

    local pretty = vim.fn.system({ python, "-m", "json.tool" }, json_str)
    if vim.v.shell_error == 0 and pretty and #pretty > 0 then
        return pretty
    end

    vim.notify(
        "Juno: json.tool formatting failed; saved without pretty formatting."
            .. (pretty and #pretty > 0 and ("\n" .. vim.trim(pretty)) or ""),
        vim.log.levels.WARN
    )
    return json_str
end

function persist.mtime_eq(a, b)
    return a ~= nil and b ~= nil and a.sec == b.sec and a.nsec == b.nsec
end

-- Record the file's current mtime so the watcher can tell our own writes apart
-- from external changes. Call after every save.
function persist.stamp_disk_mtime(state)
    local st = uv.fs_stat(state.file_path)
    state.disk_mtime = st and st.mtime or nil
end

function persist.sync_and_save(buf)
    local state = core.buf_state[buf]
    if not state then return end

    persist.sync_buffer(buf)

    local ok, json_str = pcall(vim.fn.json_encode, state.data)
    if not ok then
        vim.notify("Juno: JSON encode failed", vim.log.levels.ERROR)
        return
    end

    json_str = pretty_json(json_str)

    local f = io.open(state.file_path, "w")
    if not f then
        vim.notify("Juno: Cannot write to " .. state.file_path, vim.log.levels.ERROR)
        return
    end
    f:write(json_str)
    f:close()

    -- Record the mtime we just wrote so the file watcher doesn't treat our own
    -- save as an external change and reload over it.
    persist.stamp_disk_mtime(state)

    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.notify("Juno: Notebook saved", vim.log.levels.INFO)
end

return persist
