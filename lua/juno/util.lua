-- Pure text helpers for converting between nbformat `source` (a string or list of
-- lines) and plain line lists. No juno state.
local util = {}

function util.get_cell_content(source)
    if type(source) == "table" then
        return table.concat(source, "")
    end
    return source or ""
end

function util.clean_lines(text)
    if text:sub(-1) == "\n" then
        text = text:sub(1, -2)
    end
    return vim.split(text, "\n")
end

-- Convert a list of plain lines into an nbformat `source` array: every line but
-- the last carries a trailing newline.
function util.lines_to_source(lines)
    local source = {}
    for k, line in ipairs(lines) do
        source[k] = (k < #lines) and (line .. "\n") or line
    end
    return source
end

return util
