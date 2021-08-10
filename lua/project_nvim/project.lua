local config = require("project_nvim.config")
local history = require("project_nvim.utils.history")
local M = {}

-- Internal states
M.attached_lsp = false
M.last_project = nil

function M.find_lsp_root()
  -- Get lsp client for current buffer
  -- Returns nil or string
  local buf_ft = vim.api.nvim_buf_get_option(0, 'filetype')
  local clients = vim.lsp.buf_get_clients()
  if next(clients) == nil then
    return nil
  end

  for _, client in pairs(clients) do
    local filetypes = client.config.filetypes
    if filetypes and vim.fn.index(filetypes, buf_ft) ~= -1 then
      return client.config.root_dir
    end
  end

  return nil
end

function M.find_pattern_root()
  local work_ctx = vim.loop.new_work(function(search_dir, ...)
    local uv = require("luv")
    local patterns = {...}

    local last_dir_cache = ""
    local curr_dir_cache = {}

    local function get_parent(path)
      path = path:match("^(.*)/")
      if path == "" then
          path = "/"
      end
      return path
    end

    local function get_files(file_dir)
      last_dir_cache = file_dir
      curr_dir_cache = {}

      local dir = uv.fs_scandir(file_dir)
      if dir == nil then
        return
      end

      while true do
        local file = uv.fs_scandir_next(dir)
        if file == nil then
          return
        end

        table.insert(curr_dir_cache, file)
      end
    end

    local function is(dir, identifier)
      dir = dir:match(".*/(.*)")
      return dir == identifier
    end

    local function sub(dir, identifier)
      local path = get_parent(dir)
      while true do
        if is(path, identifier) then return true end
        local current = path
        path = get_parent(path)
        if current == path then
          return false
        end
      end
    end

    local function child(dir, identifier)
      local path = get_parent(dir)
      return is(path, identifier)
    end

    local function has(dir, identifier)
      if last_dir_cache ~= dir then
        get_files(dir)
      end
      for _, file in ipairs(curr_dir_cache) do
        if file:match(identifier) == file then
          return true
        end
      end
      return false
    end

    local function match(dir, pattern)
      local first_char = pattern:sub(1, 1)
      if first_char == '=' then
        return is(dir, pattern:sub(2))
      elseif first_char == '^' then
        return sub(dir, pattern:sub(2))
      elseif first_char == '>' then
        return child(dir, pattern:sub(2))
      else
        return has(dir, pattern)
      end
    end

    -- breadth-first search
    while true do
      for _, pattern in ipairs(patterns) do
        local exclude = false
        if pattern:sub(1, 1) == "!" then
          exclude = true
          pattern = pattern:sub(2)
        end
        if match(search_dir, pattern) then
          if exclude then
            break
          else
            return search_dir, pattern
          end
        end
      end

      local parent = get_parent(search_dir)
      if parent == search_dir then
        return nil
      end

      search_dir = parent
    end

    return 1 -- must return something otherwise Segmentation fault: #561 luv
  end, vim.schedule_wrap(function(path, pattern)
    if type(path) == "string" then
      M.set_pwd(path, "pattern " .. pattern)
    end
  end))

  local file_dir = vim.fn.expand('%:p:h', true)
  work_ctx:queue(file_dir, unpack(config.options.patterns))
end

---@diagnostic disable-next-line: unused-local
local on_attach_lsp = function(client, bufnr)
  M.on_buf_enter() -- Recalculate root dir after lsp attaches
end

function M.attach_to_lsp()
  if M.attached_lsp then
    return
  end

  local _start_client = vim.lsp.start_client
  vim.lsp.start_client = function(lsp_config)
    if lsp_config.on_attach == nil then
      lsp_config.on_attach = on_attach_lsp
    else
      local _on_attach = lsp_config.on_attach
      lsp_config.on_attach = function(client, bufnr)
        on_attach_lsp(client, bufnr)
        _on_attach(client, bufnr)
      end
    end
    return _start_client(lsp_config)
  end

  M.attached_lsp = true
end

function M.set_pwd(dir, method)
  if dir ~= nil then
    M.last_project = dir
    table.insert(history.session_projects, dir)

    if vim.fn.getcwd() ~= dir then
      vim.api.nvim_set_current_dir(dir)

      -- NvimTree integration
      local status, nvim_tree = pcall(require, "nvim-tree.lib")
      if status then
        pcall(nvim_tree.change_dir, dir)
      end

      if config.options.silent_chdir == false then
        print("Set CWD to", dir, "using", method)
      end
    end
    return true
  end

  return false
end

function M.is_file()
  local buf_type = vim.api.nvim_buf_get_option(0, "buftype")
  local buf_name = vim.api.nvim_buf_get_name(0)

  local whitelisted_buf_type = { "", "acwrite" }
  local is_in_whitelist = false
  for _, wtype in ipairs(whitelisted_buf_type) do
    if buf_type == wtype then
      is_in_whitelist = true
      break
    end
  end
  if not is_in_whitelist then
    return false
  end

  if buf_name == "" then
    return false
  end

  return true
end

function M.on_buf_enter()
  if vim.v.vim_did_enter == 0 then
    return
  end

  if not M.is_file() then
    return
  end

  for _, detection_method in ipairs(config.options.detection_methods) do
    if detection_method == "lsp" then
      local root = M.find_lsp_root()
      if root ~= nil then
        M.set_pwd(root, "lsp")
        return -- avoid any further calculations if lsp found
      end
    elseif detection_method == "pattern" then
      M.find_pattern_root()
    end
  end
end

function M.init()
  vim.cmd [[
    autocmd VimEnter,BufEnter * lua require("project_nvim.project").on_buf_enter()
    autocmd VimLeave * lua require("project_nvim.utils.history").write_projects_to_history()
  ]]

  for _, detection_method in ipairs(config.options.detection_methods) do
    if detection_method == "lsp" then
      M.attach_to_lsp()
    end
  end

  history.read_projects_from_history()
end

return M
