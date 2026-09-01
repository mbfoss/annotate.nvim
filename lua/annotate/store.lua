local M = {}

local config = require("annotate.config")

--- Where the notes live between sessions.
---
--- One JSON file, `stdpath("data")/annotate.json` by default, holding every
--- note as a map from file to the notes on it. There is no project in the
--- store: it is the notes of whoever reads it. A store per project is a
--- `storage_file` that returns a path inside the project, which is also what
--- makes two checkouts of a repository keep two sets.
---
--- Paths are stored relative to the directory the store itself is in when they
--- are under it, so a store kept inside a project survives the project being
--- moved or cloned elsewhere. A note on a file outside that directory -- every
--- note, for the default store under `stdpath("data")` -- keeps its absolute
--- path.
---
--- Every write replaces the whole file, so reading and writing are never far
--- enough apart for another session's notes to be read stale and written back
--- over.

local _VERSION = 2

---@class annotate.StoredNote
---@field lnum integer  1-based
---@field text string

---@class annotate.StoredFile
---@field version integer
---@field notes table<string, annotate.StoredNote[]>  keyed by file, relative
---                        to the store's directory when under it

--- The file the notes are written to.
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

---@param file string
---@return boolean
local function _is_absolute(file)
    return vim.fs.normalize(file):sub(1, 1) == "/" or file:match("^%a:[/\\]") ~= nil
end

---@param base string  the store's directory
---@param file string  absolute
---@return string
local function _relative(base, file)
    return vim.fs.relpath(base, file) or file
end

---@param base string  the store's directory
---@param file string  relative or absolute
---@return string absolute
local function _absolute(base, file)
    if _is_absolute(file) then return vim.fs.normalize(file) end
    return vim.fs.normalize(vim.fs.joinpath(base, file))
end

---@param note any
---@return boolean
local function _valid(note)
    return type(note) == "table" and type(note.text) == "string" and type(note.lnum) == "number"
end

--- Version 1 kept the notes of every project in one file, bucketed by project
--- root, with the paths inside a bucket relative to that root. Those roots are
--- absolute, so flattening them loses nothing: what was a bucket for a project
--- other than this one becomes a note on an absolute path, still listed and
--- still removable.
---@param data table
---@return { file:string, lnum:integer, text:string }[]
local function _from_v1(data)
    local notes = {}
    for root, stored in pairs(data.roots) do
        if type(root) == "string" and type(stored) == "table" then
            for _, note in ipairs(stored) do
                if _valid(note) and type(note.file) == "string" then
                    notes[#notes + 1] = {
                        file = _absolute(root, note.file),
                        lnum = math.max(1, math.floor(note.lnum)),
                        text = note.text,
                    }
                end
            end
        end
    end
    return notes
end

--- Every note in the store, as absolute paths.
---
--- A file that is missing is simply a store with no notes in it yet; one that
--- is unreadable or malformed is reported and treated the same way, so a
--- corrupt file costs the session its notes but never its startup.
---@return { file:string, lnum:integer, text:string }[]
function M.load()
    local path = M.path()
    local fd = io.open(path, "r")
    if not fd then return {} end
    local content = fd:read("*a")
    fd:close()
    if not content or content == "" then return {} end

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then
        vim.notify(("[annotate] ignoring unreadable store %s"):format(path), vim.log.levels.WARN)
        return {}
    end

    if type(data.roots) == "table" then return _from_v1(data) end

    if type(data.notes) ~= "table" then
        vim.notify(("[annotate] ignoring unreadable store %s"):format(path), vim.log.levels.WARN)
        return {}
    end

    local base = vim.fs.dirname(path)
    local notes = {}
    for file, stored in pairs(data.notes) do
        if type(file) == "string" and type(stored) == "table" then
            for _, note in ipairs(stored) do
                if _valid(note) then
                    notes[#notes + 1] = {
                        file = _absolute(base, file),
                        lnum = math.max(1, math.floor(note.lnum)),
                        text = note.text,
                    }
                end
            end
        end
    end
    return notes
end

--- Write `notes`, replacing the store.
---
--- Written to a temporary file in the same directory and renamed over the
--- store, so a store that exists is always a complete one: this runs on
--- `VimLeavePre` among other places, where a process that goes away mid-write
--- would otherwise leave a truncated file behind. A store with no notes left
--- is removed rather than written empty.
---@param notes { file:string, lnum:integer, text:string }[]
---@return boolean ok
function M.save(notes)
    local path = M.path()

    if #notes == 0 then
        os.remove(path)
        return true
    end

    local base = vim.fs.dirname(path)
    ---@type table<string, annotate.StoredNote[]>
    local by_file = {}
    for _, note in ipairs(notes) do
        local file = _relative(base, note.file)
        local list = by_file[file]
        if not list then
            list = {}
            by_file[file] = list
        end
        list[#list + 1] = { lnum = note.lnum, text = note.text }
    end
    for _, list in pairs(by_file) do
        table.sort(list, function(a, b) return a.lnum < b.lnum end)
    end

    if vim.fn.isdirectory(base) == 0 then
        vim.fn.mkdir(base, "p")
    end

    local content = vim.json.encode({ version = _VERSION, notes = by_file })

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
