local M = {}

function M.check()
    vim.health.start("juno.nvim report")

    -- 1. Check Neovim version
    if vim.fn.has("nvim-0.10.0") == 1 then
        vim.health.ok("Neovim version is compatible (>= 0.10.0)")
    else
        vim.health.error("Neovim version is too old (< 0.10.0). Juno requires Neovim 0.10+.")
    end

    -- 2. Check render-markdown.nvim
    if pcall(require, "render-markdown") then
        vim.health.ok("render-markdown.nvim is installed")
    else
        vim.health.error(
            "render-markdown.nvim is missing (required)",
            "Install 'MeanderingProgrammer/render-markdown.nvim' using your plugin manager."
        )
    end

    -- 3. Check otter.nvim (optional)
    if pcall(require, "otter") then
        vim.health.ok("otter.nvim is installed (optional completion/diagnostics)")
    else
        vim.health.info("otter.nvim is not installed (optional completion/diagnostics are disabled)")
    end

    -- 4. Check python3 executable and dependencies
    local persist = require("juno.persist")
    local python = persist.find_python()
    if python then
        vim.health.ok("Python executable found: " .. python)

        -- Check python imports
        local deps = { "jupyter_client", "ipykernel", "markdownify" }
        local missing = {}
        for _, dep in ipairs(deps) do
            local cmd = { python, "-c", "import " .. dep }
            vim.fn.system(cmd)
            if vim.v.shell_error == 0 then
                vim.health.ok("Python module '" .. dep .. "' is installed")
            else
                table.insert(missing, dep)
            end
        end

        if #missing == 0 then
            vim.health.ok("All python dependencies are installed (execution ready)")
        else
            vim.health.warn(
                "Some python dependencies are missing: " .. table.concat(missing, ", "),
                "Install them in your environment to enable cell execution: pip install " .. table.concat(missing, " ")
            )
        end
    else
        vim.health.error(
            "python3 executable not found on PATH or g:python3_host_prog",
            "Install python3 or set vim.g.python3_host_prog to your python3 path."
        )
    end
end

return M
