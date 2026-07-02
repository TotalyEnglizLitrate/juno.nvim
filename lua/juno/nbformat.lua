-- nbformat concerns: notebook normalization, cell construction, and stable cell
-- ids. Kept dependency-free (pure Lua + vim built-ins) so it never relies on a
-- project python having the nbformat package available.
local nb = {}

local uv = vim.uv or vim.loop

-- We target nbformat 4.5, which requires a per-cell `id`.
nb.NBFORMAT = 4
nb.NBFORMAT_MINOR = 5

local ID_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

-- Seed once at load. Date/random are available in the nvim runtime (unlike the
-- workflow sandbox); hrtime gives a high-resolution, per-launch-unique seed.
math.randomseed(uv.hrtime() % 2147483647)

local function random_id()
    local chars = {}
    for i = 1, 8 do
        local n = math.random(1, #ID_CHARS)
        chars[i] = ID_CHARS:sub(n, n)
    end
    return table.concat(chars)
end

-- Set of ids already used by cells, so generated ids stay unique within a notebook.
function nb.taken_ids(cells)
    local taken = {}
    for _, cell in ipairs(cells or {}) do
        if type(cell.id) == "string" then taken[cell.id] = true end
    end
    return taken
end

-- Generate a cell id not present in `taken` (a set from taken_ids). Does not
-- mutate `taken` — the caller adds the returned id if it keeps generating more.
function nb.gen_id(taken)
    local id = random_id()
    while taken and taken[id] do
        id = random_id()
    end
    return id
end

-- Build a fresh, valid nbformat cell. `id` should come from gen_id; one is
-- generated if omitted. metadata must be a JSON object, so vim.empty_dict()
-- (an empty Lua table would encode as `[]`); source/outputs are arrays.
function nb.make_cell(cell_type, id)
    id = id or nb.gen_id(nil)
    if cell_type == "markdown" then
        return { id = id, cell_type = "markdown", metadata = vim.empty_dict(), source = {} }
    end
    return {
        id = id,
        cell_type = "code",
        metadata = vim.empty_dict(),
        source = {},
        outputs = {},
        execution_count = vim.NIL,
    }
end

-- Bring a decoded notebook up to a valid nbformat 4.5 shape in place. Non-
-- destructive: it fills/coerces required fields but never strips unknown ones.
--   * required top-level fields (cells, nbformat, nbformat_minor, metadata-as-object)
--   * per-cell: metadata-as-object, a stable string `id`
--   * code cells: `outputs` list + `execution_count` key (null if absent)
--   * non-code cells: drop code-only fields (outputs/execution_count)
-- Empty Lua tables encode as `[]`, so empty metadata must be forced to a dict.
function nb.normalize(data)
    data.cells = data.cells or {}
    data.nbformat = data.nbformat or nb.NBFORMAT
    data.nbformat_minor = data.nbformat_minor or nb.NBFORMAT_MINOR
    if type(data.metadata) ~= "table" or vim.tbl_isempty(data.metadata) then
        data.metadata = vim.empty_dict()
    end

    local taken = nb.taken_ids(data.cells)
    for _, cell in ipairs(data.cells) do
        if type(cell.metadata) ~= "table" or vim.tbl_isempty(cell.metadata) then
            cell.metadata = vim.empty_dict()
        end
        if type(cell.source) == "string" then
            cell.source = { cell.source }
        end
        if type(cell.id) ~= "string" or cell.id == "" then
            local id = nb.gen_id(taken)
            taken[id] = true
            cell.id = id
        end
        if cell.cell_type == "code" then
            if type(cell.outputs) ~= "table" then cell.outputs = {} end
            if cell.execution_count == nil then cell.execution_count = vim.NIL end
        else
            cell.outputs = nil
            cell.execution_count = nil
        end
    end
    return data
end

return nb
