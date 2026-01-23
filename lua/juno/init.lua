local M = {}

M.config = {}
M.ns_id = vim.api.nvim_create_namespace("juno_cells")
M.state = {
    render_to_raw = {},
    raw_to_render = {},
}

local function get_cell_content(source)
    if type(source) == "table" then
        return table.concat(source, "")
    end
    return source or ""
end

local function clean_lines(text)
    -- Remove the trailing newline if present, to avoid extra spacing in markdown
    if text:sub(-1) == "\n" then
        text = text:sub(1, -2)
    end
    return vim.split(text, "\n")
end

-- Sync content from render_buf back to raw_buf and save
local function sync_and_save(render_buf, raw_buf, data, cell_map)
    local lines = vim.api.nvim_buf_get_lines(render_buf, 0, -1, false)

    -- Update data object from buffer content using extmarks
    for i, cell_idx in ipairs(cell_map) do
        local extmark = vim.api.nvim_buf_get_extmark_by_id(render_buf, M.ns_id, i, { details = true })
        if extmark and #extmark > 0 then
            local start_row = extmark[1]
            local end_row = extmark[3].end_row

            -- Get lines for this cell
            -- Note: end_row is inclusive in extmark details usually, but verify API
            -- Extmark end_row/col is exclusive-ish depending on api. 
            -- Using nvim_buf_get_lines uses 0-indexed, exclusive end.

            -- Adjust for fences if code cell
            local cell_data = data["cells"][cell_idx]
            local content_lines = {}

            if cell_data["cell_type"] == "markdown" then
                content_lines = vim.api.nvim_buf_get_lines(render_buf, start_row, end_row, false)
                -- If the last line is empty and it's just spacing, maybe trim? 
                -- But users might want that space. Let's keep it raw for now.
            else
                -- Code cell: skip first (```python) and last (```) lines of the block
                -- Provided the user hasn't deleted them. 
                -- Safe check:
                local raw_lines = vim.api.nvim_buf_get_lines(render_buf, start_row, end_row, false)
                if #raw_lines >= 2 then
                    if raw_lines[1]:match("^```") then table.remove(raw_lines, 1) end
                    if #raw_lines > 0 and raw_lines[#raw_lines]:match("^```") then table.remove(raw_lines) end
                end
                content_lines = raw_lines
            end

            -- Update source
            -- Jupyter usually expects an array of strings including \n, or a single string.
            -- We'll normalize to a single string with newlines for simplicity or array
            -- Let's stick to array of lines with \n to be perfectly spec compliant? 
            -- Or just one string. Most parsers handle one string.
            -- Let's reconstruct the array of strings with newlines as that is idiomatic ipynb
            local source_arr = {}
            for k, line in ipairs(content_lines) do
                if k < #content_lines then
                    table.insert(source_arr, line .. "\n")
                else
                    table.insert(source_arr, line)
                end
            end
            cell_data["source"] = source_arr
        end
    end

    -- Encode JSON
    local ok, json_str = pcall(vim.fn.json_encode, data)
    if not ok then
        vim.notify("Juno: Failed to encode JSON for save", vim.log.levels.ERROR)
        return
    end

    -- Try to prettify JSON using the neovim python provider; fallback to system python if unavailable - error in worst case
    local python = vim.g.python3_host_prog
    if not python or python == "" then
        vim.notify("Juno: python3_host_prog not set, using system python for JSON formatting", vim.log.levels.WARN)
        python = "python3"
    end
    local pretty_json = vim.fn.system({python , '-m', 'json.tool'}, json_str)
    if vim.v.shell_error == 0 and pretty_json and #pretty_json > 0 then
        json_str = pretty_json
    else
        vim.notify("Juno: Failed to prettify JSON, saving unformatted", vim.log.levels.WARN)
    end

    -- Write to raw buffer
    vim.api.nvim_buf_set_lines(raw_buf, 0, -1, false, vim.split(json_str, "\n"))

    -- Save raw buffer
    vim.api.nvim_buf_call(raw_buf, function()
        vim.cmd("write")
    end)

    -- Reset modified flag on render buffer
    vim.api.nvim_set_option_value("modified", false, { buf = render_buf })
    vim.notify("Juno: Notebook saved", vim.log.levels.INFO)
