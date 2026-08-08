local cli = require("neo-tree.sources.jj.cli")

local M = {}

local SGR_PATTERN = "\27%[[0-9;]*m"

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_relpath(path)
  path = trim(path)
  path = path:gsub("\\", "/")
  path = path:gsub("^%./", "")

  if path ~= "" then
    path = vim.fs.normalize(path)
  end

  return path
end

local function absolute_path(root, relpath)
  return vim.fs.normalize(vim.fs.joinpath(root, relpath))
end

local function split_plain(value, separator)
  local result = {}
  local start = 1

  while true do
    local first, last = value:find(separator, start, true)

    if not first then
      table.insert(result, value:sub(start))
      break
    end

    table.insert(result, value:sub(start, first - 1))
    start = last + 1
  end

  return result
end

function M.strip_ansi(value)
  return (value or ""):gsub(SGR_PATTERN, "")
end

local function ansi_code_sets_color(code)
  if code == "\27[0m" or code == "\27[39m" then
    return false
  end

  if code:match("^\27%[3[0-7]m$") then
    return true
  end

  if code:match("^\27%[9[0-7]m$") then
    return true
  end

  if code:match("^\27%[38;5;%d+m$") then
    return true
  end

  if code:match("^\27%[48;5;%d+m$") then
    return true
  end

  if code:match("^\27%[38;2;%d+;%d+;%d+m$") then
    return true
  end

  if code:match("^\27%[48;2;%d+;%d+;%d+m$") then
    return true
  end

  return nil
end

