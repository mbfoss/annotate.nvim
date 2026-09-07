local M = {}

---@class annotate.util.fileextmarks.MarkInfo
---@field id number
---@field file string
---@field lnum number        -- 1-based
---@field col number        -- 0-based
---@field opts vim.api.keyset.set_extmark
---@field user_data any
---@field source "live"|"stored"

---@class annotate.util.fileextmarks.MarkData
---@field id number
---@field ns number
---@field lnum number        -- 1-based
---@field col number        -- 0-based
---@field opts vim.api.keyset.set_extmark
---@field user_data any

---@alias annotate.util.fileextmarks.ById table<number, annotate.util.fileextmarks.MarkData>
---@alias annotate.util.fileextmarks.ByFile table<string, annotate.util.fileextmarks.ById>

---@class annotate.util.fileextmarks.GroupData
---@field ns number
---@field byfile annotate.util.fileextmarks.ByFile
---@field id_to_file table<number, string>

---@type table<string, annotate.util.fileextmarks.GroupData>
local _defined_groups = {}
local _autocmds_registered = false

-- Namespaces and autocmd groups live in a process-wide registry keyed by name,
-- while the state above is per instance; the plugin claims a prefix via M.init().
---@type string?
local _prefix = nil

---@return string
local function _require_prefix()
    return assert(_prefix, "init(prefix) must be called first")
end

---@param name string
---@return string
local function _prefixed(name)
    return ("%s.%s"):format(_require_prefix(), name)
end

--- Lands every spelling of a file -- relative, or symlinked -- on one key, buffer
--- names included. `resolve()`, since a mark may name a file that is not there.
---@param file string
---@return string
local function _normalize_file(file)
    return vim.fn.resolve(vim.fn.fnamemodify(file, ":p"))
end

--- Normalized buffer names, keyed by bufnr and validated against the raw name.
--- A miss normalizes every loaded buffer, and most tracked files are not open.
---@type table<integer, { name: string, normalized: string }>
local _bufname_cache = {}

--- `_normalize_file` for a buffer's name, memoized. Re-validating against the raw
--- name heals a rename and a reused buffer number on its own.
---@param bufnr integer
---@param name string        -- the buffer's raw name, non-empty
---@return string
local function _normalized_buf_name(bufnr, name)
    local entry = _bufname_cache[bufnr]
    if entry and entry.name == name then return entry.normalized end

    local normalized = _normalize_file(name)
    _bufname_cache[bufnr] = { name = name, normalized = normalized }
    return normalized
end

---@class annotate.util.fileextmarks.BufCacheEntry
---@field bufnr integer
---@field name string        -- the buffer's name when it was resolved

--- Cache for `_get_loaded_bufnr`, keyed by normalized path.
---@type table<string, annotate.util.fileextmarks.BufCacheEntry>
local _bufnr_cache = {}

--- Walks the buffer list comparing normalized names, so another spelling lands too.
--- Not `vim.fn.bufnr()`: it falls back to a partial match.
---@param file string        -- must already be normalized
---@return integer
local function _lookup_loaded_bufnr(file)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" and _normalized_buf_name(bufnr, name) == file then return bufnr end
        end
    end

    return -1
end

--- The scan above is a `resolve()` per loaded buffer, so it is cached. Re-validating
--- against the name it was cached under heals wipes, unloads and renames.
---@param file string        -- must already be normalized
---@return integer
local function _get_loaded_bufnr(file)
    local entry = _bufnr_cache[file]
    if entry then
        if vim.api.nvim_buf_is_valid(entry.bufnr)
            and vim.api.nvim_buf_is_loaded(entry.bufnr)
            and vim.api.nvim_buf_get_name(entry.bufnr) == entry.name
        then
            return entry.bufnr
        end
        _bufnr_cache[file] = nil
    end

    local bufnr = _lookup_loaded_bufnr(file)
    if bufnr == -1 then return -1 end

    _bufnr_cache[file] = { bufnr = bufnr, name = vim.api.nvim_buf_get_name(bufnr) }
    return bufnr
end

