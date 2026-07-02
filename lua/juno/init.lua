local M = {}

M.config = {}
M.ns_src = vim.api.nvim_create_namespace("juno_src")
M.ns_out = vim.api.nvim_create_namespace("juno_out")
M.buf_state = {}

local function get_cell_content(source)
    if type(source) == "table" then
        return table.concat(source, "")
    end
    return source or ""
end

local function clean_lines(text)
    if text:sub(-1) == "\n" then
        text = text:sub(1, -2)
    end
    return vim.split(text, "\n")
end

local function kernel_language(data)
    local m = data.metadata
    return (m and (
        (m.kernelspec and m.kernelspec.language) or
        (m.language_info and m.language_info.name)
    )) or "python"
end

local function output_to_virt_lines(output)
    local vlines = {}
    if output.output_type == "stream" then
        for _, line in ipairs(clean_lines(get_cell_content(output.text))) do
            table.insert(vlines, { { line, "Comment" } })
        end
    elseif output.output_type == "execute_result" and output.data and output.data["text/plain"] then
        for _, line in ipairs(clean_lines(get_cell_content(output.data["text/plain"]))) do
            table.insert(vlines, { { line, "String" } })
        end
    elseif output.output_type == "error" then
        table.insert(vlines, { { "Error: " .. (output.evalue or "unknown"), "ErrorMsg" } })
        for _, tb in ipairs(output.traceback or {}) do
            table.insert(vlines, { { tb:gsub("\27%[[%d;]*m", ""), "ErrorMsg" } })
        end
    end
    return vlines
end

local function render(buf, data)
    local lang = kernel_language(data)
    local lines = {}
    local cell_pos = {}
    local idx = 0

    for i, cell in ipairs(data.cells or {}) do
        local start = idx
        local src = clean_lines(get_cell_content(cell.source))
        local h

        if cell.cell_type == "markdown" then
            vim.list_extend(lines, src)
            h = #src
        else
            table.insert(lines, "```" .. lang)
            vim.list_extend(lines, src)
            table.insert(lines, "```")
            h = #src + 2
        end

        table.insert(lines, "")
        idx = idx + h + 1
        cell_pos[i] = { start = start, h = h }
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    for i, cell in ipairs(data.cells or {}) do
        local pos = cell_pos[i]

        vim.api.nvim_buf_set_extmark(buf, M.ns_src, pos.start, 0, {
            end_row = pos.start + pos.h,
            id = i,
        })

        if cell.cell_type == "code" and cell.outputs and #cell.outputs > 0 then
            local vlines = {}
            for _, out in ipairs(cell.outputs) do
                vim.list_extend(vlines, output_to_virt_lines(out))
            end
            if #vlines > 0 then
                vim.api.nvim_buf_set_extmark(buf, M.ns_out, pos.start + pos.h - 1, 0, {
                    virt_lines = vlines,
                })
            end
        end
    end
end

local function sync_and_save(buf)
    local state = M.buf_state[buf]
    if not state then return end

    for i, cell in ipairs(state.data.cells or {}) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(buf, M.ns_src, i, { details = true })
        if mark and #mark > 0 then
            local start_row = mark[1]
            local end_row = mark[3].end_row
            local raw = vim.api.nvim_buf_get_lines(buf, start_row, end_row, false)

            if cell.cell_type == "code" then
                if #raw >= 1 and raw[1]:match("^```") then table.remove(raw, 1) end
                if #raw >= 1 and raw[#raw]:match("^```") then table.remove(raw) end
            end

            local source = {}
            for k, line in ipairs(raw) do
                source[k] = (k < #raw) and (line .. "\n") or line
            end
            cell.source = source
        end
    end

    local ok, json_str = pcall(vim.fn.json_encode, state.data)
    if not ok then
        vim.notify("Juno: JSON encode failed", vim.log.levels.ERROR)
        return
    end

    local python = (vim.g.python3_host_prog and vim.g.python3_host_prog ~= "") and vim.g.python3_host_prog or "python3"
    local pretty = vim.fn.system({ python, "-m", "json.tool" }, json_str)
    if vim.v.shell_error == 0 and pretty and #pretty > 0 then
        json_str = pretty
    end

    local f = io.open(state.file_path, "w")
    if not f then
        vim.notify("Juno: Cannot write to " .. state.file_path, vim.log.levels.ERROR)
        return
    end
    f:write(json_str)
    f:close()

    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    vim.notify("Juno: Notebook saved", vim.log.levels.INFO)
end

function M.attach(file_path)
    local buf = vim.api.nvim_get_current_buf()

    local content = vim.fn.filereadable(file_path) == 1 and vim.fn.readfile(file_path) or {}
    local ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
    if not ok or type(data) ~= "table" then
        vim.notify("Juno: Invalid notebook file", vim.log.levels.ERROR)
        return
    end

    vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

    M.buf_state[buf] = { file_path = file_path, data = data }
    render(buf, data)
    vim.api.nvim_set_option_value("modified", false, { buf = buf })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function() sync_and_save(buf) end,
    })

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        callback = function() M.buf_state[buf] = nil end,
    })
end

function M.detach()
    local buf = vim.api.nvim_get_current_buf()
    local state = M.buf_state[buf]
    if not state then
        vim.notify("Juno: Not a notebook buffer", vim.log.levels.WARN)
        return
    end

    local raw_buf = vim.api.nvim_create_buf(true, true)
    local content = vim.fn.filereadable(state.file_path) == 1 and vim.fn.readfile(state.file_path) or {}
    vim.api.nvim_buf_set_lines(raw_buf, 0, -1, false, content)
    vim.api.nvim_set_option_value("filetype", "json", { buf = raw_buf })

    vim.api.nvim_set_current_buf(raw_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
end

function M.setup(user_config)
    M.config = vim.tbl_deep_extend("force", {}, user_config or {})

    local group = vim.api.nvim_create_augroup("juno", { clear = true })
    vim.api.nvim_create_autocmd("BufReadCmd", {
        pattern = "*.ipynb",
        group = group,
        callback = function(ev) M.attach(ev.file) end,
    })
end

return M
