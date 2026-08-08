local M = {}

M.FIELD_SEPARATOR = "ඞjjk"
M.RECORD_SEPARATOR = "jjkඞ\n"
M.FILE_SEPARATOR = "j@j@k"
M.FILE_FIELD_SEPARATOR = "@?!"

local function get_jj_config_path()
  local paths = vim.api.nvim_get_runtime_file(
    "jj-config.toml",
    false
  )

  if #paths == 0 then
    error(
      "neo-tree-jj-source: could not find jj-config.toml"
    )
  end

  return paths[1]
end

local function jj_string(value)
  value = value
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("%z", "\\0")
    :gsub("\t", "\\t")
    :gsub("\r", "\\r")
    :gsub("\n", "\\n")

  return '"' .. value .. '"'
end

local function parent_id_list(expression)
  return table.concat({
    "if(",
    "self.parents(),",
    jj_string("["),
    "++ self.parents()",
    ".map(|p| stringify(",
    expression,
    ").escape_json())",
    ".join(",
    jj_string(","),
    ")",
    "++",
    jj_string("]"),
    ",",
    jj_string("[]"),
    ")",
  }, " ")
end

local parent_change_ids =
  parent_id_list("p.change_id()")

local parent_commit_ids =
  parent_id_list("p.commit_id()")

local diff_files = table.concat({
  "self.diff().files()",
  ".map(|entry|",
  "entry.status()",
  "++",
  jj_string(M.FILE_FIELD_SEPARATOR),
  "++ entry.source().path().display()",
  "++",
  jj_string(M.FILE_FIELD_SEPARATOR),
  "++ entry.target().path().display()",
  "++",
  jj_string(M.FILE_FIELD_SEPARATOR),
  "++ entry.target().conflict()",
  ")",
  ".join(",
  jj_string(M.FILE_SEPARATOR),
  ")",
}, " ")

M.SHOW_TEMPLATE = table.concat({
  "self.change_id()",
  jj_string(M.FIELD_SEPARATOR),

  "self.commit_id()",
  jj_string(M.FIELD_SEPARATOR),

  parent_change_ids,
  jj_string(M.FIELD_SEPARATOR),

  parent_commit_ids,
  jj_string(M.FIELD_SEPARATOR),

  "self.author().name()",
  jj_string(M.FIELD_SEPARATOR),

  "self.author().email()",
  jj_string(M.FIELD_SEPARATOR),

  "self.author().timestamp().local().format("
    .. jj_string("%F %H:%M:%S")
    .. ")",

  jj_string(M.FIELD_SEPARATOR),

  "self.description().escape_json()",
  jj_string(M.FIELD_SEPARATOR),

  "self.empty()",
  jj_string(M.FIELD_SEPARATOR),

  "self.conflict()",
  jj_string(M.FIELD_SEPARATOR),

  diff_files,

  jj_string(M.RECORD_SEPARATOR),
}, " ++ ")

local function schedule(callback, ...)
  local args = { ... }

  vim.schedule(function()
    callback(unpack(args))
  end)
end

local function normalize_cwd(path)
  path = path or vim.fn.getcwd()
  path = vim.fs.normalize(path)

  local uv = vim.uv or vim.loop
  local stat = uv.fs_stat(path)

  if stat and stat.type ~= "directory" then
    path = vim.fs.dirname(path)
  end

  return path
end

---@param cwd string
---@param args string[]
---@param opts? table
---@param callback fun(err: string|nil, stdout: string|nil)
function M.run(cwd, args, opts, callback)
  opts = opts or {}

  local command = {
    "jj",
    "--no-pager",
  }

  if opts.ignore_working_copy then
    table.insert(command, "--ignore-working-copy")
  end

  if opts.color then
    table.insert(command, "--color=" .. opts.color)
  end

  vim.list_extend(command, args)

  table.insert(command, "--config-file")
  table.insert(command, get_jj_config_path())

  vim.system(command, {
    cwd = cwd,
    text = true,
    timeout = opts.timeout or 5000,
  }, function(result)
    if result.code ~= 0 then
      local stderr = vim.trim(result.stderr or "")

      if stderr == "" then
        stderr = "exit code " .. tostring(result.code)
      end

      local message = string.format(
        "%s failed: %s",
        table.concat(command, " "),
        stderr
      )

      schedule(callback, message, nil)
      return
    end

    schedule(callback, nil, result.stdout or "")
  end)
end

---@param path string
---@param callback fun(err: string|nil, root: string|nil)
function M.get_root(path, callback)
  local cwd = normalize_cwd(path)

  M.run(cwd, { "root" }, {
    ignore_working_copy = true,
    color = "never",
  }, function(err, stdout)
    if err then
      callback(err, nil)
      return
    end

    local root = vim.trim(stdout or "")

    if root == "" then
      callback("jj root returned no repository root", nil)
      return
    end

    callback(nil, vim.fs.normalize(root))
  end)
end

---@param root string
---@param callback fun(err: string|nil, operation_id: string|nil)
function M.get_latest_operation_id(root, callback)
  -- Deliberately do NOT pass --ignore-working-copy here.
  --
  -- This lets JJ snapshot a dirty working copy first. The subsequent status
  -- and log commands use --ignore-working-copy, so they all read the same
  -- operation snapshot.
  M.run(root, {
    "operation",
    "log",
    "--limit",
    "1",
    "-T",
    "self.id()",
    "--no-graph",
  }, {
    color = "never",
  }, function(err, stdout)
    if err then
      callback(err, nil)
      return
    end

    local operation_id = vim.trim(stdout or "")

    if operation_id == "" then
      callback("jj operation log returned no operation id", nil)
      return
    end

    callback(nil, operation_id)
  end)
end

---@param root string
---@param callback fun(err: string|nil, stdout: string|nil)
function M.get_status(root, callback)
  M.run(root, {
    "status",
  }, {
    ignore_working_copy = true,
    color = "always",
    timeout = 5000,
  }, callback)
end

---@param root string
---@param revisions string[]
---@param callback fun(err: string|nil, stdout: string|nil)
function M.get_shows(root, revisions, callback)
  if #revisions == 0 then
    callback(nil, "")
    return
  end

  local args = {
    "log",
    "-T",
    M.SHOW_TEMPLATE,
    "--no-graph",
  }

  for _, revision in ipairs(revisions) do
    table.insert(args, "-r")
    table.insert(args, revision)
  end

  M.run(root, args, {
    ignore_working_copy = true,
    color = "never",
    timeout = 5000,
  }, callback)
end

---@param root string
---@param revision string
---@param callback fun(err: string|nil, stdout: string|nil)
function M.get_show(root, revision, callback)
  M.get_shows(root, { revision }, callback)
end

return M
