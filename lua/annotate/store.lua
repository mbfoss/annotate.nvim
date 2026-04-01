local M = {}

local config = require("annotate.config")

--- Where the notes live between sessions.
---
--- One JSON file per project root, under `stdpath("data")/annotate`. Nothing is
--- written into the project itself: notes are a private reading aid, not
--- something to commit, and a repository checked out twice keeps a set per
--- checkout because the root -- not the file -- is the key.
---
--- Paths are stored relative to the root wherever they are under it, so moving
--- or cloning a project elsewhere does not orphan its notes. A note on a file
--- outside the root (a header opened from `/usr/include`, a dependency read
--- out of tree) keeps its absolute path.

local _VERSION = 1

---@class annotate.StoredNote
---@field file string   relative to the root when under it, absolute otherwise
---@field lnum integer  1-based
---@field text string

--- The store file for `root`. The basename is there to make the directory
--- readable by a human; the digest is what actually distinguishes two roots
--- with the same name.
---@param root string
---@return string
function M.path(root)
    local name = vim.fn.fnamemodify(root:gsub("/+$", ""), ":t")
    if name == "" then name = "root" end
    name = name:gsub("[^%w%-_.]", "_")
    local digest = vim.fn.sha256(root):sub(1, 12)
    return vim.fs.joinpath(config.values.storage_dir, ("%s-%s.json"):format(name, digest))
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

--- Read the notes recorded for `root`, as absolute paths. A store that is
--- missing is simply a project with no notes yet; one that is unreadable or
--- malformed is reported and treated the same way, so a corrupt file costs the
--- session its notes but never its startup.
---@param root string
---@return { file:string, lnum:integer, text:string }[]
function M.load(root)
    local path = M.path(root)
    local fd = io.open(path, "r")
    if not fd then return {} end
    local content = fd:read("*a")
    fd:close()
    if not content or content == "" then return {} end

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" or type(data.notes) ~= "table" then
        vim.notify(("[annotate] ignoring unreadable store %s"):format(path), vim.log.levels.WARN)
        return {}
    end

    local notes = {}
    for _, note in ipairs(data.notes) do
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

--- Write `notes` for `root`, replacing whatever was there.
---
--- Written to a temporary file in the same directory and renamed over the
--- store, so a store that exists is always a complete one: this runs on
--- `VimLeavePre` among other places, where a process that goes away mid-write
--- would otherwise leave a truncated file behind. An empty set removes the
--- store rather than writing an empty one.
---@param root string
---@param notes { file:string, lnum:integer, text:string }[]
---@return boolean ok
function M.save(root, notes)
    local path = M.path(root)

    if #notes == 0 then
        os.remove(path)
        return true
    end

    if vim.fn.isdirectory(config.values.storage_dir) == 0 then
        vim.fn.mkdir(config.values.storage_dir, "p")
    end

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

    local content = vim.json.encode({ version = _VERSION, root = root, notes = stored })

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
