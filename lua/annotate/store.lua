local M = {}

local config = require("annotate.config")

--- Where the notes live between sessions.
---
--- One JSON file for every project, under `stdpath("data")`, with the notes
--- keyed by project root inside it. Nothing is written into the project
--- itself: notes are a private reading aid, not something to commit, and a
--- repository checked out twice keeps a set per checkout because the root --
--- not the file -- is the key.
---
--- Paths are stored relative to their root wherever they are under it, so
--- moving or cloning a project elsewhere does not orphan its notes. A note on
--- a file outside the root (a header opened from `/usr/include`, a dependency
--- read out of tree) keeps its absolute path.
---
--- Every write rewrites the whole file, roots this session never touched
--- included, so reading is always immediately before writing and the two are
--- never far enough apart for another session's notes to be read stale and
--- written back over.

local _VERSION = 1

---@class annotate.StoredNote
---@field file string   relative to the root when under it, absolute otherwise
---@field lnum integer  1-based
---@field text string

---@class annotate.StoredFile
---@field version integer
---@field roots table<string, annotate.StoredNote[]>

--- The file every project's notes are written to.
---
--- `storage_file` may be a function so that the path can depend on something
--- that is not known at `setup()` time -- the current directory, say -- and
--- it is resolved here, at every use, rather than once.
---@return string
function M.path()
    local file = config.values.storage_file
    if type(file) == "function" then file = file() end
    return vim.fs.normalize(file)
end

---@param root string
---@param file string  absolute
---@return string
local function _relative(root, file)
    return vim.fs.relpath(root, file) or file
end

---@param root string
---@param file string  relative or absolute
---@return string absolute
local function _absolute(root, file)
    if vim.fs.normalize(file):sub(1, 1) == "/" or file:match("^%a:[/\\]") then
        return vim.fs.normalize(file)
    end
    return vim.fs.normalize(vim.fs.joinpath(root, file))
end

--- Read the whole store. A file that is missing is simply a store with no
--- notes in it yet; one that is unreadable or malformed is reported and
--- treated the same way, so a corrupt file costs the session its notes but
--- never its startup.
---@return table<string, annotate.StoredNote[]>
local function _read()
    local path = M.path()
    local fd = io.open(path, "r")
    if not fd then return {} end
    local content = fd:read("*a")
    fd:close()
    if not content or content == "" then return {} end

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" or type(data.roots) ~= "table" then
        vim.notify(("[annotate] ignoring unreadable store %s"):format(path), vim.log.levels.WARN)
        return {}
    end

    local roots = {}
    for root, notes in pairs(data.roots) do
        if type(root) == "string" and type(notes) == "table" then
            roots[root] = notes
        end
    end
    return roots
end

--- The notes recorded for `root`, as absolute paths.
---@param root string
---@return { file:string, lnum:integer, text:string }[]
function M.load(root)
    local notes = {}
    for _, note in ipairs(_read()[root] or {}) do
        if type(note) == "table" and type(note.file) == "string"
            and type(note.text) == "string" and type(note.lnum) == "number" then
            notes[#notes + 1] = {
                file = _absolute(root, note.file),
                lnum = math.max(1, math.floor(note.lnum)),
                text = note.text,
            }
        end
    end
    return notes
end

--- Write `notes` for `root`, replacing whatever was there and leaving the
--- other roots as they are.
---
--- Written to a temporary file in the same directory and renamed over the
--- store, so a store that exists is always a complete one: this runs on
--- `VimLeavePre` among other places, where a process that goes away mid-write
--- would otherwise leave a truncated file behind. A root with no notes drops
--- out of the store, and a store with no roots left is removed rather than
--- written empty.
---@param root string
---@param notes { file:string, lnum:integer, text:string }[]
---@return boolean ok
function M.save(root, notes)
    local path = M.path()
    local roots = _read()

    if #notes == 0 then
        roots[root] = nil
        if next(roots) == nil then
            os.remove(path)
            return true
        end
    else
        ---@type annotate.StoredNote[]
        local stored = {}
        for _, note in ipairs(notes) do
            stored[#stored + 1] = {
                file = _relative(root, note.file),
                lnum = note.lnum,
                text = note.text,
            }
        end
        table.sort(stored, function(a, b)
            if a.file ~= b.file then return a.file < b.file end
            return a.lnum < b.lnum
        end)
        roots[root] = stored
    end

    local dir = vim.fs.dirname(path)
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end

    local content = vim.json.encode({ version = _VERSION, roots = roots })

    local tmp = path .. ".tmp"
    local fd = io.open(tmp, "w")
    if not fd then
        vim.notify(("[annotate] cannot write %s"):format(tmp), vim.log.levels.ERROR)
        return false
    end
    fd:write(content)
    fd:close()

    local ok, err = vim.uv.fs_rename(tmp, path)
    if not ok then
        os.remove(tmp)
        vim.notify(("[annotate] cannot replace %s: %s"):format(path, tostring(err)), vim.log.levels.ERROR)
        return false
    end
    return true
end

return M
