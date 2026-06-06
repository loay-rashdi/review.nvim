local M = {}

local store = require("review.store")
local config = require("review.config")
local normalize_path = require("review.utils").normalize_path

local ns_id = vim.api.nvim_create_namespace("review")
local ns_padding = vim.api.nvim_create_namespace("review_padding")
local mark_ids_by_buf = {}

---@param text string
---@param type_name string
---@param hl string
---@return table[] virt_lines
local function build_comment_box(text, type_name, hl)
  local virt_lines = {}
  local text_lines = vim.split(text, "\n")

  local max_text_width = 0
  for _, text_line in ipairs(text_lines) do
    max_text_width = math.max(max_text_width, vim.fn.strdisplaywidth(text_line))
  end
  local header_text = string.format("[%s]", string.upper(type_name))
  local content_width = math.max(max_text_width, 20)

  local top_dashes = content_width - vim.fn.strdisplaywidth(header_text) + 1
  table.insert(virt_lines, { { "╭─" .. header_text .. string.rep("─", top_dashes) .. "╮", hl } })

  for _, text_line in ipairs(text_lines) do
    local padding = content_width - vim.fn.strdisplaywidth(text_line)
    table.insert(virt_lines, { { "│ " .. text_line .. string.rep(" ", padding) .. " │", hl } })
  end

  table.insert(virt_lines, { { "╰" .. string.rep("─", content_width + 2) .. "╯", hl } })
  return virt_lines
end

local function remember_mark(bufnr, comment_id, mark_id)
  if not mark_id then
    return
  end
  mark_ids_by_buf[bufnr] = mark_ids_by_buf[bufnr] or {}
  mark_ids_by_buf[bufnr][comment_id] = mark_ids_by_buf[bufnr][comment_id] or {}
  table.insert(mark_ids_by_buf[bufnr][comment_id], mark_id)
end

local function clear_comment_marks(bufnr, comment_id)
  local by_comment = mark_ids_by_buf[bufnr]
  local mark_ids = by_comment and by_comment[comment_id]
  if not mark_ids then
    return
  end
  for _, mark_id in ipairs(mark_ids) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, mark_id)
  end
  by_comment[comment_id] = nil
end

local function render_comment(bufnr, comment)
  local cfg = config.get()
  local type_info = cfg.comment_types[comment.type]
  local icon = type_info and type_info.icon or "●"
  local hl = type_info and type_info.hl or "ReviewSign"
  local line_hl = type_info and type_info.line_hl
  local name = type_info and type_info.name or comment.type
  local virt_lines = build_comment_box(comment.text, name, hl)

  if comment.line == 0 then
    local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, 0, 0, {
      sign_text = icon,
      sign_hl_group = hl,
      virt_lines = virt_lines,
      virt_lines_above = true,
    })
    if ok then
      remember_mark(bufnr, comment.id, mark_id)
    end
    -- Scroll windows to reveal virt_lines above row 0
    local virt_line_count = #virt_lines
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
        vim.api.nvim_win_call(win, function()
          local view = vim.fn.winsaveview()
          if view.topline <= 1 then
            view.topfill = virt_line_count
            vim.fn.winrestview(view)
          end
        end)
      end
    end
  else
    local line_start = comment.line - 1
    local line_end_0 = (comment.line_end or comment.line) - 1
    local is_range = line_end_0 ~= line_start

    if line_start >= 0 then
      if is_range then
        local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line_start, 0, {
          sign_text = icon,
          sign_hl_group = hl,
          line_hl_group = line_hl,
        })
        if ok then
          remember_mark(bufnr, comment.id, mark_id)
        end

        for l = line_start + 1, line_end_0 - 1 do
          ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, l, 0, {
            line_hl_group = line_hl,
          })
          if ok then
            remember_mark(bufnr, comment.id, mark_id)
          end
        end

        ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line_end_0, 0, {
          line_hl_group = line_hl,
          virt_lines = virt_lines,
          virt_lines_above = false,
        })
        if ok then
          remember_mark(bufnr, comment.id, mark_id)
        end
      else
        local ok, mark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line_start, 0, {
          sign_text = icon,
          sign_hl_group = hl,
          line_hl_group = line_hl,
          virt_lines = virt_lines,
          virt_lines_above = false,
        })
        if ok then
          remember_mark(bufnr, comment.id, mark_id)
        end
      end
    end
  end
end

---@param bufnr number
---@param side? "old"|"new"
---@param file_override? string file path to use directly instead of parsing buffer name
function M.render_for_buffer(bufnr, side, file_override)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local file
  if file_override then
    file = normalize_path(file_override)
  else
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if not bufname or bufname == "" then
      return
    end

    if bufname:match("^codediff://") then
      local path = bufname:match("^codediff://[^/]+/(.+)%?") or bufname:match("^codediff://[^/]+/(.+)$")
      if path then
        file = normalize_path(path)
      end
    else
      file = normalize_path(vim.fn.fnamemodify(bufname, ":."))
    end
  end

  if not file then
    return
  end

  local comments = store.get_for_file(file, side)

  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  mark_ids_by_buf[bufnr] = {}

  for _, comment in ipairs(comments) do
    render_comment(bufnr, comment)
  end
end

---Calculate the height of a comment's virtual line box
---@param comment table
---@return number height, number attach_line (0-indexed)
local function comment_box_height(comment)
  local text_lines = vim.split(comment.text, "\n")
  local height = #text_lines + 2 -- top border + content + bottom border
  local attach_line
  if comment.line == 0 then
    attach_line = 0
  else
    attach_line = (comment.line_end or comment.line) - 1
  end
  return height, attach_line
