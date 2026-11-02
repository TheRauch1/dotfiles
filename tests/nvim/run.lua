-- Headless test runner. Run from any directory:
--   nvim --headless -c "luafile <repo>/tests/nvim/run.lua"
-- Env: TEST_DIR (default: this file's dir), TEST_FILTER (substring of
-- "file::name"), UPDATE_SNAPSHOTS=1 (rewrite snapshots instead of comparing).
-- Every TEST_DIR/test_*.lua returns { [name] = function() end }.
-- Reused by other repos: point TEST_DIR at their own tests.

local here = debug.getinfo(1, "S").source:sub(2):match("(.*)/") or "."
local dir = vim.env.TEST_DIR or here
local filter = vim.env.TEST_FILTER
local update = vim.env.UPDATE_SNAPSHOTS == "1"

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local notify_orig = vim.notify
local time_orig = os.time
local captured

T = {}

function T.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(("%sexpected: %s\n  actual: %s"):format(
      msg and (msg .. "\n  ") or "", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

function T.ok(v, msg)
  if not v then error(msg or "expected a truthy value", 2) end
end

function T.lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

function T.fixture(rel)
  return read(dir .. "/fixtures/" .. rel)
end

function T.json(rel)
  return vim.json.decode(T.fixture(rel))
end

function T.snapshot(name, lines)
  local path = dir .. "/snapshots/" .. name .. ".txt"
  local text = table.concat(lines, "\n") .. "\n"
  if update then
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
    return
  end
  local f = io.open(path, "rb")
  if not f then error("missing snapshot " .. path .. " (UPDATE_SNAPSHOTS=1 to create)", 2) end
  local want = f:read("*a")
  f:close()
  if want ~= text then
    error(("snapshot %s differs\nexpected:\n%s\nactual:\n%s"):format(name, want, text), 2)
  end
end

function T.freeze_time(epoch)
  os.time = function(t)
    if t == nil then return epoch end
    return time_orig(t)
  end
end

function T.notifications()
  if not captured then
    captured = {}
    vim.notify = function(msg, level)
      captured[#captured + 1] = { msg = msg, level = level }
    end
  end
  return captured
end

function T.wait(fn, ms)
  return vim.wait(ms or 2000, fn, 10)
end

local passed, failed = 0, 0
local files = vim.fn.glob(dir .. "/test_*.lua", false, true)
table.sort(files)

for _, file in ipairs(files) do
  local fname = vim.fn.fnamemodify(file, ":t:r")
  local ok, tests = pcall(dofile, file)
  if not ok then
    failed = failed + 1
    print(("FAIL %s: %s"):format(fname, tests))
  else
    local names = vim.tbl_keys(tests)
    table.sort(names)
    for _, name in ipairs(names) do
      local id = fname .. "::" .. name
      if not filter or id:find(filter, 1, true) then
        local rok, err = pcall(tests[name])
        if rok then
          passed = passed + 1
          print("PASS " .. id)
        else
          failed = failed + 1
          print(("FAIL %s: %s"):format(id, tostring(err)))
        end
        pcall(vim.cmd, "silent! %bwipeout!")
        vim.notify = notify_orig
        os.time = time_orig
        captured = nil
      end
    end
  end
end

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then vim.cmd("cquit 1") else vim.cmd("qa!") end