--- Buffers holding marks, mapped to the normalized file they hold them for:
--- `_on_lines` needs it on every change and cannot re-derive it from the name.
---@type table<integer, string>
local _attached = {}

--- Buffers with a live `on_lines` subscription. Kept out of `_attached`, where a
--- dropped entry only schedules a detach and would stack a second subscription.
---@type table<integer, true>
local _subscribed = {}

--- Forgets the cached buffer lookup for `file`, unless some group still tracks it.
--- The cache is shared across groups, so the last one out turns the light off.
---@param file string
local function _forget_bufnr(file)
    for _, group_data in pairs(_defined_groups) do
        if group_data.byfile[file] then return end
    end

    _bufnr_cache[file] = nil

    -- Schedule the `on_lines` release too, or the buffer pays a query per group on
    -- every edit. `_attached` is scanned since `_bufnr_cache` may lack this file.
    for bufnr, attached_file in pairs(_attached) do
        if attached_file == file then _attached[bufnr] = nil end
    end
end

--- Call after removing a mark: drops `file` from the group if that was its last,
--- then releases the cache, so an emptied file does not linger as a bare table.
---@param group_data annotate.util.fileextmarks.GroupData
---@param file string
local function _release_file(group_data, file)
    local file_table = group_data.byfile[file]
    if file_table and next(file_table) == nil then
        group_data.byfile[file] = nil
    end

    _forget_bufnr(file)
end

