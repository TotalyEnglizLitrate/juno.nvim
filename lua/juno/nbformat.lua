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

-- Build a fresh, valid nbformat cell of the given type ("code", "markdown", or
-- "raw"). `id` should come from gen_id; one is generated if omitted. metadata must
-- be a JSON object, so vim.empty_dict() (an empty Lua table would encode as `[]`);
-- source/outputs are arrays. Only code cells carry outputs/execution_count.
function nb.make_cell(cell_type, id)
    id = id or nb.gen_id(nil)
    if cell_type == "code" then
        return {
            id = id,
            cell_type = "code",
            metadata = vim.empty_dict(),
            source = {},
            outputs = {},
            execution_count = vim.NIL,
        }
    end
    return { id = id, cell_type = cell_type, metadata = vim.empty_dict(), source = {} }
end

-- The cell in `cells` with the given stable nbformat id, or nil. This is the
-- identity lookup that pairs with the positional `cells[i]` access.
function nb.cell_by_id(cells, id)
    for _, cell in ipairs(cells or {}) do
        if cell.id == id then return cell end
    end
    return nil
end

-- The 1-based position of the cell with the given nbformat id, or nil.
function nb.index_by_id(cells, id)
    for i, cell in ipairs(cells or {}) do
        if cell.id == id then return i end
    end
    return nil
end

-- The declared kernel language, or nil if the notebook doesn't specify one.
function nb.declared_language(data)
    local m = data.metadata
    return m and (
        (m.kernelspec and m.kernelspec.language) or
        (m.language_info and m.language_info.name)
    ) or nil
end

-- The kernel language, defaulting to python when the notebook declares none.
function nb.kernel_language(data)
    return nb.declared_language(data) or "python"
end

-- Record a notebook-level kernel language into metadata so render()'s fences and
-- otter activation stay consistent. juno supports a single language per notebook.
function nb.set_declared_language(data, lang)
    data.metadata = data.metadata or {}
    data.metadata.language_info = data.metadata.language_info or {}
    data.metadata.language_info.name = lang
end

-- A fresh, valid notebook seeded with one empty code cell — mirrors VSCode's
-- "New Jupyter Notebook" (ipynb.newUntitledIpynb). Used when juno opens a missing
-- or blank .ipynb so the user has a cell to type into immediately.
function nb.new_notebook()
    return {
        cells = { nb.make_cell("code") },
        metadata = vim.empty_dict(),
        nbformat = nb.NBFORMAT,
        nbformat_minor = nb.NBFORMAT_MINOR,
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
