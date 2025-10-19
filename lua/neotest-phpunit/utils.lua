local logger = require("neotest.logging")
local lib = require("neotest.lib")

local M = {}
local separator = "::"

---Generate an id which we can use to match Treesitter queries and PHPUnit tests
---@param position neotest.Position The position to return an ID for
---@param namespace neotest.Position[] Any namespaces the position is within
---@return string
M.make_test_id = function(position)
  -- Treesitter starts line numbers from 0 so we add 1
  local id = position.path .. separator .. (tonumber(position.range[1]) + 1)

  logger.info("Path to test file:", { position.path })
  logger.info("Treesitter id:", { id })

  return id
end

---Recursively iterate through a deeply nested table to obtain specified keys
---@param data_table table
---@param key string
---@param output_table table
---@return table
local function iterate_key(data_table, key, output_table)
  if type(data_table) == "table" then
    for k, v in pairs(data_table) do
      if key == k then
        table.insert(output_table, v)
      end
      iterate_key(v, key, output_table)
    end
  end
  return output_table
end

---Extract the failure messages from the tests
---@param tests table,
---@return boolean|table
local function errors_or_fails(tests)
  local errors_fails = {}

  iterate_key(tests, "error", errors_fails)
  iterate_key(tests, "failure", errors_fails)

  if #errors_fails == 0 then
    return false
  end

  return errors_fails
end

---Make the outputs for a given test
---@param test table
---@param output_file string
---@return table
local function make_outputs(test, output_file, project_root)
  local test_attr = test["_attr"] or test[1]["_attr"]

  local file = test_attr.file
  if file then
    if type(file) == "string" and not lib.files.exists(file) then
      local suff = file:match("(/tests/.*)$")
      if suff and project_root then
        file = vim.fs.joinpath(project_root, suff)
      end
    end
  end

  local test_id = file .. "::" .. test_attr.line
  logger.debug("JUnit->host path:", { junit = test_attr.file, host = file, id = test_id })

  local classname = test_attr.classname or test_attr.class
  local test_output = {
    status = "passed",
    short = string.upper(classname) .. "\n-> " .. "PASSED" .. " - " .. test_attr.name,
    output_file = output_file,
  }

  local test_failed = errors_or_fails(test)
  if test_failed then
    local error_message = test_failed[1][1]
    test_output.status = "failed"
    test_output.short = error_message

    local errors = {}

    -- Extract error lines from the stack trace
    -- Format: /path/to/file.php:123
    for line_info in error_message:gmatch("([^\n]+%.php:%d+)") do
      local file, line = line_info:match("(.+):(%d+)")
      if file and line and file == test_attr.file then
        table.insert(errors, {
          line = tonumber(line) - 1,
          message = error_message,
        })
      end
    end

    -- If no matching errors found in the file, add error at test line
    if #errors == 0 then
      table.insert(errors, {
        line = tonumber(test_attr.line) - 1,
        message = error_message,
      })
    end

    test_output.errors = errors
  end

  return test_id, test_output
end

---Iterate through test results and create a table of test IDs and outputs
---@param tests table
---@param output_file string
---@param output_table table
---@return table
local function iterate_test_outputs(tests, output_file, out, project_root)
  for i = 1, #tests do
    if #tests[i] == 0 then
      local id, res = make_outputs(tests[i], output_file, project_root)
      if not (out[id] and out[id].status == "failed") then
        out[id] = res
      end
    else
      iterate_test_outputs(tests[i], output_file, out, project_root)
    end
  end
  return out
end

---Get the test results from the parsed xml
---@param parsed_xml_output table
---@param output_file string
---@return neotest.Result[]
M.get_test_results = function(parsed_xml_output, output_file, project_root)
  local tests = {}
  local function collect(t, key, acc)
    if type(t) == "table" then
      for k, v in pairs(t) do
        if k == key then
          table.insert(acc, v)
        end
        collect(v, key, acc)
      end
    end
    return acc
  end
  collect(parsed_xml_output, "testcase", tests)
  return iterate_test_outputs(tests, output_file, {}, project_root)
end

return M