--- Writes `mark` into the buffer at the given position, clamped to a real line
--- and a real column. Does not touch the cached position in `mark`.
---@param bufnr integer
---@param mark annotate.util.fileextmarks.MarkData
---@param lnum integer        -- 1-based
---@param col integer        -- 0-based
---@param ends { end_row: integer?, end_col: integer? }?      -- live end, if known
---@return integer lnum, integer col      -- the clamped position actually used
local function _place_extmark(bufnr, mark, lnum, col, ends)
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    lnum = math.max(1, math.min(lnum, line_count))
    local row = lnum - 1

    -- Only a non-zero column needs the line, and marks overwhelmingly sit at 0.
    -- Kept around for the range end below, which usually wants the same line.
    local row_line
    if col > 0 then
        row_line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1] or ""
        col = math.min(col, #row_line)
    else
        col = 0
    end

    -- Clamp the range end inside the buffer: `end_col` is measured against its line,
    -- so a deleted range would throw. `mark.opts` is left alone, so undo restores it.
    local opts = mark.opts
    local end_row, end_col = opts.end_row, opts.end_col

    -- `ends` wins when given: the stored end only moves on a save. Both fields nil
    -- means a point mark, which must clear a range the stored opts still carry.
    if ends then end_row, end_col = ends.end_row, ends.end_col end

    if end_row or end_col then
        local clamped_row = math.min(end_row or row, line_count - 1)

        -- The end may not precede the start: Neovim stores an inverted range in
        -- silence and the mark just stops rendering.
        clamped_row = math.max(clamped_row, row)

        local clamped_col = end_col

        if end_col then
            local line = clamped_row == row and row_line
            if not line then
                line = vim.api.nvim_buf_get_lines(bufnr, clamped_row, clamped_row + 1, true)[1] or ""
            end
            clamped_col = math.min(end_col, #line)
            if clamped_row == row then clamped_col = math.max(clamped_col, col) end
        end

        if ends then
            -- Assigned rather than merged: `tbl_extend` cannot carry a nil through,
            -- so a merge would leave a stale field standing.
            opts = vim.tbl_extend("force", opts, {})
            opts.end_row, opts.end_col = clamped_row, clamped_col
        elseif (end_row and clamped_row ~= end_row) or clamped_col ~= end_col then
            opts = vim.tbl_extend("force", opts, { end_row = clamped_row, end_col = clamped_col })
        end
    elseif ends and (opts.end_row or opts.end_col) then
        opts = vim.tbl_extend("force", opts, {})
        opts.end_row, opts.end_col = nil, nil
    end

    assert(type(mark.id) == "number")
    local id = vim.api.nvim_buf_set_extmark(bufnr, mark.ns, row, col, opts)
    assert(id == mark.id)

    return lnum, col
end

---@param bufnr integer
---@param mark annotate.util.fileextmarks.MarkData
---@param store boolean      -- record where the mark landed, clamp included
local function _set_extmark(bufnr, mark, store)
    -- No empty-buffer guard: a loaded buffer always holds at least one line.
    if not vim.api.nvim_buf_is_loaded(bufnr) then return end

    local lnum, col = _place_extmark(bufnr, mark, mark.lnum, mark.col)
    if store then mark.lnum, mark.col = lnum, col end
end

---@class annotate.util.fileextmarks.LivePos
---@field id number
---@field lnum number        -- 1-based
---@field col number        -- 0-based
---@field end_row number?        -- 0-based; nil for a point mark
---@field end_col number?        -- 0-based; nil for a point mark

--- Reports where this group's marks currently sit in `bufnr`. Pure: `_on_lines`
--- keeps every row real, and the clamp is defence for a buffer we failed to attach.
---@param bufnr integer
---@param file_table annotate.util.fileextmarks.ById
---@param ns integer
---@return annotate.util.fileextmarks.LivePos[]      -- in buffer order
local function _read_live_marks(bufnr, file_table, ns)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local result = {}

    -- `details` is what carries the range end, and only a synced end can be paired
    -- with a synced start -- see `_sync_file_extmarks`. A point mark reports neither.
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        local id, row, col, details = m[1], m[2], m[3], m[4]
        assert(details)
        if file_table[id] then
            result[#result + 1] = {
                id = id,
                lnum = math.min(row + 1, line_count),
                col = col,
                end_row = details.end_row,
                end_col = details.end_col,
            }
        end
    end

    return result
end

--- Re-anchors marks stranded past the end of `bufnr` onto its last line, where they
--- would otherwise never render. Bounded to that tail, so usually free.
---@param bufnr integer
---@param file string        -- normalized; from `_attached`, so an edit re-normalizes nothing
---@param line_count integer      -- the buffer's line count after the change
local function _repair_stranded_marks(bufnr, file, line_count)
    for _, group_data in pairs(_defined_groups) do
        -- Matched through `byfile`, not by id: a buffer can hold an extmark for a
        -- file it no longer holds, and by id that orphan would re-anchor every edit.
        local file_table = group_data.byfile[file]
        if file_table then
            local stranded = vim.api.nvim_buf_get_extmarks(
                bufnr,
                group_data.ns,
                { line_count, 0 },
                { -1, -1 },
                { details = true }
            )
            for _, m in ipairs(stranded) do
                local mark = file_table[m[1]]
                if mark then
                    -- Clamps onto the last line, live end included, since the stored
                    -- end would collapse the range. The cached position is left alone.
                    _place_extmark(bufnr, mark, m[2] + 1, m[3], m[4])
                end
            end
        end
    end
end

--- Fires for every change to an attached buffer, API ones included -- which a
--- TextChanged autocmd misses, stranding marks whenever a plugin edits the buffer.
local function _on_lines(_, bufnr, _, _, _, last_new)
    -- No entry means the last mark for this buffer's file is gone. Returning true is
    -- the detach path: the next change tears the subscription down.
    local file = _attached[bufnr]
    if not file then
        _subscribed[bufnr] = nil
        return true -- detach
    end

    -- Guarded for a second reason: an error here has Neovim drop the subscription
    -- without `on_detach`, and the stale entry would bar a later `_attach_buffer`.
    local ok, line_count = pcall(vim.api.nvim_buf_line_count, bufnr)
    if not ok then
        -- State unknown, so hold nothing: detaching costs one re-attach, and the
        -- next `_apply_buffer_extmarks` or `set_file_extmark` does it.
        _attached[bufnr] = nil
        _subscribed[bufnr] = nil
        return true -- detach
    end

    -- Only a change reaching the end can strand a mark, growth included: a right-
    -- gravity mark lands on `last_new`. Decided from the range alone, so O(1).
    if last_new < line_count then return end -- change stopped short of the end

    -- Swallowed on purpose: an error raised here propagates out of the change that
    -- triggered it, and the buffer then rejects every later edit.
    pcall(_repair_stranded_marks, bufnr, file, line_count)
end

---@param bufnr integer
---@param file string        -- normalized; the file `bufnr` holds marks for
local function _attach_buffer(bufnr, file)
    _attached[bufnr] = file -- may be a re-attach under a new name

    -- A subscription scheduled for release but not yet torn down is reused: the
    -- entry above revives it, and attaching again would leave two running.
    if _subscribed[bufnr] then return end

    _subscribed[bufnr] = true
    local ok = vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = _on_lines,
        on_detach = function(_, b)
            _attached[b] = nil
            _subscribed[b] = nil
        end,
    })
    if not ok then
        _attached[bufnr] = nil
        _subscribed[bufnr] = nil
    end
