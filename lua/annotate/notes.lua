local M = {}

local config       = require("annotate.config")
local fileextmarks = require("annotate.util.fileextmarks")
local store        = require("annotate.store")
local ui           = require("annotate.ui")

--- Line notes: a piece of text attached to a line of a file, drawn as virtual
--- text at the end of it and remembered between sessions.
---
--- A note is an extmark, which is what makes it follow the line as the file is
--- edited rather than sitting at a line number that drifts out from under it.
--- `util/fileextmarks` keeps the copy that outlives the buffer; this module
--- owns what a note *is* -- its text, how it is drawn, when it is written out
--- -- and the commands over it.

---@class annotate.Note
---@field file string   absolute path
---@field lnum integer  1-based
---@field text string

---@type annotate.util.fileextmarks.GroupFunctions?
local _group

local _loaded = false
local _root ---@type string?

--- Extmark ids are per namespace and only have to be unique within it;
--- counting up from one and never reusing is enough, since a session sets
--- notes by hand.
local _last_id = 0

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[annotate] " .. msg, level or vim.log.levels.INFO)
end

--- How a note is drawn: virtual text on its line, a sign in the gutter, or
--- both. `virt_text_pos = "off"` and `sign = ""` each turn their half off, so
--- a sign-only note is the pair of them; a note with neither is still a note,
--- and still in `:Annotate list`, it just leaves the line alone.
---@param text string
---@return vim.api.keyset.set_extmark
local function _extmark_opts(text)
    local cfg = config.values
    ---@type vim.api.keyset.set_extmark
    local opts = {
        hl_mode = "combine",
        priority = cfg.priority,
    }

    if cfg.virt_text_pos ~= "off" then
        opts.virt_text = { { (" %s %s"):format(cfg.symbol, text), cfg.hl } }
        opts.virt_text_pos = cfg.virt_text_pos
    end

    if cfg.sign ~= "" then
        opts.sign_text = cfg.sign
        opts.sign_hl_group = cfg.hl
    end

    return opts
end

--- A colorscheme clears highlight groups, so the group is (re)defined whenever
--- one is loaded. `default = true` throughout: a colorscheme that has an
--- opinion about `AnnotateNote` wins over this one.
local function _define_hl()
    vim.api.nvim_set_hl(0, "AnnotateNote", { link = "Todo", default = true })
end

---@param file string
---@return string
local function _norm(file)
    return vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
end

--- Read the store and draw what is in it, once per session. Every entry point
--- goes through here, so the notes are there whether the session started by
--- opening a file or by running a command.
function M.load()
    if _loaded then return end
    _loaded = true

    _define_hl()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("annotate.hl", { clear = true }),
        callback = _define_hl,
    })

    _root = config.values.root()
    -- The prefix every namespace and augroup `util/fileextmarks` creates is
    -- named after; claimed once, before any group is defined.
    fileextmarks.init("annotate")
    _group = fileextmarks.define_group("notes")

    for _, note in ipairs(store.load(_root)) do
        _last_id = _last_id + 1
        _group.set_file_extmark(_last_id, note.file, note.lnum, 0, _extmark_opts(note.text), { text = note.text })
    end

    local augroup = vim.api.nvim_create_augroup("annotate.save", { clear = true })
    -- Writing a file is where the lines the notes have drifted to become the
    -- lines on disk, and so the point at which the store is out of date even
    -- if no note was touched.
    vim.api.nvim_create_autocmd({ "BufWritePost", "VimLeavePre" }, {
        group = augroup,
        callback = function() M.save() end,
    })
end

--- Draw the notes in the buffer that was being read when the plugin loaded.
--- Loading is all it takes: `define_group` sweeps the buffers that are already
--- loaded, which during `BufReadPost` includes this one, and from then on
--- `util/fileextmarks` picks buffers up through its own autocommand.
---@param _bufnr integer
function M.attach(_bufnr)
    M.load()
end

--- Redraw every note with the current configuration. Only needed when
--- `setup()` runs after the notes have already been drawn -- a session that
--- opened a file before the configuration was applied.
function M.refresh()
    if not _loaded then return end
    local group = assert(_group)
    _define_hl()

    -- Rebuilt rather than `group.refresh()`ed: the drawing options are held on
    -- the marks themselves, so redrawing the existing ones would redraw them
    -- under the old configuration.
    local notes = M.list()
    group.remove_extmarks()
    for _, note in ipairs(notes) do
        _last_id = _last_id + 1
        group.set_file_extmark(_last_id, note.file, note.lnum, 0, _extmark_opts(note.text), { text = note.text })
    end
end

-------- PUBLIC API --------

