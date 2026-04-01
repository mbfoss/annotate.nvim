local M = {}

--- Extmarks keyed by *file* rather than by buffer.
---
--- A note outlives the buffer it was set in: it is restored from disk before
--- anything is open, it survives the buffer being unloaded, and it has to come
--- back at the right line when the file is opened again. Neovim's extmarks are
--- per buffer and vanish with it, so a group keeps its own table of
--- `file -> id -> mark` as the durable copy, and mirrors it into whichever
--- buffers happen to be loaded.
---
--- Positions therefore have two sources. While a file is loaded the buffer is
--- authoritative -- the extmark has been tracking the user's edits -- so reads
--- go to `nvim_buf_get_extmarks` and the table is refreshed from it. While it
--- is not, the table is all there is.

---@class annotate.MarkInfo
---@field id   integer
---@field file string   absolute path
---@field lnum integer  1-based
---@field col  integer  0-based
---@field data any      payload carried alongside the extmark

---@class annotate.extmarks.Mark
---@field id   integer
---@field lnum integer
---@field col  integer
---@field opts vim.api.keyset.set_extmark
---@field data any

---@class annotate.Group
---@field ns integer
---@field priority integer
---@field byfile table<string, table<integer, annotate.extmarks.Mark>>
---@field id_to_file table<integer, string>
local Group = {}
Group.__index = Group

---@type annotate.Group[]
local _groups = {}
local _augroup

---@param file string
---@return string
local function _normalize(file)
    return vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
end

--- The loaded buffer for `file`, or -1. An unloaded buffer is no better than
--- no buffer here: it has no lines to place an extmark against.
---@param file string
---@return integer
local function _loaded_buf(file)
    local bufnr = vim.fn.bufnr(file, false)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then return bufnr end
    return -1
end