end

---@param bufnr integer
---@param ns integer
local function _clear_buf_namespace(bufnr, ns)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

--- Whether `bufnr`'s text can be read as the file's own, which gates every write
--- back into the cache: an unsaved edit, or a buffer with no file, is not it.
---@param bufnr integer
---@return boolean
local function _buf_matches_file(bufnr)
    if vim.bo[bufnr].modified then return false end

    -- The second call is reached only by a one-line buffer, so the common case is
    -- a single C call and no allocation.
    if vim.api.nvim_buf_line_count(bufnr) > 1 then return true end
    return vim.api.nvim_buf_get_lines(bufnr, 0, 1, true)[1] ~= ""
end

--- Replaces the namespace with this group's stored marks for `bufnr`'s file. The
--- clear collects marks orphaned by an unload or a rename, so it runs first.
---@param bufnr integer
---@param group string
local function _apply_buffer_extmarks(bufnr, group)
    local group_data = _defined_groups[group]
    assert(group_data)

    _clear_buf_namespace(bufnr, group_data.ns)

    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then return end
    file = _normalized_buf_name(bufnr, file)

    local file_data = group_data.byfile[file]
    if not file_data then return end

    -- The clamp is evidence about the file only when the buffer holds what the file
    -- does: a `BufNewFile` buffer is empty for want of a file, not of lines.
    local store = _buf_matches_file(bufnr)

    for _, mark in pairs(file_data) do
        _set_extmark(bufnr, mark, store)
    end

    _attach_buffer(bufnr, file)
end

---@param bufnr number
local function _sync_file_extmarks(bufnr)
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then return end
    file = _normalized_buf_name(bufnr, file)

    -- Both callers reach here with the buffer about to be written or dropped, and
    -- neither is a reason to record positions the file does not have.
    if not _buf_matches_file(bufnr) then return end

    for _, group_data in pairs(_defined_groups) do
        local file_table = group_data.byfile[file]
        if file_table then
            for _, live in ipairs(_read_live_marks(bufnr, file_table, group_data.ns)) do
                local mark = file_table[live.id]
                mark.lnum, mark.col = live.lnum, live.col

                -- The end drifts like the start but lives in `opts`, so syncing only
                -- the start would re-place it against a creation-time end.
                mark.opts.end_row = live.end_row
                mark.opts.end_col = live.end_col
            end
        end
    end
end

