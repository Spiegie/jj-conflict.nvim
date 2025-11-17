-- lua/jj-conflict.lua
-- Minimal Neovim plugin to highlight Jujutsu-style conflicts in the current buffer only.

local api = vim.api
local M = {}

local bit = require('bit')

local NAMESPACE = api.nvim_create_namespace('jj-conflict')
local PRIORITY = vim.highlight.priorities.user

local sep = package.config:sub(1,1)

-- Default regex markers (covers common Jujutsu variants and Git-like markers)
local MARKERS = {
  header = '^%%%%%%',         -- jj conflict header (e.g. "%%%%%% conflict ...")
  start = '^<<<<<<<',         -- start of a side
  ancestor = '^|||||||',      -- ancestor/base marker
  middle = '^=======',        -- divider between sides
  finish = '^>>>>>>>',        -- end of conflict
}

-- Highlight group names used internally
local CURRENT_HL = 'JjConflictCurrent'
local INCOMING_HL = 'JjConflictIncoming'
local ANCESTOR_HL = 'JjConflictAncestor'
local CURRENT_LABEL_HL = 'JjConflictCurrentLabel'
local INCOMING_LABEL_HL = 'JjConflictIncomingLabel'
local ANCESTOR_LABEL_HL = 'JjConflictAncestorLabel'

local DEFAULT_HLS = {
  current = 'DiffText',
  incoming = 'DiffAdd',
  ancestor = 'DiffChange',
}

local DEFAULT_CURRENT_BG_COLOR = 4218238  -- #405d7e
local DEFAULT_INCOMING_BG_COLOR = 3229523 -- #314753
local DEFAULT_ANCESTOR_BG_COLOR = 6824314 -- #68217A

-- Small util to read the full buffer lines
local function get_buf_lines(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  return api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

-- Detect conflicts in the buffer lines. Returns list of positions.
-- Each position has: current = {range_start, range_end, content_start, content_end}
-- incoming = {..} and optional ancestor = {..}
local function detect_conflicts(lines)
  local positions = {}
  local i = 1
  local n = #lines

  while i <= n do
    local line = lines[i]
    -- detect start either by header or by <<<<<<< marker
    local is_header = line and line:match(MARKERS.header)
    local is_start = line and line:match(MARKERS.start)

    if is_header or is_start then
      -- We found a conflict block. We'll scan forward to find middle and finish.
      local block_start = i - 1 -- zero-based
      local current_start, current_end, ancestor_start, ancestor_end, middle_line, incoming_start, incoming_end
      local j = i + 1
      local seen_ancestor = false
      local seen_middle = false

      -- If there was a header line (%%%%%), the actual side markers might follow. We'll treat
      -- header as part of the conflict block and continue scanning for <<<<<<< or ======= etc.
      while j <= n do
        local lj = lines[j]
        if not seen_middle and lj:match(MARKERS.ancestor) then
          -- ancestor/base section begins here. Set current end just before ancestor.
          seen_ancestor = true
          -- current content ends at line before ancestor
          current_end = j - 2 -- content end (0-based)
          ancestor_start = j - 1
        elseif not seen_middle and lj:match(MARKERS.middle) then
          seen_middle = true
          middle_line = j - 1
          if not seen_ancestor then
            -- current ends before middle
            current_end = j - 2
          else
            -- ancestor ends before middle
            ancestor_end = j - 2
          end
          incoming_start = j
        elseif lj:match(MARKERS.finish) then
          -- end of block
          incoming_end = j - 2
          -- fill defaults if some values nil
          if not current_start then current_start = block_start end
          if not current_end then current_end = (seen_ancestor and (ancestor_start - 1) or (middle_line and middle_line - 1 or incoming_end)) end
          if seen_ancestor and not ancestor_end then ancestor_end = (middle_line and middle_line - 1 or incoming_end) end
          if not incoming_start then incoming_start = middle_line and (middle_line + 1) or (current_end + 2) end

          table.insert(positions, {
            current = {
              range_start = current_start,
              range_end = current_end,
              content_start = current_start + 1,
              content_end = current_end,
            },
            incoming = {
              range_start = incoming_start,
              range_end = incoming_end,
              content_start = incoming_start + 1,
              content_end = incoming_end,
            },
            ancestor = (seen_ancestor and {
              range_start = ancestor_start,
              range_end = ancestor_end,
              content_start = ancestor_start + 1,
              content_end = ancestor_end,
            } or {}),
            markers = { start = block_start, middle = middle_line or -1, finish = j - 1 },
          })

          i = j + 1
          break
        end
        j = j + 1
      end
    else
      i = i + 1
    end
  end

  return positions
end

-- Helper to set extmark for a range with highlight.
local function hl_range(bufnr, hl, range_start, range_end)
  if not range_start or not range_end then return end
  return api.nvim_buf_set_extmark(bufnr, NAMESPACE, range_start, 0, {
    hl_group = hl,
    hl_eol = true,
    hl_mode = 'combine',
    end_row = range_end,
    priority = PRIORITY,
  })
end

-- Draw a label overlay on the given line
local function draw_section_label(bufnr, hl_group, label, lnum)
  if not lnum then return end
  -- compute remaining space; if we can't get window width, just use a reasonable pad
  local ok, width = pcall(api.nvim_win_get_width, 0)
  local remaining_space = (ok and (width - vim.fn.strdisplaywidth(label))) or 20
  if remaining_space < 1 then remaining_space = 1 end
  local virt = label .. string.rep(' ', remaining_space)
  return api.nvim_buf_set_extmark(bufnr, NAMESPACE, lnum, 0, {
    hl_group = hl_group,
    virt_text = { { virt, hl_group } },
    virt_text_pos = 'overlay',
    priority = PRIORITY,
  })
end

-- Apply highlights for all detected positions in the current buffer
local function highlight_conflicts(bufnr, positions, lines)
  bufnr = bufnr or api.nvim_get_current_buf()
  -- clear previous
  api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)

  for _, pos in ipairs(positions) do
    local current_start = pos.current.range_start
    local current_end = pos.current.range_end
    local incoming_start = pos.incoming.range_start
    local incoming_end = pos.incoming.range_end

    -- Labels will show the marker lines if available, otherwise generic
    local curr_label_text = (lines[current_start + 1] or 'Current') .. ' (Current)'
    local inc_label_text = (lines[incoming_end + 1] or 'Incoming') .. ' (Incoming)'

    -- create extmarks
    local curr_label_id = draw_section_label(bufnr, CURRENT_LABEL_HL, curr_label_text, current_start)
    local curr_id = hl_range(bufnr, CURRENT_HL, current_start, current_end + 1)
    local inc_id = hl_range(bufnr, INCOMING_HL, incoming_start, incoming_end + 1)
    local inc_label_id = draw_section_label(bufnr, INCOMING_LABEL_HL, inc_label_text, incoming_end)

    if not vim.tbl_isempty(pos.ancestor or {}) then
      local ancestor_start = pos.ancestor.range_start
      local ancestor_end = pos.ancestor.range_end
      local ancestor_label = (lines[ancestor_start + 1] or 'Ancestor') .. ' (Base)'
      local id = hl_range(bufnr, ANCESTOR_HL, ancestor_start + 1, ancestor_end + 1)
      local label_id = draw_section_label(bufnr, ANCESTOR_LABEL_HL, ancestor_label, ancestor_start)
    end
  end
