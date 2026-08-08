local common =
  require("neo-tree.sources.common.commands")

local manager =
  require("neo-tree.sources.manager")

local M = {}

local function notify_historical(extra)
  local message

  if extra.status == "D" and extra.revision == "@" then
    message =
      "Opening deleted JJ files is not implemented yet"
  else
    message =
      "Opening files from historical JJ revisions is not implemented yet"
  end

  vim.notify(
    message,
    vim.log.levels.INFO,
    {
      title = "neo-tree-jj-source",
    }
  )
end

local function can_open_as_working_file(node)
  local extra = node.extra or {}

  if extra.kind ~= "changed_file" then
    return false
  end

  if extra.revision ~= "@" then
    return false
  end

  if extra.status == "D" then
    return false
  end

  local uv = vim.uv or vim.loop

  return uv.fs_stat(node.path) ~= nil
end

local function dispatch_open(
  state,
  common_command
)
  local node = state.tree:get_node()

  if not node then
    return
  end

  local extra = node.extra or {}

  if extra.kind == "change_group" then
    common.toggle_node(state)
    return
  end

  if extra.kind ~= "changed_file" then
    return
  end

  if can_open_as_working_file(node) then
    common_command(state)
    return
  end

  notify_historical(extra)
end

function M.open(state)
  dispatch_open(state, common.open)
end

function M.open_split(state)
  dispatch_open(state, common.open_split)
end

function M.open_vsplit(state)
  dispatch_open(state, common.open_vsplit)
end

function M.open_tabnew(state)
  dispatch_open(state, common.open_tabnew)
end

function M.refresh(state)
  manager.refresh("jj", state)
end

-- External Neo-tree sources are expected to expose the common commands
-- used by Neo-tree's global mappings.
--
-- Our custom definitions above win because _add_common_commands only
-- fills commands that do not already exist.
common._add_common_commands(M)

return M