local function _register_autocmds()
    if _autocmds_registered then return end
    _autocmds_registered = true

    local name = _prefixed("fileextmarks")

    assert(not pcall(vim.api.nvim_get_autocmds, { group = name }),
        ("augroup %q already exists -- another copy of this module owns prefix %q"):format(name, _require_prefix()))

    local augroup = vim.api.nvim_create_augroup(name, { clear = true })
    -- `BufNewFile` alongside `BufReadPost`: a path with no file behind it fires only
    -- the former, and marks on a file that is not there yet are supported.
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
        group = augroup,
        callback = function(ev)
            for group in pairs(_defined_groups) do
                _apply_buffer_extmarks(ev.buf, group)
            end
        end,
    })
    -- A rename leaves the buffer holding the old name's marks, rendered but
    -- unreachable. Re-applying puts back whatever the new name owns.
    vim.api.nvim_create_autocmd("BufFilePost", {
        group = augroup,
        callback = function(ev)
            -- Dropped rather than repointed: `_apply_buffer_extmarks` re-attaches
            -- under the new file, and a stale entry has `_on_lines` repairing it wrong.
            _attached[ev.buf] = nil
            for group in pairs(_defined_groups) do
                _apply_buffer_extmarks(ev.buf, group)
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        callback = function(ev) _sync_file_extmarks(ev.buf) end,
    })
    -- `BufUnload` as well as `BufWipeout`: `:bdelete` unloads without wiping, so
    -- waiting for the wipe leaks an entry per buffer for the life of the session.
    vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
        group = augroup,
        callback = function(ev) _bufname_cache[ev.buf] = nil end,
    })
end

---@param id number
---@param file string
---@param lnum number        -- 1-based
---@param col number        -- 0-based
---@param group_data annotate.util.fileextmarks.GroupData
---@param opts vim.api.keyset.set_extmark       -- extmark opts (include `priority` here)
---@param user_data any
---@see vim.api.nvim_buf_set_extmark
local function _set_file_extmark(id, file, lnum, col, group_data, opts, user_data)
    assert(lnum >= 1, "lnum must be 1-based")

    file = _normalize_file(file)
    local bufnr = _get_loaded_bufnr(file)

    local old_file = group_data.id_to_file[id]
    if old_file and old_file ~= file then
        local old_bufnr = _get_loaded_bufnr(old_file)
        if old_bufnr >= 0 then
            vim.api.nvim_buf_del_extmark(old_bufnr, group_data.ns, id)
        end

        -- Vacate the old file, or the mark stays visible there: `_get_extmarks` and
        -- `refresh()` both read from `byfile` rather than from the buffer.
        local old_table = group_data.byfile[old_file]
        if old_table then
            old_table[id] = nil
            _release_file(group_data, old_file)
        end
    end

    group_data.id_to_file[id] = file
    group_data.byfile[file] = group_data.byfile[file] or {}

    ---@type annotate.util.fileextmarks.MarkData
    local mark = {
        id = id,
        ns = group_data.ns,
        lnum = lnum,
        col = col,
        -- `id` last: with "force" the right-hand table wins, and the id this
        -- mark is keyed by everywhere is not the caller's to override.
        opts = vim.tbl_extend("force", opts or {}, { id = id }),
        user_data = user_data,
    }

    group_data.byfile[file][id] = mark

    if bufnr >= 0 then
        -- Gated like every other write into the cached position: a buffer with unsaved
        -- deletes is shorter than its file, and storing that would pin the mark.
        _set_extmark(bufnr, mark, _buf_matches_file(bufnr))
        _attach_buffer(bufnr, file)
    end
end

---@param id number
---@param group_data annotate.util.fileextmarks.GroupData
local function _remove_extmark(id, group_data)
    local file = group_data.id_to_file[id]
    if not file then return end

    group_data.id_to_file[id] = nil

    local file_table = group_data.byfile[file]
    if not file_table then return end

    local bufnr = _get_loaded_bufnr(file)
    if bufnr >= 0 then
        vim.api.nvim_buf_del_extmark(bufnr, group_data.ns, id)
    end

    file_table[id] = nil
    _release_file(group_data, file)
end

---@param file string
---@param group_data annotate.util.fileextmarks.GroupData
local function _remove_file_extmarks(file, group_data)
    file = _normalize_file(file)

    local file_table = group_data.byfile[file]
    if not file_table then return end

    for id in pairs(file_table) do
        group_data.id_to_file[id] = nil
    end

    group_data.byfile[file] = nil

    local bufnr = _get_loaded_bufnr(file)
    if bufnr >= 0 then
        _clear_buf_namespace(bufnr, group_data.ns)
    end

    _forget_bufnr(file)
end

