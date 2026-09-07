local M = {}

local config = require("annotate.config")

--- Where the notes live between sessions: one JSON file, a map from file to the
--- notes on it, with paths relative to the store's directory when under it.

---@class annotate.StoredNote
---@field lnum integer  1-based
---@field text string

---@class annotate.StoredFile
---@field notes table<string, annotate.StoredNote[]>  keyed by file, relative
---                        to the store's directory when under it

--- The notes this session read or wrote. A note on disk that is not in here is
--- another session's; one in here the session no longer holds it deleted.
---@type table<string, true>
local _baseline = {}

--- The store this session resolved, so that writes go to the file the baseline
--- describes. Nil before it has read one.
---@type string?
local _path = nil

---@param note { file:string, lnum:integer }
---@return string
local function _key(note)
    return ("%s\0%d"):format(note.file, note.lnum)
end

--- The store `storage_file` names now: the call to it, with anything but a path
--- meaning the default store. Differing from `M.path()` is what `reload` acts on.
---@return string
function M.resolve()
    local file = config.values.storage_file
    if type(file) == "function" then file = file() end
    if type(file) ~= "string" or file == "" then file = config.default_storage_file() end
    return vim.fs.normalize(file)
end

--- The file the notes are read from and written to. Held from first use so a
--- read and the writes merging against it cannot be about two different files.
---@return string
function M.path()
    _path = _path or M.resolve()
    return _path
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

--- Flatten a version 1 store (notes bucketed by project root). The roots are
--- absolute, so each bucket becomes notes on absolute paths.
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

--- Read the store at `path`, as absolute paths. Missing, unreadable or
--- malformed is an empty store; `quiet` drops the report, for the read a write does.
---@param path string
---@param quiet boolean?
---@return { file:string, lnum:integer, text:string }[]
local function _read(path, quiet)
    local fd = io.open(path, "r")
    if not fd then return {} end
    local content = fd:read("*a")
    fd:close()
    if not content or content == "" then return {} end

    local function unreadable()
        if not quiet then
            vim.notify(("[annotate] ignoring unreadable store %s"):format(path), vim.log.levels.WARN)
        end
        return {}
    end

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then return unreadable() end

    if type(data.roots) == "table" then return _from_v1(data) end

    if type(data.notes) ~= "table" then return unreadable() end

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

--- Every note in the store, as absolute paths, kept as the baseline later
--- writes merge against. Resolves the store again: this path is the one they use.
---@return { file:string, lnum:integer, text:string }[]
function M.load()
    _path = nil
    local notes = _read(M.path())
    _baseline = {}
    for _, note in ipairs(notes) do
        _baseline[_key(note)] = true
    end
    return notes
end

--- What to write for a session holding `notes`, given `stored` on disk: `notes`
--- wins, another session's are kept, ones this session read and dropped go.
---@param notes { file:string, lnum:integer, text:string }[]
---@param stored { file:string, lnum:integer, text:string }[]
---@return { file:string, lnum:integer, text:string }[]
local function _merge(notes, stored)
    local merged, held = {}, {}
    for _, note in ipairs(notes) do
        held[_key(note)] = true
        merged[#merged + 1] = note
    end
    for _, note in ipairs(stored) do
        local key = _key(note)
        if not held[key] and not _baseline[key] then merged[#merged + 1] = note end
    end
    return merged
end

--- Write `notes`, merged into the store on disk, through a temporary file so a
--- store that exists is complete. `replace` skips the merge, for `clear_all`.
---@param notes { file:string, lnum:integer, text:string }[]
---@param replace boolean?
---@return boolean ok
function M.save(notes, replace)
    local path = M.path()
    local merged = replace and notes or _merge(notes, _read(path, true))

    local function agreed()
        _baseline = {}
        for _, note in ipairs(notes) do
            _baseline[_key(note)] = true
        end
    end

    if #merged == 0 then
        os.remove(path)
        agreed()
        return true
    end

    local base = vim.fs.dirname(path)
    ---@type table<string, annotate.StoredNote[]>
    local by_file = {}
    for _, note in ipairs(merged) do
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

    local content = vim.json.encode({ notes = by_file })

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
    agreed()
    return true
end

return M
