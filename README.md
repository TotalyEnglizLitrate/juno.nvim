# juno.nvim

Edit Jupyter notebooks (`.ipynb`) in Neovim as an ordinary Markdown buffer -
code cells become fenced blocks, outputs render inline, and full LSP works
inside cells via [otter.nvim](https://github.com/jmbuhr/otter.nvim).

Juno stores the notebook model in memory and renders it into the buffer; `:w`
writes it back as valid `nbformat` 4.5. It is an **editor**, not a kernel - see
[Running notebooks](#running-notebooks).

## Features

- Notebooks open as Markdown, rendered with
  [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim):
  code cells fenced, markdown/raw cells plain.
- Cell outputs (stdout/stderr, results, errors + tracebacks) shown as virtual
  lines with a distinct left rail.
- Cell numbers as inline hints.
- LSP inside code cells (hover, definition, references, rename, format,
  completion, diagnostics) through otter - standard `vim.lsp.buf.*` mappings
  just work.
- Cell operations: create, delete, move, change type, merge, split, clear
  outputs, yank/paste.
- Stable per-cell ids and non-destructive `nbformat` normalization on load.
- New/empty `.ipynb` files are seeded with a base notebook.
- Watches the file on disk and reloads on external changes (e.g. after running
  the notebook elsewhere).

## Requirements

- Neovim 0.10+
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
  - **required**. Juno renders notebooks into a Markdown buffer and relies on it
  for the display (fences, headings, conceal).
- [otter.nvim](https://github.com/jmbuhr/otter.nvim) - optional, required only
  for the in-cell LSP features.
- `python3` on `$PATH` - optional; used only to pretty-print the saved JSON.
  Without it, notebooks still save as valid (compact) JSON.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "TotalyEnglizLitrate/juno.nvim",
  dependencies = {
    "MeanderingProgrammer/render-markdown.nvim", -- required
    "jmbuhr/otter.nvim",                          -- optional, for LSP in cells
  },
  -- Load eagerly: Juno registers a BufReadCmd for *.ipynb, which must exist
  -- before you open a notebook (filetype-based lazy-loading fires too late).
  lazy = false,
  opts = {},
}
```

With [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use({
  "TotalyEnglizLitrate/juno.nvim",
  requires = {
    "MeanderingProgrammer/render-markdown.nvim", -- required
    "jmbuhr/otter.nvim",                          -- optional, for LSP in cells
  },
  config = function() require("juno").setup() end,
})
```

`setup()` registers autocommands for `*.ipynb`, so opening any notebook attaches
Juno automatically.

## Configuration

`setup()` takes a table; these are the defaults:

```lua
require("juno").setup({
  -- In-cell LSP via otter.nvim.
  otter = {
    enabled = true,
    completion = true,
    diagnostics = true,
  },
  -- Poll the file and reload when it changes on disk (e.g. after `jupyter run`).
  watch = true,
  -- Left-rail glyph prefixed to every output line (highlight: JunoOutputMarker).
  output_rail = "▎ ",
})
```

## Usage

Open any `.ipynb` file and Juno renders it. Editing cell text and `:w` saves the
notebook back to disk.

### Commands

All functionality is under the `:Juno` command (with tab-completion):

| Command | Description |
| --- | --- |
| `:Juno attach <file>` | Attach/render a notebook in the current buffer |
| `:Juno detach` | Replace the rendered buffer with the raw JSON |
| `:Juno next` / `:Juno prev` | Jump to the next / previous cell |
| `:Juno goto <n>` | Jump to cell *n* (1-indexed) |
| `:Juno new [code\|markdown\|raw]` | Create a cell (prompts for type if omitted) |
| `:Juno delete` | Delete the current cell |
| `:Juno move [up\|down]` | Move the current cell (default: down) |
| `:Juno type [code\|markdown\|raw]` | Change cell type (toggles code/markdown if omitted) |
| `:Juno merge [up\|down]` | Merge with a neighbor (default: down) |
| `:Juno split` | Split the current cell at the cursor line |
| `:Juno clear [all]` | Clear outputs of the current cell, or of all cells |
| `:Juno yank` | Copy the current cell to Juno's cell clipboard |
| `:Juno paste [above\|below]` | Paste the yanked cell (default: below) |

### Keymaps

Juno ships **no default keymaps**. Bind the Lua API to whatever you like, e.g.:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "markdown", -- notebook buffers are filetype=markdown
  callback = function(ev)
    if not require("juno").buf_state[ev.buf] then return end
    local juno = require("juno")
    local map = function(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = ev.buf }) end
    map("]c", juno.next_cell)
    map("[c", juno.prev_cell)
    map("<leader>ja", function() juno.new_cell({ where = "above" }) end)
    map("<leader>jb", function() juno.new_cell({ where = "below" }) end)
    map("<leader>jd", juno.delete_cell)
    map("<leader>js", juno.split_cell)
    map("<leader>jm", function() juno.merge_cell(1) end)
    map("<leader>jc", juno.clear_outputs)
  end,
})
```

### LSP in cells

With `otter.enabled` and otter.nvim installed, standard LSP mappings work inside
code cells with no extra setup - `vim.lsp.buf.hover()`, `vim.lsp.buf.definition()`,
etc. are routed through otter automatically, and your `LspAttach` handler runs for
the notebook buffer so your usual keymaps apply.

The same actions are also exposed directly: `require("juno").hover()`,
`.definition()`, `.type_definition()`, `.references()`, `.rename()`, `.format()`,
`.document_symbols()`.

## Highlights

Output highlight groups are defined as overridable links (your definitions win)
and re-applied on `:colorscheme`:

| Group | Default | Used for |
| --- | --- | --- |
| `JunoOutputMarker` | `Special` | the left rail on each output line |
| `JunoOutput` | `Normal` | stream (stdout/stderr) text |
| `JunoOutputResult` | `Normal` | `execute_result` (return value) text |
| `JunoOutputError` | `DiagnosticError` | errors and tracebacks |

Override as usual:

```lua
vim.api.nvim_set_hl(0, "JunoOutput", { link = "Comment" })
vim.api.nvim_set_hl(0, "JunoOutputMarker", { fg = "#89b4fa" })
```

## Running notebooks

Juno does not run kernels yet. It renders whatever outputs are stored in the
file. To execute a notebook, use the standard Jupyter tools and let Juno's file
watcher pick up the results:

```sh
jupyter nbconvert --to notebook --execute --inplace notebook.ipynb
# or
jupyter execute notebook.ipynb
```

In-editor execution is planned.