---@param group_data annotate.util.fileextmarks.GroupData
local function _remove_extmarks(group_data)
    local files = {}
    for file in pairs(group_data.byfile) do
        files[#files + 1] = file
        local bufnr = _get_loaded_bufnr(file)
        if bufnr >= 0 then
            _clear_buf_namespace(bufnr, group_data.ns)
        end
    end

    group_data.byfile = {}
    group_data.id_to_file = {}

    for _, file in ipairs(files) do
        _forget_bufnr(file)
    end
end

---@param id number
---@param group_data annotate.util.fileextmarks.GroupData
---@return annotate.util.fileextmarks.MarkInfo?
local function _get_extmark_by_id(id, group_data)
    local file = group_data.id_to_file[id]
    if not file then return nil end

    local mark = (group_data.byfile[file] or {})[id]
    if not mark then return nil end

    return {
        id = mark.id,
        file = file,
        lnum = mark.lnum,
        col = mark.col,
        opts = mark.opts,
        user_data = mark.user_data,
        source = "stored",
    }
end

---@param file string
---@param line number
---@param group_data annotate.util.fileextmarks.GroupData
---@param live boolean
---@return annotate.util.fileextmarks.MarkInfo?
local function _get_extmark_by_location(file, line, group_data, live)
    assert(type(live) == "boolean")
    assert(line >= 1, "line must be 1-based")

    file = _normalize_file(file)

    local file_table = group_data.byfile[file]
    if not file_table then return nil end

    local bufnr = live and _get_loaded_bufnr(file) or -1
    if bufnr >= 0 then
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        if line > line_count then return nil end

        -- Bounded to the line asked for rather than walking the namespace. The last
        -- line reaches past the end too, where a stranded mark reads as sitting on it.
        local last = line == line_count and { -1, -1 } or { line - 1, -1 }
        local found = vim.api.nvim_buf_get_extmarks(
            bufnr,
            group_data.ns,
            { line - 1, 0 },
            last,
            { details = false }
        )

        for _, m in ipairs(found) do
            local mark = file_table[m[1]]
            if mark then
                return {
                    id = m[1],
                    file = file,
                    lnum = line, -- every hit in this range reads as `line`
                    col = m[3],
                    opts = mark.opts,
                    user_data = mark.user_data,
                    source = "live",
                }
            end
        end

        return nil
    end

    for id, mark in pairs(file_table) do
        if mark.lnum == line then
            return {
                id = id,
                file = file,
                lnum = mark.lnum,
                col = mark.col,
                opts = mark.opts,
                user_data = mark.user_data,
                source = "stored",
            }
        end
    end

    return nil
end

---@param group_data annotate.util.fileextmarks.GroupData
---@param live boolean
---@return annotate.util.fileextmarks.MarkInfo[]
local function _get_extmarks(group_data, live)
    assert(type(live) == "boolean")

    local result = {}

    for file, file_table in pairs(group_data.byfile) do
        local bufnr = live and _get_loaded_bufnr(file) or -1
        if bufnr >= 0 then
            for _, m in ipairs(_read_live_marks(bufnr, file_table, group_data.ns)) do
                local mark = file_table[m.id]
                result[#result + 1] = {
                    id = m.id,
                    file = file,
                    lnum = m.lnum,
                    col = m.col,
                    opts = mark.opts,
                    user_data = mark.user_data,
                    source = "live",
                }
            end
        else
            for id, mark in pairs(file_table) do
                result[#result + 1] = {
                    id = id,
                    file = file,
                    lnum = mark.lnum,
                    col = mark.col,
                    opts = mark.opts,
                    user_data = mark.user_data,
                    source = "stored",
                }
            end
        end
    end

    return result
end

---@param file string
---@param group_data annotate.util.fileextmarks.GroupData
---@param live boolean
---@return annotate.util.fileextmarks.MarkInfo[]
local function _get_file_extmarks(file, group_data, live)
    assert(type(live) == "boolean")

    file = _normalize_file(file)
    local result = {}

    local file_table = group_data.byfile[file]
    if not file_table then return result end

    local bufnr = live and _get_loaded_bufnr(file) or -1
    if bufnr >= 0 then
        for _, m in ipairs(_read_live_marks(bufnr, file_table, group_data.ns)) do
            local mark = file_table[m.id]
            result[#result + 1] = {
                id = mark.id,
                file = file,
                lnum = m.lnum,
                col = m.col,
                opts = mark.opts,
                user_data = mark.user_data,
                source = "live",
            }
        end
    else
        for _, mark in pairs(file_table) do
            result[#result + 1] = {
                id = mark.id,
                file = file,
                lnum = mark.lnum,
                col = mark.col,
                opts = mark.opts,
                user_data = mark.user_data,
                source = "stored",
            }
        end
    end

    return result
end

---@param group_data annotate.util.fileextmarks.GroupData
---@param group string
local function _refresh_group(group_data, group)
    for file in pairs(group_data.byfile) do
        local bufnr = _get_loaded_bufnr(file)
        if bufnr >= 0 then
            _apply_buffer_extmarks(bufnr, group) -- clears the namespace itself
        end
    end
end

---@class annotate.util.fileextmarks.GroupFunctions
---@field set_file_extmark fun(id:number, file:string, lnum:number, col:number, opts:vim.api.keyset.set_extmark, user_data:any)
---@field remove_extmarks fun()
---@field remove_extmark fun(id:number)
---@field remove_file_extmarks fun(file:string)
---@field get_extmark_by_id fun(id:number): annotate.util.fileextmarks.MarkInfo?
---@field get_extmark_by_location fun(file:string, line:number, live:boolean): annotate.util.fileextmarks.MarkInfo?
---@field get_extmarks fun(live:boolean): annotate.util.fileextmarks.MarkInfo[]
---@field get_file_extmarks fun(file:string, live:boolean): annotate.util.fileextmarks.MarkInfo[]
---@field refresh fun()

--- Claims the prefix used for every namespace and augroup this module creates.
--- Must be called (once) before M.define_group().
---@param prefix string  unique to the calling plugin, e.g. "myplugin"
function M.init(prefix)
    assert(type(prefix) == "string" and prefix ~= "", "prefix (non-empty string) required")
    assert(not _prefix or _prefix == prefix, ("already initialized with prefix %q"):format(_prefix))

    _prefix = prefix
end

---@param group string  name, unique within this module instance; used to derive the extmark namespace
---@return annotate.util.fileextmarks.GroupFunctions
function M.define_group(group)
    _require_prefix()
    assert(type(group) == "string", "group (string) required")
    assert(not _defined_groups[group], "group already defined")

    local ns_name = _prefixed(group)
    assert(not vim.api.nvim_get_namespaces()[ns_name],
        ("namespace %q already exists -- another copy of this module owns prefix %q"):format(ns_name, _require_prefix()))

    ---@type annotate.util.fileextmarks.GroupData
    local group_data = {
        ns = vim.api.nvim_create_namespace(ns_name),
        byfile = {},
        id_to_file = {},
    }
    _defined_groups[group] = group_data

    _register_autocmds()

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            _apply_buffer_extmarks(bufnr, group)
        end
    end

    ---@type annotate.util.fileextmarks.GroupFunctions
    return {
        set_file_extmark = function(id, file, lnum, col, opts, user_data)
            _set_file_extmark(id, file, lnum, col, group_data, opts, user_data)
        end,
        remove_extmark = function(id)
            _remove_extmark(id, group_data)
        end,
        remove_file_extmarks = function(file)
            _remove_file_extmarks(file, group_data)
        end,
        remove_extmarks = function()
            _remove_extmarks(group_data)
        end,
        get_extmark_by_id = function(id)
            return _get_extmark_by_id(id, group_data)
        end,
        get_extmark_by_location = function(file, line, live)
            return _get_extmark_by_location(file, line, group_data, live)
        end,
        get_extmarks = function(live)
            return _get_extmarks(group_data, live)
        end,
        get_file_extmarks = function(file, live)
            return _get_file_extmarks(file, group_data, live)
        end,
        refresh = function()
            _refresh_group(group_data, group)
        end,
    }
end

return M
