local M = {}

local function basename(path)
  return path:match("([^/]+)$") or path
end

local function dirname(path)
  return path:match("^(.*)/[^/]+$") or ""
end

local function clean_description(description)
  description = description or ""

  return vim.trim(
    description:gsub("[\r\n]+", " ")
  )
end

local function group_label(prefix, change)
  local description =
    clean_description(change.description)

  local label = string.format(
    "%s [%s]",
    prefix,
    change.change_id
  )

  if description ~= "" then
    label = label .. " • " .. description
  end

  if change.is_empty then
    label = label .. " (empty)"
  end

  if change.is_conflict then
    label = label .. " (conflict)"
  end

  if description == "" then
    label = label .. " (no description)"
  end

  return label
end

local function build_file_node(change, file)
  local relpath = file.relpath

  return {
    id = table.concat({
      "jj:file",
      change.change_id,
      relpath,
    }, ":"),

    name = basename(relpath),

    -- This remains the actual filesystem location even for historical
    -- or deleted entries. Commands use extra.revision/status to decide
    -- whether it is legal to open this as a normal file.
    path = file.path,

    type = "file",

    extra = {
      kind = "changed_file",

      revision = change.revision,
      change_id = change.change_id,
      commit_id = change.commit_id,

      status = file.status,

      relpath = relpath,
      parent_path = dirname(relpath),

      old_path = file.old_path,

      conflicted = file.conflicted == true,
    },
  }
end

local function build_group_node(
  group_type,
  prefix,
  change
)
  local children = {}

  for _, file in ipairs(change.files or {}) do
    table.insert(
      children,
      build_file_node(change, file)
    )
  end

  local id

  if group_type == "working_copy" then
    id = "jj:working:" .. change.change_id
  else
    id = "jj:parent:" .. change.change_id
  end

  return {
    id = id,
    name = group_label(prefix, change),

    -- Mechanically this is a Neo-tree directory because that gives us
    -- container expansion. Semantically it is NOT a filesystem directory.
    type = "directory",

    path = id,

    loaded = true,
    children = children,

    extra = {
      kind = "change_group",

      group_type = group_type,

      revision = change.revision,
      change_id = change.change_id,
      commit_id = change.commit_id,

      description = change.description,
      bookmarks = change.bookmarks,

      is_empty = change.is_empty == true,
      is_conflict = change.is_conflict == true,

      count = #children,
    },
  }
end

---@param snapshot table
---@return table[]
function M.build_nodes(snapshot)
  local nodes = {}

  table.insert(
    nodes,
    build_group_node(
      "working_copy",
      "Working Copy",
      snapshot.working_copy
    )
  )

  for _, parent in ipairs(snapshot.parents) do
    table.insert(
      nodes,
      build_group_node(
        "parent",
        "Parent Commit",
        parent
      )
    )
  end

  return nodes
end

---@param text string
---@return table[]
function M.message(text)
  return {
    {
      id = "jj:message",
      name = text,
      type = "message",
      path = "jj:message",
      extra = {
        kind = "message",
      },
    },
  }
end

return M