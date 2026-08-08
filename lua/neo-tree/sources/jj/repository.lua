local cli = require("neo-tree.sources.jj.cli")
local parser = require("neo-tree.sources.jj.parser")

local M = {}

local repositories = {}

local start_refresh

local function create_repository(root)
  local repository = {
    root = root,

    operation_id = nil,
    snapshot = nil,

    refreshing = false,
    pending = false,

    changed_while_waiting = false,

    waiters = {},
  }

  repositories[root] = repository

  return repository
end

local function get_repository(root)
  return repositories[root] or create_repository(root)
end

local function notify_waiters(
  repository,
  err,
  snapshot,
  changed
)
  local waiters = repository.waiters
  repository.waiters = {}

  for _, callback in ipairs(waiters) do
    callback(err, snapshot, changed)
  end
end

local function finish_refresh(
  repository,
  err,
  snapshot,
  changed
)
  repository.refreshing = false

  if err then
    repository.pending = false
    repository.changed_while_waiting = false

    notify_waiters(
      repository,
      err,
      snapshot,
      false
    )

    return
  end

  repository.changed_while_waiting =
    repository.changed_while_waiting or changed

  if repository.pending then
    repository.pending = false
    start_refresh(repository)
    return
  end

  local final_changed =
    repository.changed_while_waiting

  repository.changed_while_waiting = false

  notify_waiters(
    repository,
    nil,
    snapshot,
    final_changed
  )
end

local function parse_status(root, output)
  local ok, result = pcall(
    parser.parse_status,
    root,
    output
  )

  if not ok then
    return nil, "Failed to parse jj status: " .. tostring(result)
  end

  return result, nil
end

local function parse_shows(root, output)
  local ok, result = pcall(
    parser.parse_shows,
    root,
    output
  )

  if not ok then
    return nil, "Failed to parse parent changes: " .. tostring(result)
  end

  return result, nil
end

local function get_parent_shows(
  root,
  parent_changes,
  callback
)
  if #parent_changes == 0 then
    callback(nil, {})
    return
  end

  local remaining = #parent_changes
  local results = {}
  local finished = false

  for index, parent in ipairs(parent_changes) do
    cli.get_show(
      root,
      parent.change_id,
      function(err, output)
        if finished then
          return
        end

        if err then
          finished = true
          callback(err, nil)
          return
        end

        local shows, parse_err = parse_shows(
          root,
          output or ""
        )

        if parse_err then
          finished = true
          callback(parse_err, nil)
          return
        end

        if #shows ~= 1 then
          finished = true
          callback(
            string.format(
              "Expected one parent change for %s, got %d",
              parent.change_id,
              #shows
            ),
            nil
          )
          return
        end

        results[index] = {
          change_id = parent.change_id,
          show = shows[1],
        }

        remaining = remaining - 1

        if remaining == 0 then
          finished = true
          callback(nil, results)
        end
      end
    )
  end
end

local function build_snapshot(
  repository,
  operation_id,
  status,
  shows
)
  local shows_by_change_id = {}

  for _, result in ipairs(shows) do
    shows_by_change_id[result.change_id] =
      result.show
  end

  local working_copy = vim.deepcopy(
    status.working_copy
  )

  working_copy.revision = "@"
  working_copy.files = status.files

  local parents = {}

  for _, parent_metadata in ipairs(
    status.parent_changes
  ) do
    local show = shows_by_change_id[
      parent_metadata.change_id
    ]

    if not show then
      return nil, string.format(
        "jj log did not return parent change %s",
        parent_metadata.change_id
      )
    end

    local parent = vim.deepcopy(parent_metadata)

    parent.revision = parent.change_id
    parent.files = show.files

    -- Status remains authoritative for the presentation metadata,
    -- but use the structured query as a fallback.
    parent.commit_id =
      parent.commit_id
      or show.change.commit_id

    parent.description =
      parent.description
      or show.change.description

    if parent.is_empty == nil then
      parent.is_empty = show.change.is_empty
    end

    if parent.is_conflict == nil then
      parent.is_conflict = show.change.is_conflict
    end

    table.insert(parents, parent)
  end

  return {
    root = repository.root,
    operation_id = operation_id,

    working_copy = working_copy,
    parents = parents,
  }, nil
end

start_refresh = function(repository)
  repository.refreshing = true

  cli.get_latest_operation_id(
    repository.root,
    function(err, operation_id)
      if err then
        finish_refresh(repository, err, nil, false)
        return
      end

      if
        repository.snapshot
        and repository.operation_id == operation_id
      then
        finish_refresh(
          repository,
          nil,
          repository.snapshot,
          false
        )

        return
      end

      cli.get_status(
        repository.root,
        function(status_err, status_output)
          if status_err then
            finish_refresh(
              repository,
              status_err,
              nil,
              false
            )

            return
          end

          local status, status_parse_err =
            parse_status(
              repository.root,
              status_output or ""
            )

          if status_parse_err then
            finish_refresh(
              repository,
              status_parse_err,
              nil,
              false
            )

            return
          end

          get_parent_shows(
            repository.root,
            status.parent_changes,
            function(show_err, shows)
              if show_err then
                finish_refresh(
                  repository,
                  show_err,
                  nil,
                  false
                )

                return
              end

              local snapshot, snapshot_err =
                build_snapshot(
                  repository,
                  operation_id,
                  status,
                  shows
                )

              if snapshot_err then
                finish_refresh(
                  repository,
                  snapshot_err,
                  nil,
                  false
                )

                return
              end

              repository.operation_id =
                operation_id

              repository.snapshot =
                snapshot

              finish_refresh(
                repository,
                nil,
                snapshot,
                true
              )
            end
          )
        end
      )
    end
  )
end

local function refresh_root(root, callback)
  local repository = get_repository(root)

  table.insert(
    repository.waiters,
    callback
  )

  if repository.refreshing then
    repository.pending = true
    return
  end

  repository.changed_while_waiting = false
  start_refresh(repository)
end

---@param path string
---@param callback fun(err: string|nil, snapshot: table|nil, changed: boolean)
function M.refresh(path, callback)
  callback = callback or function() end

  path = vim.fs.normalize(
    path or vim.fn.getcwd()
  )

  -- Once state.path has become the repository root, avoid paying for
  -- another `jj root` invocation on every refresh.
  if repositories[path] then
    refresh_root(path, callback)
    return
  end

  cli.get_root(path, function(err, root)
    if err then
      callback(err, nil, false)
      return
    end

    refresh_root(root, callback)
  end)
end

---@param root? string
function M.invalidate(root)
  if root then
    repositories[vim.fs.normalize(root)] = nil
    return
  end

  repositories = {}
end

return M
