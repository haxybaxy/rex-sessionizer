# rex-sessionizer

A project picker for [Rex](https://www.superlogical.com/rex), ported from [ThePrimeagen's tmux-sessionizer](https://github.com/theprimeagen/tmux-sessionizer): one key, a fuzzy list of your project directories, and a session for whichever you pick.


https://github.com/user-attachments/assets/08e96606-42da-4053-ba7e-b89186bae3f6


## Overview

Press the key and a floating [fzf](https://github.com/junegunn/fzf) picker lists the directories under `~/work`. Pick one and Rex switches to a session for it, creating the session with a shell started in that directory when there isn't one yet. Sessions are labelled after their directory, so the next pick finds the same session, and the current session is listed last, out of the way.

The picker understands nested projects. When the current project holds only directories, such as a repo split into `frontend/` and `backend/`, those are listed first. When the current project's parent holds only directories, its siblings are listed first. The top-level projects are always there below.

```
~/work/
├── project1/
└── project2/
    ├── project2-fe/
    └── project2-be/

Picker in project1:     project2, zeta, project1
Picker in project2-fe:  project2/project2-be, project1, project2, project2/project2-fe
```

## How it works

- `setup` defines two actions. `sessionizer` opens the picker in a floating terminal over the active window. `sessionizer_go` takes a `path` and switches to its session, creating it if needed; it also works from the CLI, as `rex do sessionizer_go path=project1`.
- The float runs `sessionizer.sh`, which lists the directories, runs fzf, and hands the choice back with `rex do sessionizer_go`. That action asks the app to show the session, which the app accepts from the CLI only when Remote Control is on. The action can't wait for the pick itself, because Rex stops taking input while a key-bound action runs.

## Install

Clone into Rex's configuration directory:

```sh
git clone https://github.com/haxybaxy/rex-sessionizer ~/.config/rex/rex-sessionizer
```

Add to `~/.config/rex/init.lua`:

```lua
require("rex-sessionizer").setup{ work_dir = "~/work" }
rex.bind("ctrl+space>f", "sessionizer")
```

Turn on Remote Control in Rex → Settings → Rex Server, then reload:

```sh
rex config reload
```

Rex loads modules from beside the `init.lua` it opens, so if `init.lua` is a symlink, clone next to the link. fzf has to be on the `PATH` your login shell sets.

`ctrl+space>f` is a key sequence, like a tmux prefix. If you use one, bind the prefix pressed twice to send it to the terminal:

```lua
rex.bind("ctrl+space>ctrl+space", "pane.send_key", { key = "ctrl+space" })
```

Any key works, and the picker is also in the command palette as "Switch Project…".

## Options

```lua
require("rex-sessionizer").setup{
  work_dir = "~/work",                 -- the directory whose subdirectories are projects
  bounds   = { 0.15, 0.1, 0.7, 0.8 },  -- x, y, width, height of the float, as fractions of the window
  layout   = nil,                      -- function(name, path) -> layout for a new session
  script   = nil,                      -- the picker script; sessionizer.sh beside init.lua by default
}
```

A `layout` function builds the first window of a new session with `rex.layout`, for example an editor beside a shell:

```lua
layout = function(name, path)
  local shell = "com.superlogical.terminal.shell"
  return rex.layout.horizontal(0.6,
    rex.layout.block{ flavor = shell, options = { cwd = path, command = { "nvim" } } },
    rex.layout.block{ flavor = shell, options = { cwd = path } })
end
```

## Test

`test/list_test.sh` checks the directory listing and its order against a fixture, without Rex:

```sh
bash test/list_test.sh
```

## Upgrade

```sh
git -C ~/.config/rex/rex-sessionizer pull
rex config reload
```

## Credits

The original is [ThePrimeagen's tmux-sessionizer](https://github.com/theprimeagen/tmux-sessionizer). This is a port of my own variant of it, which added the nested-project listing, to Rex sessions.
