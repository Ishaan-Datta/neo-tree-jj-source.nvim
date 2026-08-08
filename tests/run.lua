local cli = require("neo-tree.sources.jj.cli")
local parser = require("neo-tree.sources.jj.parser")
local render = require("neo-tree.sources.jj.render")
local repository = require("neo-tree.sources.jj.repository")

local failures = 0
local tests = 0

local function inspect(value)
  return vim.inspect(value)
end

local function assert_equal(actual, expected, message)
  if vim.deep_equal(actual, expected) then
    return
  end

  error(string.format(
    "%s\nexpected: %s\nactual:   %s",
    message or "values differ",
    inspect(expected),
    inspect(actual)
  ))
end

local function assert_truthy(value, message)
  if not value then
    error(message or "expected a truthy value")
  end
end

local function test(name, callback)
  tests = tests + 1

  local ok, err = xpcall(callback, debug.traceback)

  if ok then
    io.write("ok - ", name, "\n")
  else
    failures = failures + 1
    io.stderr:write("not ok - ", name, "\n", err, "\n")
  end
end

local function absolute(root, relpath)
  return vim.fs.normalize(vim.fs.joinpath(root, relpath))
end

test("parseRenamePaths ports jjk rename cases", function()
  local cases = {
    { "{old => new}.txt", "old.txt", "new.txt" },
    { "prefix/{old => new}", "prefix/old", "prefix/new" },
    { "{old => new}/suffix", "old/suffix", "new/suffix" },
    { "src/test/{ => basic-suite}/main.test.ts", "src/test/main.test.ts", "src/test/basic-suite/main.test.ts" },
    { "src/{old => }/file.ts", "src/old/file.ts", "src/file.ts" },
    { "src/{ old name => new name }/file.lua", "src/old name/file.lua", "src/new name/file.lua" },
  }

  for _, case in ipairs(cases) do
    local parsed = parser.parse_rename_paths(case[1])
    assert_truthy(parsed, "expected rename to parse: " .. case[1])
    assert_equal(parsed.from_path, case[2])
    assert_equal(parsed.to_path, case[3])
  end

  assert_equal(parser.parse_rename_paths("old => new"), nil)
  assert_equal(parser.parse_rename_paths(""), nil)
end)

test("parseStatus ports jjk working-copy and parent metadata", function()
  local root = "/tmp/jjk-status"
  local esc = "\27["
  local output = table.concat({
    "Working copy changes:",
    "M src/changed.lua",
    "R src/{old => new}.lua",
    "There are unresolved conflicts at these paths:",
    "src/changed.lua " .. esc .. "38;5;9m2-sided conflict" .. esc .. "39m",
    "To resolve the conflicts, start by updating the working copy:",
    "Working copy  (@) : " .. esc .. "1m" .. esc .. "38;5;13mwcchange" .. esc .. "0m " .. esc .. "38;5;10mwccommit" .. esc .. "0m " .. esc .. "38;5;10m(empty)" .. esc .. "39m " .. esc .. "38;5;9m(conflict)" .. esc .. "39m " .. esc .. "38;5;10m(no description set)" .. esc .. "0m",
    "Parent commit (@-): " .. esc .. "1m" .. esc .. "38;5;5mparentch" .. esc .. "0m " .. esc .. "38;5;5mparentco" .. esc .. "0m " .. esc .. "38;5;5mmain feature" .. esc .. "38;5;8m | " .. esc .. "39mParent description",
    "",
  }, "\n")

  local status = parser.parse_status(root, output)

  assert_equal(status.working_copy.change_id, "wcchange")
  assert_equal(status.working_copy.commit_id, "wccommit")
  assert_equal(status.working_copy.description, "")
  assert_equal(status.working_copy.is_empty, true)
  assert_equal(status.working_copy.is_conflict, true)
  assert_equal(status.parent_changes[1].change_id, "parentch")
  assert_equal(status.parent_changes[1].commit_id, "parentco")
  assert_equal(status.parent_changes[1].bookmarks, { "main", "feature" })
  assert_equal(status.parent_changes[1].description, "Parent description")
  assert_equal(status.files[1], {
    status = "M",
    relpath = "src/changed.lua",
    path = absolute(root, "src/changed.lua"),
    old_path = nil,
    conflicted = true,
  })
  assert_equal(status.files[2], {
    status = "R",
    relpath = "src/new.lua",
    path = absolute(root, "src/new.lua"),
    old_path = "src/old.lua",
    conflicted = false,
  })
end)