--- Place `mark` in `bufnr`, clamped to what the buffer actually has. A file
--- can have been shortened since the notes were written, and a stale line
--- number would otherwise be an error rather than a note at the end.
---@param bufnr integer
---@param ns integer
---@param mark annotate.extmarks.Mark
local function _place(bufnr, ns, mark)
    if not vim.api.nvim_buf_is_loaded(bufnr) then return end
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count == 0 then return end

    local lnum = math.max(1, math.min(mark.lnum, line_count))
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
    local col = math.max(0, math.min(mark.col, #line))
    mark.lnum, mark.col = lnum, col

    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, col, mark.opts)
end

--- Autocommands shared by every group, installed with the first one: buffers
--- get their marks as they are read, and give their positions back as they are
--- written. Between those two points the buffer's copy is the current one and
--- the table is behind; `BufWritePost` is where the drift is folded back in,
--- so a note saved to disk names the line the user just wrote.
local function _ensure_autocmds()
    if _augroup then return end
    _augroup = vim.api.nvim_create_augroup("annotate.extmarks", { clear = true })

    vim.api.nvim_create_autocmd("BufReadPost", {
        group = _augroup,
        callback = function(ev)
            for _, group in ipairs(_groups) do group:attach(ev.buf) end
        end,
    })

    vim.api.nvim_create_autocmd("BufWritePost", {
        group = _augroup,
        callback = function(ev)
            for _, group in ipairs(_groups) do group:sync(ev.buf) end
        end,
    })
end

--- A group of file-keyed extmarks in a namespace of its own.
---@param name string     namespace suffix, for debugging
---@param opts { priority: integer }
---@return annotate.Group
function M.new(name, opts)
    _ensure_autocmds()
    local group = setmetatable({
        ns         = vim.api.nvim_create_namespace("annotate_" .. name),
        priority   = opts.priority,
        byfile     = {},
        id_to_file = {},
    }, Group)
    _groups[#_groups + 1] = group
    return group
end

--- Add or move a mark. Reusing an `id` moves it, including across files.
---@param id integer
---@param file string
---@param lnum integer  1-based
---@param col integer   0-based
---@param opts vim.api.keyset.set_extmark
---@param data any
function Group:set(id, file, lnum, col, opts, data)
    assert(lnum >= 1, "lnum must be 1-based")
    file = _normalize(file)

    local old_file = self.id_to_file[id]
    if old_file then
        local old_buf = _loaded_buf(old_file)
        if old_buf >= 0 then
            pcall(vim.api.nvim_buf_del_extmark, old_buf, self.ns, id)
        end
        local old_table = self.byfile[old_file]
        if old_table then old_table[id] = nil end
    end

    local mark = {
        id   = id,
        lnum = lnum,
        col  = col,
        opts = vim.tbl_extend("force", { id = id, priority = self.priority }, opts or {}),
        data = data,
    }

    self.id_to_file[id] = file
    self.byfile[file] = self.byfile[file] or {}
    self.byfile[file][id] = mark

    local bufnr = _loaded_buf(file)
    if bufnr >= 0 then _place(bufnr, self.ns, mark) end
end

---@param id integer
function Group:remove(id)
    local file = self.id_to_file[id]
    if not file then return end
    self.id_to_file[id] = nil

    local file_table = self.byfile[file]
    if file_table then
        file_table[id] = nil
        if next(file_table) == nil then self.byfile[file] = nil end
    end

    local bufnr = _loaded_buf(file)
    if bufnr >= 0 then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, self.ns, id)
    end
end

---@param file string
function Group:remove_file(file)
    file = _normalize(file)
    local file_table = self.byfile[file]
    if not file_table then return end

    for id in pairs(file_table) do self.id_to_file[id] = nil end
    self.byfile[file] = nil

    local bufnr = _loaded_buf(file)
    if bufnr >= 0 then
        vim.api.nvim_buf_clear_namespace(bufnr, self.ns, 0, -1)
    end
end

function Group:clear()
    for file in pairs(self.byfile) do
        local bufnr = _loaded_buf(file)
        if bufnr >= 0 then
            vim.api.nvim_buf_clear_namespace(bufnr, self.ns, 0, -1)
        end
    end
    self.byfile = {}
    self.id_to_file = {}
end

--- Draw this group's marks for `file` into `bufnr`, which is what makes a note
--- appear when its file is opened.
---@param bufnr integer
function Group:attach(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then return end
    local file_table = self.byfile[_normalize(name)]
    if not file_table then return end
    for _, mark in pairs(file_table) do
        _place(bufnr, self.ns, mark)
    end
end

--- Copy the positions the extmarks have drifted to in `bufnr` back into the
--- table.
---@param bufnr integer
function Group:sync(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then return end
    local file_table = self.byfile[_normalize(name)]
    if not file_table then return end

    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, self.ns, 0, -1, {})) do
        local mark = file_table[m[1]]
        if mark then
            mark.lnum, mark.col = m[2] + 1, m[3]
        end
    end
end

---@param id integer
---@return annotate.MarkInfo?
function Group:get(id)
    local file = self.id_to_file[id]
    if not file then return nil end
    local mark = self.byfile[file] and self.byfile[file][id]
    if not mark then return nil end

    local bufnr = _loaded_buf(file)
    if bufnr >= 0 then
        local got = vim.api.nvim_buf_get_extmark_by_id(bufnr, self.ns, id, {})
        if got and got[1] then
            mark.lnum, mark.col = got[1] + 1, got[2]
        end
    end
    return { id = id, file = file, lnum = mark.lnum, col = mark.col, data = mark.data }
end

--- The mark on `lnum` of `file`, if there is one.
---@param file string
---@param lnum integer  1-based
---@return annotate.MarkInfo?
function Group:get_at(file, lnum)
    assert(lnum >= 1, "lnum must be 1-based")
    file = _normalize(file)

    local bufnr = _loaded_buf(file)
    if bufnr >= 0 then
        local found = vim.api.nvim_buf_get_extmarks(
            bufnr, self.ns, { lnum - 1, 0 }, { lnum - 1, -1 }, {})
        if #found == 0 then return nil end
        return self:get(found[1][1])
    end

    for id, mark in pairs(self.byfile[file] or {}) do
        if mark.lnum == lnum then
            return { id = id, file = file, lnum = mark.lnum, col = mark.col, data = mark.data }
        end
    end
    return nil
end

--- Every mark in the group, with the positions loaded buffers have moved them
--- to. Unordered: callers that show them sort for themselves.
---@return annotate.MarkInfo[]
function Group:get_all()
    local result = {}
    for file, file_table in pairs(self.byfile) do
        local bufnr = _loaded_buf(file)
        if bufnr >= 0 then
            for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, self.ns, 0, -1, {})) do
                local mark = file_table[m[1]]
                if mark then
                    mark.lnum, mark.col = m[2] + 1, m[3]
                    result[#result + 1] = {
                        id = mark.id, file = file, lnum = mark.lnum, col = mark.col, data = mark.data,
                    }
                end
            end
        else
            for _, mark in pairs(file_table) do
                result[#result + 1] = {
                    id = mark.id, file = file, lnum = mark.lnum, col = mark.col, data = mark.data,
                }
            end
        end
    end
    return result
end

return M
