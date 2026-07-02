-- File watcher: poll the notebook on disk and reload it into the buffer when it
-- changes externally (e.g. after `jupyter run`), unless the buffer has unsaved edits.
local core = require("juno.core")
local render = require("juno.render")
local nbformat = require("juno.nbformat")
local persist = require("juno.persist")

local uv = vim.uv or vim.loop

local watch = {}

function watch.stop(state)
    if state and state.watcher then
        state.watcher:stop()
        if not state.watcher:is_closing() then state.watcher:close() end
        state.watcher = nil
    end
end

-- Re-read the notebook from disk into an already-attached buffer and re-render.
-- Unlike attach() this doesn't touch otter or autocmds; it just refreshes content
-- (render() is idempotent), so it's safe for a background buffer.
local function reload(buf)
    local state = core.buf_state[buf]
    if not state or not vim.api.nvim_buf_is_valid(buf) then return end

    local content = vim.fn.filereadable(state.file_path) == 1 and vim.fn.readfile(state.file_path) or {}
    local ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
    if not ok or type(data) ~= "table" then
        vim.notify("Juno: notebook changed on disk but is not valid JSON; not reloading.", vim.log.levels.WARN)
        return
    end

    nbformat.normalize(data)
    state.data = data
    render.render(buf, data)
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    persist.stamp_disk_mtime(state)
    vim.notify("Juno: reloaded notebook from disk", vim.log.levels.INFO)
end

local function on_disk_change(buf, curr)
    local state = core.buf_state[buf]
    if not state or not vim.api.nvim_buf_is_valid(buf) then return end

    -- Ignore our own writes (and no-op stat changes): sync_and_save re-stamps
    -- disk_mtime after writing, so a matching mtime means nothing external changed.
    local st = curr or uv.fs_stat(state.file_path)
    if st and persist.mtime_eq(st.mtime, state.disk_mtime) then return end

    -- Deferred: no 3-way merge yet, so don't clobber unsaved work.
    if vim.api.nvim_get_option_value("modified", { buf = buf }) then
        vim.notify(
            "Juno: notebook changed on disk but the buffer has unsaved edits; not reloading. "
                .. "Save (:w overwrites disk) or discard and :edit to reload.",
            vim.log.levels.WARN
        )
        -- Update the stamp so we don't nag again for this same on-disk version.
        state.disk_mtime = st and st.mtime or state.disk_mtime
        return
    end

    reload(buf)
end

function watch.start(buf, file_path)
    local state = core.buf_state[buf]
    if not state then return end
    watch.stop(state)
    persist.stamp_disk_mtime(state)

    local poll = uv.new_fs_poll()
    if not poll then return end
    state.watcher = poll
    -- fs_poll (stat-based) rather than fs_event so we survive atomic-rename
    -- writes (nbconvert/jupyter replace the file, which breaks inode watches).
    poll:start(file_path, 1000, function(err, _prev, curr)
        if err then return end
        vim.schedule(function() on_disk_change(buf, curr) end)
    end)
end

return watch
