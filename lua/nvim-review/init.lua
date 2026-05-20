local M = {}

local review_bufnr = nil
local review_winnr = nil

local function get_git_root()
  local dir = vim.fn.expand("%:p:h")
  if dir ~= "" then
    local result = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
    if result.code == 0 then
      return result.stdout:gsub("\n$", "")
    end
  end
  local result = vim.system({ "git", "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel" }, { text = true }):wait()
  if result.code == 0 then
    return result.stdout:gsub("\n$", "")
  end
  return nil
end

local function parse_status_output(output)
  local files = {}
  for line in output:gmatch("[^\n]+") do
    local status, file = line:match("^(%S+)%s+(.+)$")
    if status and file then
      table.insert(files, { status = status, file = file })
    end
  end
  return files
end

local function get_git_info()
  local git_root = get_git_root()
  if not git_root then
    return nil
  end

  local branch = vim.system({ "git", "-C", git_root, "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }):wait()
  local head = vim.system({ "git", "-C", git_root, "rev-parse", "--short", "HEAD" }, { text = true }):wait()

  return {
    root = git_root,
    branch = branch.code == 0 and branch.stdout:gsub("\n$", "") or "unknown",
    head = head.code == 0 and head.stdout:gsub("\n$", "") or "",
  }
end

local function get_merge_base(ref, git_root)
  local result = vim.system({ "git", "-C", git_root, "merge-base", ref, "HEAD" }, { text = true }):wait()
  if result.code == 0 and result.stdout ~= "" then
    return result.stdout:gsub("\n$", "")
  end
  return nil
end

local function get_changed_files(ref, git_root)
  if ref then
    local base = get_merge_base(ref, git_root) or ref
    local seen = {}
    local changed = {}

    local diff_out = vim.system({ "git", "-C", git_root, "diff", "--name-status", base }, { text = true }):wait()
    if diff_out.code == 0 and diff_out.stdout ~= "" then
      for _, f in ipairs(parse_status_output(diff_out.stdout)) do
        if not seen[f.file] then
          seen[f.file] = true
          table.insert(changed, f)
        end
      end
    end

    local untracked_out = vim.system({ "git", "-C", git_root, "ls-files", "--others", "--exclude-standard" }, { text = true }):wait()
    if untracked_out.code == 0 and untracked_out.stdout ~= "" then
      for file in untracked_out.stdout:gmatch("[^\n]+") do
        if file ~= "" and not seen[file] then
          seen[file] = true
          table.insert(changed, { status = "??", file = file })
        end
      end
    end

    return { changed = changed }
  end

  local staged = {}
  local unstaged = {}
  local untracked = {}

  local staged_out = vim.system({ "git", "-C", git_root, "diff", "--name-status", "--cached" }, { text = true }):wait()
  if staged_out.code == 0 and staged_out.stdout ~= "" then
    staged = parse_status_output(staged_out.stdout)
  end

  local seen = {}
  for _, f in ipairs(staged) do
    seen[f.file] = true
  end

  local unstaged_out = vim.system({ "git", "-C", git_root, "diff", "--name-status" }, { text = true }):wait()
  if unstaged_out.code == 0 and unstaged_out.stdout ~= "" then
    for _, f in ipairs(parse_status_output(unstaged_out.stdout)) do
      if not seen[f.file] then
        table.insert(unstaged, f)
      end
    end
  end

  local untracked_out = vim.system({ "git", "-C", git_root, "ls-files", "--others", "--exclude-standard" }, { text = true }):wait()
  if untracked_out.code == 0 and untracked_out.stdout ~= "" then
    for file in untracked_out.stdout:gmatch("[^\n]+") do
      if file ~= "" then
        table.insert(untracked, { status = "??", file = file })
      end
    end
  end

  return { staged = staged, unstaged = unstaged, untracked = untracked }
end

local function create_review_buffer(file_groups, git_info, ref)
  local lines = {}
  local line_to_file = {}
  local all_files = {}
  local file_line_numbers = {}

  local function add_header(text)
    table.insert(lines, text)
    table.insert(line_to_file, 0)
  end

  local function add_file(item)
    table.insert(all_files, item)
    local idx = #all_files
    table.insert(lines, string.format("  %s %s", item.status, item.file))
    table.insert(line_to_file, idx)
    file_line_numbers[idx] = #lines
  end

  local header = "Head: " .. git_info.branch
  if ref then
    header = header .. " (vs " .. ref .. ")"
  end
  add_header(header)
  add_header("")

  if file_groups.changed then
    if #file_groups.changed == 0 then
      add_header("No changes to review")
    else
      add_header("Changed (" .. #file_groups.changed .. ")")
      for _, f in ipairs(file_groups.changed) do
        add_file(f)
      end
    end
  else
    local has_any = (#(file_groups.staged or {}) + #(file_groups.unstaged or {}) + #(file_groups.untracked or {})) > 0
    if not has_any then
      add_header("No changes to review")
    else
      if #(file_groups.staged or {}) > 0 then
        add_header("Staged (" .. #file_groups.staged .. ")")
        for _, f in ipairs(file_groups.staged) do
          add_file(f)
        end
        add_header("")
      end
      if #(file_groups.unstaged or {}) > 0 then
        add_header("Unstaged (" .. #file_groups.unstaged .. ")")
        for _, f in ipairs(file_groups.unstaged) do
          add_file(f)
        end
        add_header("")
      end
      if #(file_groups.untracked or {}) > 0 then
        add_header("Untracked (" .. #file_groups.untracked .. ")")
        for _, f in ipairs(file_groups.untracked) do
          add_file(f)
        end
      end
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "nvim-review", { buf = bufnr })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

  local status_hl = {
    M = "DiffChange",
    A = "DiffAdd",
    D = "DiffDelete",
    R = "DiffChange",
    ["??"] = "Comment",
  }

  for i, line in ipairs(lines) do
    if line_to_file[i] and line_to_file[i] ~= 0 then
      local file = all_files[line_to_file[i]]
      local hl = status_hl[file.status] or "Normal"
      vim.api.nvim_buf_add_highlight(bufnr, -1, hl, i - 1, 2, 2 + #file.status)
    elseif line ~= "" then
      vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", i - 1, 0, -1)
    end
  end

  vim.api.nvim_buf_set_var(bufnr, "review_files", all_files)
  vim.api.nvim_buf_set_var(bufnr, "review_line_map", line_to_file)
  vim.api.nvim_buf_set_var(bufnr, "review_file_lines", file_line_numbers)

  return bufnr, #lines
end

local function apply_ref_diff(file_bufnr, git_root, base, relpath)
  local ok_minidiff, minidiff = pcall(require, "mini.diff")
  if not ok_minidiff then
    return
  end

  local result = vim.system({ "git", "-C", git_root, "show", base .. ":" .. relpath }, { text = true }):wait()
  local ref_text = ""
  if result.code == 0 then
    ref_text = result.stdout or ""
  end

  local set = function()
    if vim.api.nvim_buf_is_valid(file_bufnr) then
      pcall(minidiff.set_ref_text, file_bufnr, ref_text)
    end
  end

  -- mini.diff's git source asynchronously sets reference text to the HEAD blob
  -- after attach. Set immediately, then re-apply a few times to win the race.
  set()
  for _, delay in ipairs({ 50, 200, 500 }) do
    vim.defer_fn(set, delay)
  end
end

local function setup_file_keymaps(file_bufnr)
  local ok_minidiff, minidiff = pcall(require, "mini.diff")
  if not ok_minidiff then
    return
  end
  vim.keymap.set("n", "<leader>do", function()
    minidiff.toggle_overlay(file_bufnr)
  end, { noremap = true, silent = true, buffer = file_bufnr, desc = "Toggle inline diff overlay" })
end

local function find_editor_win(review_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= review_win then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative == "" then
        return win
      end
    end
  end
  return nil
end

local function open_file_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local ok_map, line_map = pcall(vim.api.nvim_buf_get_var, bufnr, "review_line_map")
  if not ok_map or not line_map[lnum] or line_map[lnum] == 0 then
    return
  end

  local ok_files, files = pcall(vim.api.nvim_buf_get_var, bufnr, "review_files")
  if not ok_files then
    return
  end

  local file_idx = line_map[lnum]
  if not files[file_idx] then
    return
  end

  local git_root = get_git_root()
  if not git_root then
    return
  end

  local relpath = files[file_idx].file
  local full_path = git_root .. "/" .. relpath

  local ok_base, merge_base = pcall(vim.api.nvim_buf_get_var, bufnr, "review_merge_base")
  if not ok_base then
    merge_base = ""
  end

  local target_win = find_editor_win(review_winnr)
  if target_win then
    vim.api.nvim_set_current_win(target_win)
  else
    vim.cmd("above split")
  end

  vim.cmd("edit " .. vim.fn.fnameescape(full_path))

  if merge_base ~= "" then
    apply_ref_diff(vim.api.nvim_get_current_buf(), git_root, merge_base, relpath)
  end
  setup_file_keymaps(vim.api.nvim_get_current_buf())
end

local function get_file_diff(git_root, status, relpath, merge_base)
  local cmd
  if merge_base and merge_base ~= "" then
    cmd = { "git", "-C", git_root, "diff", merge_base, "--", relpath }
  elseif status == "??" then
    cmd = { "git", "-C", git_root, "diff", "--no-index", "--", "/dev/null", relpath }
  else
    cmd = { "git", "-C", git_root, "diff", "HEAD", "--", relpath }
  end

  local result = vim.system(cmd, { text = true }):wait()
  -- `git diff --no-index` exits 1 when files differ, which is the normal case here.
  if result.code ~= 0 and result.code ~= 1 then
    return nil, result.stderr or ""
  end
  return result.stdout or "", nil
end

local function open_diff_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local ok_map, line_map = pcall(vim.api.nvim_buf_get_var, bufnr, "review_line_map")
  if not ok_map or not line_map[lnum] or line_map[lnum] == 0 then
    return
  end

  local ok_files, files = pcall(vim.api.nvim_buf_get_var, bufnr, "review_files")
  if not ok_files then
    return
  end

  local file_idx = line_map[lnum]
  local entry = files[file_idx]
  if not entry then
    return
  end

  local git_root = get_git_root()
  if not git_root then
    return
  end

  local ok_base, merge_base = pcall(vim.api.nvim_buf_get_var, bufnr, "review_merge_base")
  if not ok_base then
    merge_base = ""
  end

  local diff_text, err = get_file_diff(git_root, entry.status, entry.file, merge_base)
  if not diff_text then
    vim.notify("git diff failed: " .. (err or ""), vim.log.levels.ERROR)
    return
  end

  local lines = {}
  if diff_text == "" then
    lines = { "(no diff for " .. entry.file .. ")" }
  else
    for line in diff_text:gmatch("([^\n]*)\n?") do
      table.insert(lines, line)
    end
    if lines[#lines] == "" then
      table.remove(lines, #lines)
    end
  end

  local diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = diff_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = diff_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = diff_buf })
  vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = diff_buf })
  vim.api.nvim_set_option_value("filetype", "diff", { buf = diff_buf })

  local ui = vim.api.nvim_list_uis()[1] or { width = vim.o.columns, height = vim.o.lines }
  local width = math.floor(ui.width * 0.85)
  local height = math.floor(ui.height * 0.85)
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  local diff_win = vim.api.nvim_open_win(diff_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. entry.file .. " ",
    title_pos = "center",
  })

  vim.api.nvim_set_option_value("wrap", false, { win = diff_win })
  vim.api.nvim_set_option_value("cursorline", true, { win = diff_win })

  local close_opts = { noremap = true, silent = true, buffer = diff_buf }
  local function close()
    if vim.api.nvim_win_is_valid(diff_win) then
      vim.api.nvim_win_close(diff_win, true)
    end
  end
  vim.keymap.set("n", "q", close, close_opts)
  vim.keymap.set("n", "<Esc>", close, close_opts)
end

-- Setup keymaps for review buffer
local function setup_review_keymaps(bufnr)
  local opts = { noremap = true, silent = true, buffer = bufnr }

  vim.keymap.set("n", "<CR>", open_file_at_cursor, opts)
  vim.keymap.set("n", "d", open_diff_at_cursor, opts)

  -- Close review with q
  vim.keymap.set("n", "q", function()
    local winnr = vim.fn.bufwinnr(bufnr)
    if winnr > 0 then
      vim.api.nvim_win_close(vim.api.nvim_list_wins()[winnr], true)
      review_winnr = nil
    end
  end, opts)
end

-- Open review split
local function open_review(ref)
  local git_info = get_git_info()
  if not git_info then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  if review_winnr and vim.api.nvim_win_is_valid(review_winnr) then
    vim.api.nvim_win_close(review_winnr, true)
  end

  local file_groups = get_changed_files(ref, git_info.root)
  local merge_base = ref and get_merge_base(ref, git_info.root) or nil
  local line_count
  review_bufnr, line_count = create_review_buffer(file_groups, git_info, ref)
  vim.api.nvim_buf_set_var(review_bufnr, "review_merge_base", merge_base or "")

  vim.cmd("botright split")
  review_winnr = vim.api.nvim_get_current_win()

  local height = math.min(math.max(line_count, 4), 16)
  vim.api.nvim_win_set_height(review_winnr, height)

  vim.api.nvim_win_set_buf(review_winnr, review_bufnr)

  vim.api.nvim_set_option_value("number", false, { win = review_winnr })
  vim.api.nvim_set_option_value("relativenumber", false, { win = review_winnr })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = review_winnr })
  vim.api.nvim_set_option_value("cursorline", true, { win = review_winnr })
  vim.api.nvim_set_option_value("winfixheight", true, { win = review_winnr })

  setup_review_keymaps(review_bufnr)

  vim.api.nvim_set_option_value("buflisted", false, { buf = review_bufnr })

  local ok_lines, file_lines = pcall(vim.api.nvim_buf_get_var, review_bufnr, "review_file_lines")
  if ok_lines and file_lines and file_lines[1] then
    vim.api.nvim_win_set_cursor(review_winnr, { file_lines[1], 0 })
    open_file_at_cursor()
  else
    local target_win = find_editor_win(review_winnr)
    if target_win then
      vim.api.nvim_set_current_win(target_win)
    end
  end
end

function M.is_open()
  return review_winnr ~= nil and vim.api.nvim_win_is_valid(review_winnr)
end

function M.navigate(direction)
  if not M.is_open() or not review_bufnr then
    return false
  end

  local ok_files, files = pcall(vim.api.nvim_buf_get_var, review_bufnr, "review_files")
  local ok_lines, file_lines = pcall(vim.api.nvim_buf_get_var, review_bufnr, "review_file_lines")
  local ok_map, line_map = pcall(vim.api.nvim_buf_get_var, review_bufnr, "review_line_map")
  if not ok_files or not ok_lines or not ok_map or #files == 0 then
    return false
  end

  local cursor_lnum = vim.api.nvim_win_get_cursor(review_winnr)[1]
  local current_idx = line_map[cursor_lnum]
  if not current_idx or current_idx == 0 then
    current_idx = 0
  end

  local next_idx = current_idx + direction
  if next_idx < 1 then
    next_idx = #files
  elseif next_idx > #files then
    next_idx = 1
  end

  local target_lnum = file_lines[next_idx]
  if not target_lnum then
    return false
  end

  vim.api.nvim_win_set_cursor(review_winnr, { target_lnum, 0 })

  local git_root = get_git_root()
  if not git_root then
    return true
  end

  local relpath = files[next_idx].file
  local full_path = git_root .. "/" .. relpath
  local ok_base, merge_base = pcall(vim.api.nvim_buf_get_var, review_bufnr, "review_merge_base")
  if not ok_base then
    merge_base = ""
  end

  if vim.api.nvim_get_current_win() == review_winnr then
    local target_win = find_editor_win(review_winnr)
    if target_win then
      vim.api.nvim_set_current_win(target_win)
    else
      vim.cmd("above split")
    end
  end

  vim.cmd("edit " .. vim.fn.fnameescape(full_path))

  if merge_base ~= "" then
    apply_ref_diff(vim.api.nvim_get_current_buf(), git_root, merge_base, relpath)
  end
  setup_file_keymaps(vim.api.nvim_get_current_buf())
  return true
end

local function parse_porcelain_blame(output)
  local entries = {}
  local commits = {}
  local current_hash = nil
  local current_orig_line = nil
  local current_filename = nil

  for line in output:gmatch("[^\n]+") do
    local hash, orig_line = line:match("^(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x) (%d+) %d+")
    if hash then
      current_hash = hash
      current_orig_line = tonumber(orig_line)
      if not commits[hash] then
        commits[hash] = { hash = hash, short_hash = hash:sub(1, 8) }
      end
      current_filename = nil
    elseif current_hash then
      local key, value = line:match("^(%S+)%s(.+)$")
      if key == "author" then
        commits[current_hash].author = value
      elseif key == "author-time" then
        commits[current_hash].date = os.date("%Y-%m-%d", tonumber(value))
      elseif key == "filename" then
        current_filename = value
        commits[current_hash].filename = value
      elseif line:match("^\t") then
        local c = commits[current_hash]
        table.insert(entries, {
          hash = c.hash,
          short_hash = c.short_hash,
          author = c.author or "Unknown",
          date = c.date or "",
          orig_line = current_orig_line,
          filename = current_filename or c.filename or "",
        })
        current_hash = nil
        current_orig_line = nil
        current_filename = nil
      end
    end
  end

  return entries
end

local function open_blame()
  local source_win = vim.api.nvim_get_current_win()
  local cursor_line = vim.api.nvim_win_get_cursor(source_win)[1]
  local file = vim.fn.expand("%:p")

  local git_root = get_git_root()
  if not git_root then
    vim.notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  local rel = file
  if file:sub(1, #git_root) == git_root then
    rel = file:sub(#git_root + 2)
  end

  local head_result = vim.system({ "git", "-C", git_root, "rev-parse", "HEAD" }, { text = true }):wait()
  local head_commit = head_result.code == 0 and head_result.stdout:gsub("\n$", "") or nil

  local result = vim.system({ "git", "-C", git_root, "blame", "--porcelain", rel }, { text = true }):wait()
  if result.code ~= 0 then
    vim.notify("git blame failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
    return
  end

  local entries = parse_porcelain_blame(result.stdout)

  local max_author = 0
  for _, e in ipairs(entries) do
    if #e.author > max_author then
      max_author = #e.author
    end
  end
  max_author = math.min(max_author, 15)

  local sep = " "
  local blame_lines = {}
  local highlights = {}
  local prev_hash = nil
  for _, e in ipairs(entries) do
    local author = #e.author > max_author and e.author:sub(1, max_author) or e.author
    local padded_author = author .. string.rep(" ", max_author - #author)
    local line = e.short_hash .. sep .. padded_author .. sep .. e.date
    table.insert(blame_lines, line)

    local hash_end = #e.short_hash
    local author_start = hash_end + #sep
    local author_end = author_start + max_author
    local date_start = author_end + #sep
    local date_end = #line

    local same_as_prev = (e.short_hash == prev_hash)
    table.insert(highlights, {
      hash_end = hash_end,
      author_start = author_start,
      author_end = author_end,
      date_start = date_start,
      date_end = date_end,
      dimmed = same_as_prev,
    })
    prev_hash = e.short_hash
  end

  local ns = vim.api.nvim_create_namespace("nvim-review-blame")

  local blame_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = blame_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = blame_buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = blame_buf })
  vim.api.nvim_buf_set_lines(blame_buf, 0, -1, false, blame_lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = blame_buf })
  vim.api.nvim_set_option_value("filetype", "git-blame", { buf = blame_buf })

  for i, hl in ipairs(highlights) do
    if hl.dimmed then
      vim.api.nvim_buf_add_highlight(blame_buf, ns, "Comment", i - 1, 0, -1)
    else
      vim.api.nvim_buf_add_highlight(blame_buf, ns, "Constant", i - 1, 0, hl.hash_end)
      vim.api.nvim_buf_add_highlight(blame_buf, ns, "String", i - 1, hl.author_start, hl.author_end)
      vim.api.nvim_buf_add_highlight(blame_buf, ns, "Number", i - 1, hl.date_start, hl.date_end)
    end
  end

  local source_view = vim.fn.winsaveview()
  local source_wrap = vim.api.nvim_get_option_value("wrap", { win = source_win })
  local source_scrolloff = vim.api.nvim_get_option_value("scrolloff", { win = source_win })
  vim.api.nvim_set_option_value("wrap", false, { win = source_win })
  vim.api.nvim_set_option_value("scrolloff", 0, { win = source_win })

  vim.cmd("leftabove vsplit")
  local blame_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(blame_win, blame_buf)

  local max_width = 0
  for _, line in ipairs(blame_lines) do
    if #line > max_width then
      max_width = #line
    end
  end
  vim.api.nvim_win_set_width(blame_win, max_width + 1)

  vim.api.nvim_set_option_value("number", false, { win = blame_win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = blame_win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = blame_win })
  vim.api.nvim_set_option_value("winfixwidth", true, { win = blame_win })
  vim.api.nvim_set_option_value("cursorline", true, { win = blame_win })
  vim.api.nvim_set_option_value("wrap", false, { win = blame_win })
  vim.api.nvim_set_option_value("scrolloff", 0, { win = blame_win })

  vim.fn.winrestview({ topline = source_view.topline, lnum = cursor_line, col = 0 })

  vim.api.nvim_set_option_value("scrollbind", true, { win = blame_win })
  vim.api.nvim_set_option_value("cursorbind", true, { win = blame_win })

  vim.api.nvim_set_current_win(source_win)
  vim.fn.winrestview(source_view)
  vim.api.nvim_set_option_value("scrollbind", true, { win = source_win })
  vim.api.nvim_set_option_value("cursorbind", true, { win = source_win })
  vim.cmd("syncbind")

  local function cleanup_blame()
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_set_option_value("scrollbind", false, { win = source_win })
      vim.api.nvim_set_option_value("cursorbind", false, { win = source_win })
      vim.api.nvim_set_option_value("wrap", source_wrap, { win = source_win })
      vim.api.nvim_set_option_value("scrolloff", source_scrolloff, { win = source_win })
    end
  end

  local opts_keymap = { noremap = true, silent = true, buffer = blame_buf }

  vim.keymap.set("n", "<CR>", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    if not head_commit then return end

    local ok, decorated_yank = pcall(require, "decorated_yank")
    if not ok then
      vim.notify("decorated_yank not available", vim.log.levels.WARN)
      return
    end
    decorated_yank.blame_at(head_commit, rel, lnum, { cwd = git_root })
  end, opts_keymap)

  vim.keymap.set("n", "q", function()
    cleanup_blame()
    vim.api.nvim_win_close(blame_win, true)
  end, opts_keymap)

  vim.api.nvim_create_autocmd("BufWinLeave", {
    buffer = blame_buf,
    once = true,
    callback = cleanup_blame,
  })
end

function M.setup(opts)
  opts = opts or {}

  vim.api.nvim_create_user_command("Review", function(cmd)
    local ref = nil
    if cmd.args and cmd.args ~= "" then
      ref = cmd.args
    end
    open_review(ref)
  end, { nargs = "?" })

  vim.api.nvim_create_user_command("Blame", function()
    open_blame()
  end, {})
end

return M