--- Write the notes out. A no-op with `auto_save = false`, which leaves saving
--- entirely to the caller.
---@param force boolean?  save even with `auto_save = false`
function M.save(force)
    if not _loaded then return end
    if not (force or config.values.auto_save) then return end
    store.save(assert(_root), M.list())
end

--- Set the note on a line, replacing any note already there.
---@param file string
---@param lnum integer  1-based
---@param text string
function M.set(file, lnum, text)
    M.load()
    if text == "" then return end
    file = _norm(file)

    local existing = assert(_group).get_extmark_by_location(file, lnum, true)
    local id = existing and existing.id
    if not id then
        _last_id = _last_id + 1
        id = _last_id
    end

    _group.set_file_extmark(id, file, lnum, 0, _extmark_opts(text), { text = text })
    M.save()
end

--- The text of the note on a line, if there is one.
---@param file string
---@param lnum integer  1-based
---@return string?
function M.get(file, lnum)
    M.load()
    local info = assert(_group).get_extmark_by_location(_norm(file), lnum, true)
    return info and info.user_data.text or nil
end

--- Remove the note on a line, if there is one.
---@param file string
---@param lnum integer  1-based
---@return boolean removed
function M.remove(file, lnum)
    M.load()
    local info = assert(_group).get_extmark_by_location(_norm(file), lnum, true)
    if not info then return false end
    _group.remove_extmark(info.id)
    M.save()
    return true
end

--- Remove every note in a file.
---@param file string
function M.clear_file(file)
    M.load()
    assert(_group).remove_file_extmarks(_norm(file))
    M.save()
end

--- Remove every note in the project.
function M.clear_all()
    M.load()
    assert(_group).remove_extmarks()
    M.save()
end

--- Every note, ordered by file and then by line.
---@return annotate.Note[]
function M.list()
    M.load()
    local notes = {}
    -- `live`: where a file is open, the buffer's extmarks are what have been
    -- tracking the user's edits, so they -- not the stored line -- are current.
    for _, info in ipairs(assert(_group).get_extmarks(true)) do
        notes[#notes + 1] = { file = info.file, lnum = info.lnum, text = info.user_data.text }
    end
    table.sort(notes, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
    end)
    return notes
end

-------- COMMANDS --------

--- Set or edit the note on the current line. An existing note is offered as
--- the prompt's initial text, so the command is "edit this note" as much as it
--- is "add one"; clearing the prompt removes it.
function M.set_at_cursor()
    M.load()
    local file, lnum = ui.cursor_location()
    if not (file and lnum) then
        _notify("no file in the current window", vim.log.levels.WARN)
        return
    end

    local existing = M.get(file, lnum)
    ui.input("Note", existing, function(text)
        text = vim.trim(text)
        if text == "" then
            if existing then M.remove(file, lnum) end
            return
        end
        M.set(file, lnum, text)
    end)
end

--- Remove the note on the current line.
function M.delete_at_cursor()
    local file, lnum = ui.cursor_location()
    if not (file and lnum) then
        _notify("no file in the current window", vim.log.levels.WARN)
        return
    end
    if not M.remove(file, lnum) then
        _notify("no note on this line")
    end
end

--- Remove every note in the current file, after confirmation.
function M.clear_current_file()
    local file = ui.cursor_location()
    if not file then
        _notify("no file in the current window", vim.log.levels.WARN)
        return
    end
    ui.confirm(("Clear all notes in %s"):format(vim.fn.fnamemodify(file, ":t")), function(confirmed)
        if confirmed then M.clear_file(file) end
    end)
end

--- Remove every note in the project, after confirmation.
function M.clear_all_confirm()
    ui.confirm("Clear all notes in this project", function(confirmed)
        if confirmed then M.clear_all() end
    end)
end

--- Pick a note and jump to it. Goes through `vim.ui.select`, so it is the
--- picker the user already has.
function M.select()
    local notes = M.list()
    if #notes == 0 then
        _notify("no notes set")
        return
    end

    local root = assert(_root)
    vim.ui.select(notes, {
        prompt = "Notes",
        format_item = function(note)
            return ("%s:%d  %s"):format(
                vim.fs.relpath(root, note.file) or note.file,
                note.lnum,
                note.text:gsub("%s+", " "))
        end,
    }, function(note)
        if note then ui.open(note.file, note.lnum) end
    end)
end

--- Put the notes in the quickfix list and open it, for reading them as a list
--- rather than one at a time.
function M.qflist()
    local notes = M.list()
    if #notes == 0 then
        _notify("no notes set")
        return
    end

    local items = {}
    for _, note in ipairs(notes) do
        items[#items + 1] = {
            filename = note.file,
            lnum = note.lnum,
            col = 1,
            text = note.text:gsub("%s+", " "),
        }
    end
    vim.fn.setqflist({}, " ", { title = "Notes", items = items })
    vim.cmd("copen")
end

return M