end

-- Configure highlight group colors (derives background from user groups where possible)
local function set_highlights(user_hls)
  user_hls = user_hls or DEFAULT_HLS
  local function get_hl(name)
    if not name then return {} end
    local ok, tbl = pcall(vim.api.nvim_get_hl_by_name, name, true)
    return ok and tbl or {}
  end

  local current_color = get_hl(user_hls.current)
  local incoming_color = get_hl(user_hls.incoming)
  local ancestor_color = get_hl(user_hls.ancestor)

  local current_bg = current_color.background or DEFAULT_CURRENT_BG_COLOR
  local incoming_bg = incoming_color.background or DEFAULT_INCOMING_BG_COLOR
  local ancestor_bg = ancestor_color.background or DEFAULT_ANCESTOR_BG_COLOR

  local function shade_color(col, amount)
    amount = amount or 60
    local r = bit.rshift(bit.band(col, 0xFF0000), 16)
    local g = bit.rshift(bit.band(col, 0x00FF00), 8)
    local b = bit.band(col, 0x0000FF)
    local function s(c)
      local v = math.floor(c * (100 - amount) / 100)
      if v < 0 then v = 0 end
      return v
    end
    return (s(r) * 0x10000) + (s(g) * 0x100) + s(b)
  end

  local current_label_bg = shade_color(current_bg, 60)
  local incoming_label_bg = shade_color(incoming_bg, 60)
  local ancestor_label_bg = shade_color(ancestor_bg, 60)

  api.nvim_set_hl(0, CURRENT_HL, { background = current_bg, bold = true, default = true })
  api.nvim_set_hl(0, INCOMING_HL, { background = incoming_bg, bold = true, default = true })
  api.nvim_set_hl(0, ANCESTOR_HL, { background = ancestor_bg, bold = true, default = true })
  api.nvim_set_hl(0, CURRENT_LABEL_HL, { background = current_label_bg, default = true })
  api.nvim_set_hl(0, INCOMING_LABEL_HL, { background = incoming_label_bg, default = true })
  api.nvim_set_hl(0, ANCESTOR_LABEL_HL, { background = ancestor_label_bg, default = true })
end

-- Parse current buffer and highlight
local function parse_and_highlight(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(bufnr) then return end
  local lines = get_buf_lines(bufnr)
  local positions = detect_conflicts(lines)
  if #positions > 0 then
    highlight_conflicts(bufnr, positions, lines)
  else
    api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
  end
end

-- Public setup. Minimal options: highlights table
function M.setup(opts)
  opts = opts or {}
  set_highlights(opts.highlights)

  -- decoration provider: highlight whenever window displays buffer
  api.nvim_set_decoration_provider(NAMESPACE, {
    on_win = function(_, _, bufnr, _, _)
      -- only operate on current buffer (user requested current open buffer only)
      if bufnr == api.nvim_get_current_buf() then
        parse_and_highlight(bufnr)
      end
    end,
    on_buf = function(_, bufnr, _)
      -- show only for valid buffers: keep default behaviour
      return api.nvim_buf_is_loaded(bufnr)
    end,
  })

  -- Also attach to BufRead / TextChanged to update highlights
  api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost', 'TextChanged', 'TextChangedI' }, {
    callback = function(args)
      if args.buf == api.nvim_get_current_buf() then parse_and_highlight(args.buf) end
    end,
  })
end

function M.clear()
  local bufnr = api.nvim_get_current_buf()
  api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
end

return M

