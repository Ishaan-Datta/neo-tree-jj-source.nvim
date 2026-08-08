local common =
  require("neo-tree.sources.common.components")

local highlights =
  require("neo-tree.ui.highlights")

local M = {}

local function status_highlight(extra)
  if extra.conflicted then
    return highlights.GIT_CONFLICT
  end

  if extra.status == "A" then
    return highlights.GIT_ADDED
  end

  if extra.status == "M" then
    return highlights.GIT_MODIFIED
  end

  if extra.status == "D" then
    return highlights.GIT_DELETED
  end

  if extra.status == "R" or extra.status == "C" then
    return highlights.GIT_RENAMED
  end

  return highlights.FILE_NAME
end

function M.name(config, node, state)
  local extra = node.extra or {}

  if extra.kind == "message" then
    return {
      text = node.name,
      highlight = highlights.MESSAGE,
    }
  end

  if extra.kind == "change_group" then
    return {
      text = node.name,
      highlight = highlights.DIRECTORY_NAME,
    }
  end

  if extra.kind == "changed_file" then
    return {
      text = node.name,
      highlight = status_highlight(extra),
    }
  end

  return common.name(config, node, state)
end

function M.jj_status(_, node)
  local extra = node.extra or {}

  if extra.kind ~= "changed_file" then
    return {}
  end

  local status = extra.status or " "
  local conflict = extra.conflicted and "!" or " "

  return {
    text = status .. conflict,
    highlight = status_highlight(extra),
  }
end

function M.jj_path(_, node)
  local extra = node.extra or {}

  if extra.kind ~= "changed_file" then
    return {}
  end

  local parent_path = extra.parent_path or ""

  if parent_path == "" then
    return {}
  end

  return {
    text = parent_path,
    highlight = highlights.DIM_TEXT,
  }
end

function M.jj_count(_, node)
  local extra = node.extra or {}

  if extra.kind ~= "change_group" then
    return {}
  end

  return {
    text = tostring(extra.count or 0),
    highlight = highlights.DIM_TEXT,
  }
end

return vim.tbl_deep_extend(
  "force",
  common,
  M
)