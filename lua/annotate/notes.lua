local M = {}

local config       = require("annotate.config")
local fileextmarks = require("annotate.util.fileextmarks")
local store        = require("annotate.store")
local ui           = require("annotate.ui")

--- Line notes: text attached to a line, drawn as virtual text and remembered
--- between sessions. A note is an extmark; `util/fileextmarks` outlives buffers.

---@class annotate.Note
---@field file string   absolute path
---@field lnum integer  1-based
---@field text string

---@type annotate.util.fileextmarks.GroupFunctions?
local _group

local _loaded = false

--- Ids are per namespace; counting up and never reusing is enough.
local _last_id = 0

---@param msg string
---@param level integer?
local function _notify(msg, level)
    vim.notify("[annotate] " .. msg, level or vim.log.levels.INFO)
end

--- How a note is drawn: virtual text, a gutter sign, or both. `virt_text_pos`
--- "off" and `sign` "" each turn their half off; neither still leaves a note.
---@param text string
---@return vim.api.keyset.set_extmark
local function _extmark_opts(text)
    local cfg = config.values
    ---@type vim.api.keyset.set_extmark
    local opts = {
        hl_mode = "combine",
        priority = cfg.priority,
    }

    if cfg.virt_text_pos ~= "off" and cfg.virt_text_pos ~= "" then
        opts.virt_text = { { (" %s %s"):format(cfg.symbol, text), "AnnotateNote" } }
        opts.virt_text_pos = cfg.virt_text_pos --[[@as "eol"|"right_align"]]
    end

    if cfg.sign ~= "" then
        opts.sign_text = cfg.sign
        opts.sign_hl_group = "AnnotateSign"
    end

    return opts
end

--- `AnnotateSign` links to `AnnotateNote`, so setting one colours both. Both
--- are `default`, and redefined on `ColorScheme`, which clears them.
local function _define_hl()
    vim.api.nvim_set_hl(0, "AnnotateNote", { link = "Todo", default = true })
    vim.api.nvim_set_hl(0, "AnnotateSign", { link = "AnnotateNote", default = true })
end

---@param file string
---@return string
local function _norm(file)
    return vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
end

--- Draw `notes`, each on a fresh mark. Ids are never reused, so this is as
--- good for redrawing what is already there as for a store just read.
---@param notes { file:string, lnum:integer, text:string }[]
local function _draw(notes)
    local group = assert(_group)
    for _, note in ipairs(notes) do
        _last_id = _last_id + 1
        group.set_file_extmark(_last_id, note.file, note.lnum, 0, _extmark_opts(note.text), { text = note.text })
    end
end

--- Read the store and draw what is in it, once per session. Every entry point
--- goes through here.
function M.load()
    if _loaded then return end
    _loaded = true

    _define_hl()
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("annotate.hl", { clear = true }),
        callback = _define_hl,
    })

    -- The prefix every namespace and augroup is named after; claimed once,
    -- before any group is defined.
    fileextmarks.init("annotate")
    _group = fileextmarks.define_group("notes")

    _draw(store.load())

    local augroup = vim.api.nvim_create_augroup("annotate.save", { clear = true })
    -- Writing a file makes the lines the notes drifted to the lines on disk,
    -- so the store is out of date even if no note was touched.
    vim.api.nvim_create_autocmd({ "BufWritePost", "VimLeavePre" }, {
        group = augroup,
        callback = function() M.save() end,
    })

    -- A `storage_file` under the current directory names another store once
    -- that directory changes.
    vim.api.nvim_create_autocmd("DirChanged", {
        group = augroup,
        pattern = "global",
        callback = function() M.reload() end,
    })
end

--- Draw the notes in the buffer being read when the plugin loaded. Loading is
--- all it takes: `define_group` sweeps the buffers already loaded.
---@param _bufnr integer
function M.attach(_bufnr)
    M.load()
end

--- Redraw every note with the current configuration, for a `setup()` that runs
--- after the notes were drawn.
function M.refresh()
    if not _loaded then return end
    local group = assert(_group)
    _define_hl()

    -- Rebuilt, not `group.refresh()`ed: the drawing options are on the marks,
    -- so a redraw would use the configuration they were made with.
    local notes = M.list()
    group.remove_extmarks()
    _draw(notes)
end

--- Read the store again, where the current directory now names another one.
--- The notes are saved to the store they came from, and none are carried across.
function M.reload()
    if not _loaded then return end
    if store.resolve() == store.path() then return end

    M.save()
    assert(_group).remove_extmarks()
    _draw(store.load())
end

--- Every note, ordered by file and then by line.
---@param live boolean  read open buffers, rather than the stored line
---@return annotate.Note[]
local function _collect(live)
    local notes = {}
    for _, info in ipairs(assert(_group).get_extmarks(live)) do
        notes[#notes + 1] = { file = info.file, lnum = info.lnum, text = info.user_data.text }
    end
    table.sort(notes, function(a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.lnum < b.lnum
    end)
    return notes
end

-------- PUBLIC API --------

--- Write the notes out, at their stored lines: a modified buffer's marks
--- describe an edit that may never be written. `replace` writes the whole store.
---@param replace boolean?
function M.save(replace)
    if not _loaded then return end
    store.save(_collect(false), replace)
end

--- Set the note on a line, replacing any note already there.
---@param file string
---@param lnum integer  1-based
---@param text string
function M.set(file, lnum, text)
    M.load()
    if text == "" then return end
    file = _norm(file)

    assert(_group)
    local existing = _group.get_extmark_by_location(file, lnum, true)
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
    assert(_group)
    local info = _group.get_extmark_by_location(_norm(file), lnum, true)
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

--- Remove every note in the store, this session's and any other's.
function M.clear_all()
    M.load()
    assert(_group).remove_extmarks()
    M.save(true)
end

--- Every note, ordered by file and then by line.
---@return annotate.Note[]
function M.list()
    M.load()
    -- `live`: an open buffer's extmarks have been tracking the edits, so they
    -- are where the note is now, which is what a jump or a listing wants.
    return _collect(true)
end

-------- COMMANDS --------

--- Set or edit the note on the current line. An existing note is the prompt's
--- initial text, and clearing the prompt removes it.
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

--- Remove every note in the store, after confirmation.
function M.clear_all_confirm()
    ui.confirm("Clear all notes", function(confirmed)
        if confirmed then M.clear_all() end
    end)
end

--- Pick a note and jump to it, through `vim.ui.select`.
function M.select()
    local notes = M.list()
    if #notes == 0 then
        _notify("no notes set")
        return
    end

    vim.ui.select(notes, {
        prompt = "Notes",
        format_item = function(note)
            return ("%s:%d  %s"):format(
                vim.fn.fnamemodify(note.file, ":~:."),
                note.lnum,
                note.text:gsub("%s+", " "))
        end,
    }, function(note)
        if note then ui.open(note.file, note.lnum) end
    end)
end

--- Put the notes in the quickfix list and open it.
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
