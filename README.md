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
- Run cells in-editor (`:Juno run` / `:Juno run all`) against a Jupyter kernel;
  outputs land in the model, render inline, and persist on `:w`. Start a kernel
  in your launch environment, pick from installed kernelspecs, or attach to an
  already-running kernel.
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
- `python3` on `$PATH` - **required**. Juno pretty-prints saved notebooks to
  canonical `nbformat` JSON via `python -m json.tool`, and cell execution runs a
  python sidecar. Juno prefers the interpreter nvim was launched with (your
  project venv/nix-shell), falling back to `vim.g.python3_host_prog`.
  (Notebook *normalization* is pure Lua and needs no python packages.)
- `jupyter_client` and `ipykernel` in that environment - required only for cell
  execution (`:Juno run`). Install them where your notebook packages live.

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
  -- In-editor cell execution (:Juno run [all]) via the juno_kernel.py sidecar.
  execution = {
    enabled = true,
    kernel = nil,              -- force a registered kernelspec by name (skips prompt)
    attach = nil,              -- attach by connection-file path or kernel id (skips prompt)
    kernel_map = { python = "python3" }, -- language -> kernelspec, used when not prompting
    prompt_for_kernel = true,  -- vim.ui.select the kernel on first run
    allow_env_kernel = true,   -- allow the ephemeral launch-env kernel (no kernelspec install)
    prefer_env_python = true,  -- default python to the env kernel when not prompting
    allow_attach = true,       -- allow attaching to already-running kernels
  },
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
| `:Juno run [all]` | Run the current code cell, or every code cell |
| `:Juno interrupt` | Interrupt the running kernel (stops the in-flight cell) |
| `:Juno kernels` | Switch the buffer's kernel (re-prompts; outputs are kept) |

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

## Tests

The suite lives in `tests/` and runs in parallel:

```sh
tests/run.sh          # unit tests always; execution tests if python can import
                      # jupyter_client + ipykernel
tests/run.sh unit     # only the no-kernel unit tests
```

Unit tests (cell-id tracking, structural cell ops, nbformat helpers) need only
`nvim`. The execution tests (run/interrupt/kernel re-pick) and the Python
sidecar test need `jupyter_client` and `ipykernel` importable by the `python3`
on `$PATH`, so run them from a shell where your kernel environment is active.

Each test is an isolated process with its own kernel; test kernels use a private
Jupyter runtime dir and are cleaned up when the run ends.

## Running notebooks

Juno runs cells against a Jupyter kernel through a small python sidecar
(`python/juno_kernel.py`) that it spawns with your launch-environment
interpreter. Put the cursor in a code cell and:

- `:Juno run` - run the current code cell
- `:Juno run all` - run every code cell in order

Outputs (stdout/stderr, results, errors) are captured into the notebook model,
render inline like any stored output, and persist on `:w`.

On the first run in a notebook Juno prompts (`vim.ui.select`) for a kernel:

- **Launch env** - start a fresh kernel using the interpreter nvim was launched
  with (no kernelspec install needed); requires `ipykernel` in that environment.
  Listed first for python, so a bare `<Enter>` accepts it.
- **A registered kernelspec** - any kernel from `jupyter kernelspec list`.
- **Attach** - connect to an already-running kernel (e.g. a `jupyter console` or
  server), sharing its live variables. Juno never shuts down a kernel it
  attached to.

Configure this via the `execution` table (see [Configuration](#configuration)):
set `kernel`/`attach` to skip the prompt, `prompt_for_kernel = false` to always
use the launch-env kernel, or `allow_env_kernel = false` to require a registered
kernelspec.

Requires `jupyter_client` and `ipykernel` in the launch environment. You can
still execute a notebook out-of-editor and let Juno's file watcher pick up the
results (`jupyter nbconvert --to notebook --execute --inplace notebook.ipynb`).
