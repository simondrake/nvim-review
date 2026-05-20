<div align="center">

# nvim-review

##### A lightweight code review split for Neovim, inspired by vim-fugitive's `:G`.

</div>

## Features

- `:Review` opens a bottom split showing changed files grouped by status (staged, unstaged, untracked)
- `:Review <ref>` compares HEAD against any branch, tag, or commit
- `:Blame` opens a scroll-synced blame split alongside the current file
- Press `<CR>` on a file to open it in the window above
- Press `<CR>` on a blame line to open the blame URL in the browser (requires [decorated_yank](https://github.com/simondrake/decorated_yank))
- Navigate files programmatically with `navigate()` for keymap integration
- Section headers with syntax highlighting for file status (modified, added, deleted, untracked)
- Shows current branch and comparison ref in the header

## Requirements

- Neovim 0.12+
- A git repository
- [decorated_yank](https://github.com/simondrake/decorated_yank) (optional, for opening blame URLs in the browser)

## Installation

```lua
-- lazy.nvim
{
  "simondrake/nvim-review",
  dependencies = { "simondrake/decorated_yank" }, -- optional, for blame browser links
  config = function()
    require("nvim-review").setup()
  end,
}
```

## Usage

```vim
:Review                 " Staged, unstaged, and untracked files
:Review main            " Changes compared to main
:Review HEAD~3          " Changes compared to 3 commits ago
:Review origin/main     " Changes compared to remote main
```

### Blame

```vim
:Blame                  " Open blame split for the current file
```

Opens a scroll-synced left split showing commit hash, author, and date for each line. The blame pane stays aligned with the source file as you scroll.

#### Blame Keymaps

| Key | Action |
|---|---|
| `<CR>` | Open blame URL in the browser at the current line (requires decorated_yank) |
| `q` | Close the blame split |

Consecutive lines from the same commit are dimmed to reduce visual noise.

### Review Buffer Keymaps

| Key | Action |
|---|---|
| `<CR>` | Open file under cursor in the window above |
| `d` | Show git diff for file under cursor in a floating window (`q`/`<Esc>` to close) |
| `q` | Close the review split |

In the opened file buffer:

| Key | Action |
|---|---|
| `<leader>do` | Toggle inline diff overlay (shows deletions/changes inline via `mini.diff`) |

### Navigation API

`navigate(direction)` moves through files in the review split and opens them. Returns `false` if the review split isn't open, so you can fall back to quickfix:

```lua
vim.keymap.set("n", "<leader>k", function()
  local review = require("nvim-review")
  if not review.is_open() or not review.navigate(1) then
    pcall(vim.cmd, "cnext")
  end
end)

vim.keymap.set("n", "<leader>j", function()
  local review = require("nvim-review")
  if not review.is_open() or not review.navigate(-1) then
    pcall(vim.cmd, "cprevious")
  end
end)
```

Navigation wraps around -- going past the last file jumps to the first, and vice versa.

## API

| Function | Description |
|---|---|
| `setup(opts?)` | Register the `:Review` and `:Blame` commands |
| `is_open()` | Returns `true` if the review split is visible |
| `navigate(direction)` | Move to next (`1`) or previous (`-1`) file and open it. Returns `false` if review isn't open. |