end

function M.detach()
    local current_buf = vim.api.nvim_get_current_buf()
    local raw_buf = M.state.render_to_raw[current_buf]

    if not raw_buf or not vim.api.nvim_buf_is_valid(raw_buf) then
        vim.notify("Juno: Not attached to a valid notebook buffer", vim.log.levels.WARN)
        return
    end

    -- Switch to raw buffer
    vim.api.nvim_set_current_buf(raw_buf)
    vim.api.nvim_set_option_value("buflisted", true, { buf = raw_buf })

    -- Clean up render buffer
    vim.api.nvim_buf_delete(current_buf, { force = true })
    M.state.render_to_raw[current_buf] = nil
    M.state.raw_to_render[raw_buf] = nil
end

function M.attach(bufname)
    local raw_buf = vim.api.nvim_get_current_buf()

    -- Ensure raw buffer is loaded with file content
    -- If called via BufReadCmd, the buffer is empty initially, we must read the file.
    local file_path = vim.api.nvim_buf_get_name(raw_buf)
    if file_path == "" and bufname then file_path = bufname end

    local content = {}
    if vim.fn.filereadable(file_path) == 1 then
        content = vim.fn.readfile(file_path)
    end
    vim.api.nvim_buf_set_lines(raw_buf, 0, -1, false, content)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = raw_buf }) -- Keep it as nofile or hidden? 
    -- Actually, we want raw_buf to be the "real" file buffer but hidden.
    -- If we use BufReadCmd, we are responsible for setting it up.
    vim.api.nvim_set_option_value("buftype", "", { buf = raw_buf })
    vim.api.nvim_set_option_value("buflisted", false, { buf = raw_buf })
    vim.api.nvim_set_option_value("modified", false, { buf = raw_buf })

    local json_text = table.concat(content, "\n")
    local ok, data = pcall(vim.fn.json_decode, json_text)
    if not ok or type(data) ~= "table" then
        vim.notify("Juno: Invalid notebook file", vim.log.levels.ERROR)
        return
    end

    -- Create render buffer
    local render_buf = vim.api.nvim_create_buf(true, false) -- Listed scratch buffer
    vim.api.nvim_buf_set_name(render_buf, file_path .. ".md")
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = render_buf })

    -- Track state
    M.state.render_to_raw[render_buf] = raw_buf
    M.state.raw_to_render[raw_buf] = render_buf

    -- Render lines & track marks
    local lines = {}
    local cell_map = {} -- Maps extmark_id -> cell_index
    local current_line = 0

    for i, cell in ipairs(data["cells"] or {}) do
        local start_line = current_line

        if cell["cell_type"] == "markdown" then
            local text = get_cell_content(cell["source"])
            local cell_lines = clean_lines(text)
            vim.list_extend(lines, cell_lines)
            current_line = current_line + #cell_lines
        else
            -- Code cell
            table.insert(lines, "```python")
            local text = get_cell_content(cell["source"])
            local cell_lines = clean_lines(text)
            vim.list_extend(lines, cell_lines)
            table.insert(lines, "```")
            current_line = current_line + #cell_lines + 2

            -- Render outputs (read-only theoretically, but just text here)
            if cell["outputs"] then
                 for _, output in ipairs(cell["outputs"]) do
                    if output["output_type"] == "stream" then
                        local out_text = get_cell_content(output["text"])
                        local out_lines = clean_lines(out_text)
                        vim.list_extend(lines, out_lines)
                        current_line = current_line + #out_lines
                    elseif output["output_type"] == "execute_result" and output["data"] and output["data"]["text/plain"] then
                        local out_text = get_cell_content(output["data"]["text/plain"])
                        local out_lines = clean_lines(out_text)
                        vim.list_extend(lines, out_lines)
                        current_line = current_line + #out_lines
                    elseif output["output_type"] == "error" then
                         table.insert(lines, "Error: " .. (output["evalue"] or "unknown"))
                         current_line = current_line + 1
                    end
                end
            end
        end

        -- Add spacer
        table.insert(lines, "")
        current_line = current_line + 1

        -- Set Extmark for this cell (Source content only usually, but let's mark the whole block for now)
        -- We'll just track the source block boundaries for syncing?
        -- Actually, simplest is to mark the whole cell region so we know where it is.
        -- But for syncing back, we only care about the source.
        -- Let's stick to marking the WHOLE cell block (including outputs) so we can preserve order.
        -- But for EDITING, we only sync back the source part.
        -- We need to be careful.

        -- REVISED STRATEGY: 
        -- Just mark the "source" part of the cell for editing?
        -- If user edits outputs, we ignore it? Or revert it?
        -- For now: Mark the whole rendered block.

        -- Extmark is placed at (start_line, 0) extending to (current_line, 0)
        -- We record 'i' (cell index) in the map.
        -- Using ID 'i' directly for extmark ID is convenient.
        -- Note: Extmarks need to be placed AFTER text is set.
        table.insert(cell_map, i)
    end

    vim.api.nvim_buf_set_lines(render_buf, 0, -1, false, lines)

    -- Apply Extmarks
    local line_idx = 0
    for i, cell in ipairs(data["cells"] or {}) do
        local start = line_idx
        local cell_height = 0

        local src_height = #clean_lines(get_cell_content(cell["source"]))
        if cell["cell_type"] == "code" then src_height = src_height + 2 end -- fences

        -- Determine total height including outputs
        local total_height = src_height
        if cell["outputs"] then
             for _, output in ipairs(cell["outputs"]) do
                if output["output_type"] == "stream" then
                    total_height = total_height + #clean_lines(get_cell_content(output["text"]))
                elseif output["output_type"] == "execute_result" and output["data"] then
                    total_height = total_height + #clean_lines(get_cell_content(output["data"]["text/plain"]))
                elseif output["output_type"] == "error" then
                    total_height = total_height + 1
                end
             end
        end

        -- The Extmark should cover the SOURCE part specifically if we want to read it back easily?
        -- Or just cover the whole thing.
        -- Let's cover the source part specifically.
        -- Markdown: 0 to src_height
        -- Code: 0 to src_height (including fences)

        vim.api.nvim_buf_set_extmark(render_buf, M.ns_id, start, 0, {
            end_row = start + src_height,
            id = i, -- Use cell index as ID
        })

        line_idx = line_idx + total_height + 1 -- +1 for spacer
    end

    -- Setup Save Sync
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = render_buf,
        callback = function()
            sync_and_save(render_buf, raw_buf, data, cell_map)
        end,
    })

    -- Cleanup on wipeout
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = render_buf,
        callback = function()
            M.state.render_to_raw[render_buf] = nil
            if vim.api.nvim_buf_is_valid(raw_buf) then
                M.state.raw_to_render[raw_buf] = nil
                -- If we wipe the render buffer, we might want to ensure raw_buf is handled
                -- For now, just clearing state is enough.
            end
        end,
    })

    -- Switch to render buffer
    vim.api.nvim_set_current_buf(render_buf)
end

function M.setup(user_config)
    M.config = vim.tbl_deep_extend("force", {}, user_config or {})

    local group = vim.api.nvim_create_augroup("juno", { clear = true })

    -- Intercept opening of .ipynb files
    vim.api.nvim_create_autocmd({"BufReadCmd"}, {
        pattern = {"*.ipynb"},
        group = group,
        callback = function(ev)
            M.attach(ev.file)
        end,
    })
end

return M