test("parseShows decodes all jjk parent metadata fields", function()
  local root = "/tmp/jjk-show"
  local file_entries = table.concat({
    table.concat({ "modified", "src/a.lua", "src/a.lua", "false" }, cli.FILE_FIELD_SEPARATOR),
    table.concat({ "renamed", "old/name.lua", "new/name.lua", "true" }, cli.FILE_FIELD_SEPARATOR),
    table.concat({ "copied", "source.lua", "copy.lua", "false" }, cli.FILE_FIELD_SEPARATOR),
  }, cli.FILE_SEPARATOR)
  local record = table.concat({
    "change01",
    "commit01",
    '["parent-change"]',
    '["parent-commit"]',
    "Test Author",
    "test@example.com",
    "2026-08-09 10:11:12",
    vim.fn.json_encode("Description with \"quotes\"\nand a newline"),
    "false",
    "true",
    file_entries,
  }, cli.FIELD_SEPARATOR) .. cli.RECORD_SEPARATOR

  local shows = parser.parse_shows(root, record)
  local show = shows[1]

  assert_equal(#shows, 1)
  assert_equal(show.change.change_id, "change01")
  assert_equal(show.change.commit_id, "commit01")
  assert_equal(show.change.parent_change_ids, { "parent-change" })
  assert_equal(show.change.parent_commit_ids, { "parent-commit" })
  assert_equal(show.change.author, {
    name = "Test Author",
    email = "test@example.com",
  })
  assert_equal(show.change.authored_date, "2026-08-09 10:11:12")
  assert_equal(show.change.description, "Description with \"quotes\"\nand a newline")
  assert_equal(show.change.is_empty, false)
  assert_equal(show.change.is_conflict, true)
  assert_equal(show.files[1].status, "M")
  assert_equal(show.files[1].relpath, "src/a.lua")
  assert_equal(show.files[2].status, "R")
  assert_equal(show.files[2].old_path, "old/name.lua")
  assert_equal(show.files[2].conflicted, true)
  assert_equal(show.files[3].status, "C")
  assert_equal(show.files[3].old_path, "source.lua")
end)

test("parseShows rejects malformed structured metadata", function()
  local fields = {
    "change01",
    "commit01",
    "not-json",
    "[]",
    "Test Author",
    "test@example.com",
    "2026-08-09 10:11:12",
    '"description"',
    "false",
    "false",
    "",
  }
  local ok, err = pcall(
    parser.parse_shows,
    "/tmp/jjk-show",
    table.concat(fields, cli.FIELD_SEPARATOR) .. cli.RECORD_SEPARATOR
  )

  assert_equal(ok, false)
  assert_truthy(tostring(err):find("parent change ids JSON", 1, true))
end)

test("render displays jjk-equivalent group metadata and files", function()
  local root = "/tmp/jjk-render"
  local nodes = render.build_nodes({
    working_copy = {
      revision = "@",
      change_id = "wcchange",
      commit_id = "wccommit",
      description = "Implement metadata",
      is_empty = false,
      is_conflict = true,
      files = {
        {
          status = "M",
          relpath = "lua/source.lua",
          path = absolute(root, "lua/source.lua"),
          conflicted = true,
        },
      },
    },
    parents = {
      {
        revision = "parentch",
        change_id = "parentch",
        commit_id = "parentco",
        description = "",
        bookmarks = { "main" },
        is_empty = true,
        is_conflict = false,
        files = {
          {
            status = "A",
            relpath = "README.md",
            path = absolute(root, "README.md"),
            conflicted = false,
          },
        },
      },
    },
  })

  assert_equal(nodes[1].name, "Working Copy [wcchange] • Implement metadata (conflict)")
  assert_equal(nodes[1].extra.count, 1)
  assert_equal(nodes[1].children[1].name, "source.lua")
  assert_equal(nodes[1].children[1].extra.parent_path, "lua")
  assert_equal(nodes[1].children[1].extra.conflicted, true)
  assert_equal(nodes[2].name, "Parent Commit [parentch] (empty) (no description)")
  assert_equal(nodes[2].extra.bookmarks, { "main" })
  assert_equal(nodes[2].children[1].extra.revision, "parentch")
end)

test("real jj output matches the ported status and show parsers", function()
  if vim.fn.executable("jj") ~= 1 then
    error("jj executable is required for the integration test")
  end

  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")

  local config = vim.fs.joinpath(vim.fn.getcwd(), "jj-config.toml")

  local function run(args, ignore_working_copy)
    local command = {
      "jj",
      "--no-pager",
      "--config",
      'user.name="Neo Tree JJ Test"',
      "--config",
      'user.email="neo-tree-jj@example.com"',
    }

    if ignore_working_copy then
      table.insert(command, "--ignore-working-copy")
    end

    vim.list_extend(command, args)
    vim.list_extend(command, { "--config-file", config })

    local result = vim.system(command, {
      cwd = root,
      text = true,
      timeout = 10000,
    }):wait()

    assert_equal(result.code, 0, table.concat(command, " ") .. "\n" .. (result.stderr or ""))
    return result.stdout or ""
  end

  local ok, err = xpcall(function()
    run({ "git", "init" }, false)
    vim.fn.writefile({ "parent contents" }, vim.fs.joinpath(root, "tracked.txt"))
    run({ "describe", "-m", "Parent metadata" }, false)
    run({ "new" }, false)
    vim.fn.writefile({ "working-copy contents" }, vim.fs.joinpath(root, "tracked.txt"))

    run({ "operation", "log", "--limit", "1", "-T", "self.id()", "--no-graph" }, false)

    local status_output = run({ "status", "--color=always" }, true)
    local status = parser.parse_status(root, status_output)

    assert_equal(status.working_copy.description, "")
    assert_equal(status.parent_changes[1].description, "Parent metadata")
    assert_equal(status.files[1].status, "M")
    assert_equal(status.files[1].relpath, "tracked.txt")

    local show_output = run({
      "log",
      "-T",
      cli.SHOW_TEMPLATE,
      "--no-graph",
      "-r",
      status.parent_changes[1].change_id,
    }, true)
    local shows = parser.parse_shows(root, show_output)

    assert_equal(#shows, 1)
    assert_equal(
      shows[1].change.change_id:sub(1, #status.parent_changes[1].change_id),
      status.parent_changes[1].change_id
    )
    assert_equal(shows[1].change.description, "Parent metadata\n")
    assert_equal(shows[1].change.author.name, "Neo Tree JJ Test")
    assert_equal(shows[1].change.author.email, "neo-tree-jj@example.com")
    assert_equal(#shows[1].change.parent_change_ids, 1)
    assert_equal(#shows[1].change.parent_commit_ids, 1)
    assert_equal(shows[1].files[1].status, "A")
    assert_equal(shows[1].files[1].relpath, "tracked.txt")

    repository.invalidate(root)

    local refresh_done = false
    local refresh_err
    local snapshot

    repository.refresh(root, function(callback_err, callback_snapshot)
      refresh_err = callback_err
      snapshot = callback_snapshot
      refresh_done = true
    end)

    assert_truthy(vim.wait(10000, function()
      return refresh_done
    end, 10), "repository refresh timed out")
    assert_equal(refresh_err, nil)
    assert_equal(snapshot.working_copy.change_id, status.working_copy.change_id)
    assert_equal(snapshot.parents[1].change_id, status.parent_changes[1].change_id)
    assert_equal(snapshot.parents[1].description, "Parent metadata")
    assert_equal(snapshot.parents[1].files[1].status, "A")
    assert_equal(snapshot.parents[1].files[1].relpath, "tracked.txt")
  end, debug.traceback)

  vim.fn.delete(root, "rf")

  if not ok then
    error(err)
  end
end)

io.write(string.format("%d tests, %d failures\n", tests, failures))

if failures > 0 then
  vim.cmd("cquit 1")
end