function M.extract_colored_regions(value)
  local regions = {}
  local colored = false
  local index = 1

  local function push(text, is_colored)
    if text == "" then
      return
    end

    local previous = regions[#regions]

    if previous and previous.colored == is_colored then
      previous.text = previous.text .. text
    else
      table.insert(regions, {
        text = text,
        colored = is_colored,
      })
    end
  end

  while true do
    local first, last = value:find(SGR_PATTERN, index)

    if not first then
      push(value:sub(index), colored)
      break
    end

    if first > index then
      push(value:sub(index, first - 1), colored)
    end

    local code = value:sub(first, last)
    local color_state = ansi_code_sets_color(code)

    if color_state ~= nil then
      colored = color_state
    end

    index = last + 1
  end

  return regions
end

---@param file string
---@return table|nil
function M.parse_rename_paths(file)
  local prefix, from_part, to_part, suffix =
    file:match("^(.*){%s*(.-)%s*=>%s*(.-)%s*}(.*)$")

  if not prefix then
    return nil
  end

  return {
    from_path = normalize_relpath(prefix .. from_part .. suffix),
    to_path = normalize_relpath(prefix .. to_part .. suffix),
  }
end

local function parse_bookmarks(value)
  value = trim(M.strip_ansi(value))

  if value == "" then
    return nil
  end

  local bookmarks = {}

  for bookmark in value:gmatch("%S+") do
    table.insert(bookmarks, bookmark)
  end

  return bookmarks
end

local function parse_commit_line(line)
  local plain = trim(M.strip_ansi(line))

  local kind

  if plain:match("^Working copy") then
    kind = "working_copy"
  elseif plain:match("^Parent commit") then
    kind = "parent"
  else
    return nil
  end

  local colon = line:find(":", 1, true)

  if not colon then
    error("Unexpected commit line: " .. plain)
  end

  local rest = trim(line:sub(colon + 1))

  local raw_change_id, raw_commit_id, tail =
    rest:match("^(%S+)%s+(%S+)%s*(.*)$")

  if not raw_change_id or not raw_commit_id then
    error("Unexpected commit line: " .. plain)
  end

  local bookmarks_raw
  local description_raw

  local before_pipe, after_pipe = tail:match("^(.-)%s+|%s*(.*)$")

  if before_pipe then
    bookmarks_raw = before_pipe
    description_raw = after_pipe
  else
    description_raw = tail
  end

  description_raw = description_raw or ""

  local description_regions = M.extract_colored_regions(description_raw)

  local description_parts = {}
  local descriptor_parts = {}

  for _, region in ipairs(description_regions) do
    if region.colored then
      table.insert(descriptor_parts, region.text)
    else
      table.insert(description_parts, region.text)
    end
  end

  local description = trim(table.concat(description_parts))
  local descriptors = table.concat(descriptor_parts)

  return {
    kind = kind,

    change_id = trim(M.strip_ansi(raw_change_id)),
    commit_id = trim(M.strip_ansi(raw_commit_id)),

    bookmarks = parse_bookmarks(bookmarks_raw or ""),

    description = description,

    is_empty = descriptors:find("(empty)", 1, true) ~= nil,
    is_conflict = descriptors:find("(conflict)", 1, true) ~= nil,
  }
end

---@param root string
---@param output string
---@return table
function M.parse_status(root, output)
  local files = {}
  local conflicted_files = {}

  local working_copy = nil
  local parent_changes = {}

  local parsing_conflicts = false

  for line in (output .. "\n"):gmatch("(.-)\r?\n") do
    local raw = trim(line)
    local plain = trim(M.strip_ansi(raw))

    if plain == "" then
      goto continue
    end

    if plain:match("^Working copy changes:") then
      goto continue
    end

    if plain:match("^The working copy is clean") then
      goto continue
    end

    if plain:find(
      "There are unresolved conflicts at these paths:",
      1,
      true
    ) then
      parsing_conflicts = true
      goto continue
    end

    if parsing_conflicts then
      if plain:find("To resolve the conflicts", 1, true) then
        parsing_conflicts = false
        goto continue
      end

      local regions = M.extract_colored_regions(raw)

      local path_parts = {}
      local found_colored_region = false

      for _, region in ipairs(regions) do
        if region.colored then
          found_colored_region = true
          break
        end

        table.insert(path_parts, region.text)
      end

      local conflict_path = normalize_relpath(
        trim(table.concat(path_parts))
      )

      if conflict_path ~= "" and found_colored_region then
        conflicted_files[absolute_path(root, conflict_path)] = true
        goto continue
      end

      -- We reached something that doesn't look like another conflict path.
      parsing_conflicts = false
    end

    local status, file = plain:match("^([AMDRC])%s+(.+)$")

    if status then
      if status == "R" or status == "C" then
        local rename = M.parse_rename_paths(file)

        if not rename then
          error(
            string.format(
              "Unexpected %s line from jj status: %s",
              status == "R" and "rename" or "copy",
              plain
            )
          )
        end

        table.insert(files, {
          status = status,

          relpath = rename.to_path,
          path = absolute_path(root, rename.to_path),

          old_path = rename.from_path,

          conflicted = false,
        })
      else
        local relpath = normalize_relpath(file)

        table.insert(files, {
          status = status,

          relpath = relpath,
          path = absolute_path(root, relpath),

          old_path = nil,

          conflicted = false,
        })
      end

      goto continue
    end

    local commit = parse_commit_line(raw)

    if commit then
      if commit.kind == "working_copy" then
        working_copy = commit
      else
        table.insert(parent_changes, commit)
      end
    end

    ::continue::
  end

  if not working_copy then
    error("jj status did not contain a Working copy entry")
  end

  for _, file in ipairs(files) do
    file.conflicted = conflicted_files[file.path] == true
  end

  return {
    working_copy = working_copy,
    parent_changes = parent_changes,

    files = files,
    conflicted_files = conflicted_files,
  }
end

local STATUS_MAP = {
  modified = "M",
  added = "A",
  removed = "D",
  copied = "C",
  renamed = "R",
}

local function output_preview(value)
  value = value
    :gsub("\27", "<ESC>")
    :gsub("\r", "\\r")
    :gsub("\n", "\\n")

  if #value > 400 then
    value = value:sub(1, 400) .. "..."
  end

  return value
end

local function decode_json(value, field_name)
  local input = trim(value)

  local ok, decoded = pcall(
    vim.fn.json_decode,
    input
  )

  if not ok then
    error(
      string.format(
        "Could not decode %s JSON: %s\nDecoder error: %s",
        field_name,
        output_preview(input),
        tostring(decoded)
      )
    )
  end

  return decoded
end

local function parse_json_string_array(
  value,
  field_name
)
  local decoded =
    decode_json(value, field_name)

  if type(decoded) ~= "table" then
    error(
      string.format(
        "Expected %s to be a JSON array, got %s",
        field_name,
        type(decoded)
      )
    )
  end

  local result = {}

  for _, item in ipairs(decoded) do
    if type(item) ~= "string" then
      error(
        string.format(
          "Expected every %s entry to be a string, got %s",
          field_name,
          type(item)
        )
      )
    end

    table.insert(result, item)
  end

  return result
end

local function parse_show_record(root, record)
  local fields =
    split_plain(
      record,
      cli.FIELD_SEPARATOR
    )

  if #fields ~= 11 then
    error(
      string.format(
        "Unexpected jj log record: expected 11 fields, got %d. Record: %s",
        #fields,
        output_preview(record)
      )
    )
  end

  local change_id = trim(fields[1])
  local commit_id = trim(fields[2])

  local parent_change_ids =
    parse_json_string_array(
      fields[3],
      "parent change ids"
    )

  local parent_commit_ids =
    parse_json_string_array(
      fields[4],
      "parent commit ids"
    )

  local author_name = trim(fields[5])
  local author_email = trim(fields[6])
  local authored_date = trim(fields[7])

  local description =
  decode_json(
    fields[8],
    "description"
  )

  if type(description) ~= "string" then
    error(
      string.format(
        "Expected description to decode to a string, got %s",
        type(description)
      )
    )
  end

  local is_empty =
    trim(fields[9]) == "true"

  local is_conflict =
    trim(fields[10]) == "true"

  local files = {}
  local diff_files = fields[11]

  if diff_files ~= "" then
    for _, entry in ipairs(
      split_plain(
        diff_files,
        cli.FILE_SEPARATOR
      )
    ) do
      if entry ~= "" then
        local parts =
          split_plain(
            entry,
            cli.FILE_FIELD_SEPARATOR
          )

        if #parts ~= 4 then
          error(
            string.format(
              "Unexpected file record: expected 4 fields, got %d. Record: %s",
              #parts,
              output_preview(entry)
            )
          )
        end

        local raw_status = trim(parts[1])
        local status = STATUS_MAP[raw_status]

        if not status then
          error(
            "Unexpected file status from jj log: "
              .. raw_status
          )
        end

        local source_path =
          normalize_relpath(parts[2])

        local target_path =
          normalize_relpath(parts[3])

        if target_path == "" then
          target_path = source_path
        end

        if source_path == "" then
          source_path = target_path
        end

        local conflicted =
          trim(parts[4]) == "true"

        table.insert(files, {
          status = status,

          relpath = target_path,
          path = absolute_path(
            root,
            target_path
          ),

          old_path =
            (
              status == "R"
              or status == "C"
            )
              and source_path
            or nil,

          conflicted = conflicted,
        })
      end
    end
  end

  return {
    change = {
      change_id = change_id,
      commit_id = commit_id,

      parent_change_ids =
        parent_change_ids,

      parent_commit_ids =
        parent_commit_ids,

      author = {
        name = author_name,
        email = author_email,
      },

      authored_date = authored_date,
      description = description,

      is_empty = is_empty,
      is_conflict = is_conflict,
    },

    files = files,
  }
end

---@param root string
---@param output string
---@return table[]
function M.parse_shows(root, output)
  if output == "" then
    return {}
  end

  local records =
    split_plain(
      output,
      cli.RECORD_SEPARATOR
    )

  -- JJK's record template always terminates every record with the
  -- record separator. Therefore splitting should leave one empty
  -- element at the end.
  if records[#records] ~= "" then
    error(
      "jj log output was missing the expected record separator. Output: "
        .. output_preview(output)
    )
  end

  table.remove(records)

  local result = {}

  for _, record in ipairs(records) do
    if trim(record) ~= "" then
      table.insert(
        result,
        parse_show_record(
          root,
          record
        )
      )
    end
  end

  return result
end

return M
