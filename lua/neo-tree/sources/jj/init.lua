local events =
  require("neo-tree.events")

local manager =
  require("neo-tree.sources.manager")

local renderer =
  require("neo-tree.ui.renderer")

local utils =
  require("neo-tree.utils")

local repository =
  require("neo-tree.sources.jj.repository")

local render =
  require("neo-tree.sources.jj.render")

local M = {
  name = "jj",
  display_name = " 󰊢 JJ ",
}

local DEFAULT_RENDERERS = {
  directory = {
    {
      "indent",
      with_expanders = true,
    },
    {
      "name",
    },
    {
      "jj_count",
      align = "right",
    },
  },

  file = {
    {
      "indent",
    },
    {
      "jj_status",
    },
    {
      "icon",
    },
    {
      "name",
    },
    {
      "jj_path",
    },
  },

  message = {
    {
      "name",
    },
  },
}

local function install_default_renderers(config)
  config.renderers = config.renderers or {}

  for node_type, definition in pairs(
    DEFAULT_RENDERERS
  ) do
    if config.renderers[node_type] == nil then
      config.renderers[node_type] =
        vim.deepcopy(definition)
    end
  end
end

local function install_default_mappings(config)
  config.window = config.window or {}
  config.window.mappings =
    config.window.mappings or {}

  local mappings = config.window.mappings

  -- JJ-specific/opening behavior.
  if mappings["<cr>"] == nil then
    mappings["<cr>"] = "open"
  end

  if mappings["o"] == nil then
    mappings["o"] = "open"
  end

  if mappings["R"] == nil then
    mappings["R"] = "refresh"
  end

  -- These inherited Neo-tree mappings assume that every node maps
  -- directly to the working-copy filesystem. That is not true for
  -- parent commits, deleted files, or synthetic change groups.
  --
  -- Disable them until we implement JJ-aware equivalents.
  local disabled = {
    "<C-s>", -- quick_jump can bypass our historical-file open handling
    "P",     -- preview
    "l",     -- focus_preview
    "w",     -- open_with_window_picker

    "a",     -- add
    "A",     -- add_directory
    "d",     -- delete
    "r",     -- rename
    "b",     -- rename_basename
    "y",     -- copy_to_clipboard
    "x",     -- cut_to_clipboard
    "p",     -- paste_from_clipboard
    "<C-r>", -- clear_clipboard
    "c",     -- copy
    "m",     -- move

    "i",     -- show_file_details uses filesystem stat data
  }

  for _, lhs in ipairs(disabled) do
    if mappings[lhs] == nil then
      mappings[lhs] = "none"
    end
  end
end

local function run_callback(callback)
  if type(callback) == "function" then
    callback()
  end
end

local function default_expanded_nodes(nodes)
  local ids = {}

  for _, node in ipairs(nodes) do
    if node.type == "directory" then
      table.insert(ids, node.id)
    end
  end

  return ids
end

---@param state table
---@param path string?
---@param path_to_reveal string?
---@param callback function?
---@param async boolean?
function M.navigate(
  state,
  path,
  path_to_reveal,
  callback,
  async
)
  state.dirty = false

  if path_to_reveal then
    renderer.position.set(
      state,
      path_to_reveal
    )
  end

  path =
    path
    or state.path
    or vim.fn.getcwd()

  state.jj_request_id =
    (state.jj_request_id or 0) + 1

  local request_id = state.jj_request_id

  repository.refresh(
    path,
    function(err, snapshot)
      -- A newer navigate() started while this request was running.
      -- Never let stale async output replace newer repository state.
      if request_id ~= state.jj_request_id then
        run_callback(callback)
        return
      end

      if err then
        renderer.show_nodes(
          render.message(err),
          state
        )

        run_callback(callback)
        return
      end

      state.path = snapshot.root

      local nodes =
        render.build_nodes(snapshot)

      -- Expand all groups once on the initial successful render.
      --
      -- Immediately remove default_expanded_nodes afterwards so future
      -- renders preserve whatever the user expanded/collapsed. Neo-tree's
      -- renderer already preserves currently-expanded IDs for full redraws.
      if not state.jj_initialized then
        state.default_expanded_nodes =
          default_expanded_nodes(nodes)
      else
        state.default_expanded_nodes = nil
      end

      renderer.show_nodes(
        nodes,
        state
      )

      state.default_expanded_nodes = nil
      state.jj_initialized = true

      run_callback(callback)
    end
  )
end

function M.refresh()
  manager.refresh(M.name)
end

function M.setup(config, global_config)
  install_default_renderers(config)
  install_default_mappings(config)

  if global_config.enable_refresh_on_write then
    manager.subscribe(M.name, {
      event = events.VIM_BUFFER_CHANGED,

      handler = function(args)
        if utils.is_real_file(args.afile) then
          M.refresh()
        end
      end,
    })
  end

  if config.bind_to_cwd ~= false then
    manager.subscribe(M.name, {
      event = events.VIM_DIR_CHANGED,
      handler = M.refresh,
    })
  end
end

return M