end

local function set_padding(bufnr, line, height)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_padding, line, line + 1)
  if height <= 0 then
    return
  end

  local padding = {}
  for _ = 1, height do
    table.insert(padding, { { "", "Normal" } })
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_padding, line, 0, {
    virt_lines = padding,
    virt_lines_above = false,
  })
end

---Add blank padding lines on one buffer to match comment boxes on the other
---@param orig_buf number
---@param mod_buf number
---@param orig_file string|nil
---@param mod_file string|nil
function M.align_buffers(orig_buf, mod_buf, orig_file, mod_file)
  if orig_buf and vim.api.nvim_buf_is_valid(orig_buf) then
    vim.api.nvim_buf_clear_namespace(orig_buf, ns_padding, 0, -1)
  end
  if mod_buf and vim.api.nvim_buf_is_valid(mod_buf) then
    vim.api.nvim_buf_clear_namespace(mod_buf, ns_padding, 0, -1)
  end

  if not orig_buf or not mod_buf
    or not vim.api.nvim_buf_is_valid(orig_buf)
    or not vim.api.nvim_buf_is_valid(mod_buf)
    or (not orig_file and not mod_file) then
    return
  end

  -- Build height maps: attach_line -> total virt_line height per side
  -- Skip file comments (line 0) since they render identically on both sides
  local function build_height_map(file, side)
    if not file then return {} end
    local map = {}
    for _, comment in ipairs(store.get_for_file(file, side)) do
      if comment.line ~= 0 and (comment.side or "new") == side then
        local height, attach_line = comment_box_height(comment)
        map[attach_line] = (map[attach_line] or 0) + height
      end
    end
    return map
  end

  local old_map = build_height_map(orig_file, "old")
  local new_map = build_height_map(mod_file, "new")

  local all_lines = {}
  for line in pairs(old_map) do all_lines[line] = true end
  for line in pairs(new_map) do all_lines[line] = true end

  for line in pairs(all_lines) do
    local old_h = old_map[line] or 0
    local new_h = new_map[line] or 0
    local diff = old_h - new_h

    if diff ~= 0 then
      local target_buf = diff > 0 and mod_buf or orig_buf
      set_padding(target_buf, line, math.abs(diff))
    end
  end
end

---@param orig_buf number
---@param mod_buf number
---@param orig_file string|nil
---@param mod_file string|nil
---@param line number 0-indexed attach line
function M.align_buffers_at_line(orig_buf, mod_buf, orig_file, mod_file, line)
  if not orig_buf or not mod_buf
    or not vim.api.nvim_buf_is_valid(orig_buf)
    or not vim.api.nvim_buf_is_valid(mod_buf)
    or (not orig_file and not mod_file) then
    return
  end

  local function height_at(file, side)
    if not file then return 0 end
    local height = 0
    for _, comment in ipairs(store.get_for_file(file, side)) do
      if comment.line ~= 0 and (comment.side or "new") == side then
        local comment_height, attach_line = comment_box_height(comment)
        if attach_line == line then
          height = height + comment_height
        end
      end
    end
    return height
  end

  set_padding(orig_buf, line, 0)
  set_padding(mod_buf, line, 0)

  local old_h = height_at(orig_file, "old")
  local new_h = height_at(mod_file, "new")
  local diff = old_h - new_h

  if diff ~= 0 then
    local target_buf = diff > 0 and mod_buf or orig_buf
    set_padding(target_buf, line, math.abs(diff))
  end
end

function M.refresh()
  local ok, hooks = pcall(require, "review.hooks")
  if not ok then
    return
  end

  local orig_buf, mod_buf = hooks.get_buffers()
  local orig_path, mod_path = hooks.get_paths()
  if orig_buf then
    M.render_for_buffer(orig_buf, "old", orig_path)
  end
  if mod_buf then
    M.render_for_buffer(mod_buf, "new", mod_path)
  end

  if orig_buf and mod_buf and (orig_path or mod_path) then
    M.align_buffers(orig_buf, mod_buf, orig_path, mod_path)
  end
end

---@param comment Comment
---@param opts? {delete?: boolean}
function M.refresh_comment(comment, opts)
  local ok, hooks = pcall(require, "review.hooks")
  if not ok or not comment then
    return
  end

  local orig_buf, mod_buf = hooks.get_buffers()
  local orig_path, mod_path = hooks.get_paths()
  local targets = {}

  if comment.line == 0 then
    if orig_buf and orig_path == comment.file then
      table.insert(targets, orig_buf)
    end
    if mod_buf and mod_path == comment.file then
      table.insert(targets, mod_buf)
    end
  elseif (comment.side or "new") == "old" then
    if orig_buf and orig_path == comment.file then
      table.insert(targets, orig_buf)
    end
  elseif mod_buf and mod_path == comment.file then
    table.insert(targets, mod_buf)
  end

  for _, bufnr in ipairs(targets) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      clear_comment_marks(bufnr, comment.id)
      if not (opts and opts.delete) then
        render_comment(bufnr, comment)
      end
    end
  end

  if orig_buf and mod_buf and (orig_path or mod_path) and comment.line ~= 0 then
    M.align_buffers_at_line(orig_buf, mod_buf, orig_path, mod_path, (comment.line_end or comment.line) - 1)
  end
end

function M.clear_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
      vim.api.nvim_buf_clear_namespace(bufnr, ns_padding, 0, -1)
      mark_ids_by_buf[bufnr] = nil
    end
  end
end

return M
