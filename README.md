# rex-sessionizer

A project picker for [Rex](https://www.superlogical.com/rex), ported from [ThePrimeagen's tmux-sessionizer](https://github.com/theprimeagen/tmux-sessionizer). One key lists your project directories; pick one to switch to its own Rex session.




https://github.com/user-attachments/assets/09a28223-c15a-40e3-b7be-e7d16c04c0ba



## Features

- **Switch or create**: fuzzy-pick a directory under `~/work` to jump to its session. If it has none yet, one is created with a shell started in the directory.
- **Nested projects**: when the current project holds only directories (a repo split into `frontend/` and `backend/`), those are listed first. Inside one of them, its siblings are listed first. Top-level projects are always below, and the current project last.
- **One session per directory**: sessions are labelled after their directory, so picking it again reopens the same session.

<details>
<summary>Example: what the picker lists</summary>

```
~/work/
├── project1/
├── project2/
│   ├── project2-fe/
│   └── project2-be/
└── zeta/

In project1:     project2, zeta, project1
In project2:     project2/project2-be, project2/project2-fe, project1, zeta, project2
In project2-fe:  project2/project2-be, project1, project2, zeta, project2/project2-fe
```

</details>

## Install

Requires `fzf` on your login shell's `PATH` (not needed with the [native picker](#native-picker)).

```sh
git clone https://github.com/haxybaxy/rex-sessionizer ~/.config/rex/rex-sessionizer
```

Add to `~/.config/rex/init.lua`:

```lua
require("rex-sessionizer").setup{ work_dir = "~/work" }
rex.bind("ctrl+space>f", "sessionizer")
```

Turn on **Rex → Settings → Rex Server → Remote Control** (required for the float picker), then run `rex config reload`.

The picker is also in the command palette as "Switch Project…".

## Options

```lua
require("rex-sessionizer").setup{
  work_dir = "~/work",                 -- the directory whose subdirectories are projects
  bounds   = { 0.15, 0.1, 0.7, 0.8 },  -- float x, y, width, height as fractions of the window
  picker   = "float",                  -- "native" lists in Rex's command palette instead (see below), make sure your server has API v17 or later
  layout   = nil,                      -- function(name, path) -> rex.layout for a new session
  script   = nil,                      -- picker script (default: sessionizer.sh)
}
```

<details>
<summary>Example: custom layout</summary>

```lua
require("rex-sessionizer").setup{
  work_dir = "~/work",
  -- nvim beside a shell
  layout = function(name, path)
    local shell = "com.superlogical.terminal.shell"
    return rex.layout.horizontal(0.6,
      rex.layout.block{ flavor = shell, options = { cwd = path, command = { "nvim" } } },
      rex.layout.block{ flavor = shell, options = { cwd = path } })
  end,
}
```

</details>

## Native picker
> [!NOTE]
> This option will become the default once more people update.

`picker = "native"` lists projects in Rex's command palette instead of fzf. It needs a Rex whose server and app can show palette prompts (`rex.ui`, server API revision 17 or later).

- Picking a project switches in place: no float, no fzf, and no Remote Control needed.
- The list matches the float's, in the same order. Projects that already have a session are marked `open`, and the current one `current`.
- The fzf float is used when Rex can't ask in the palette, and for sessions on remote hosts.

## CLI

```sh
rex do sessionizer                    # open the picker
rex do sessionizer_go path=<dir>      # open a directory's session: an absolute path, ~/path, or a name under work_dir
```

Run from the CLI, the switch needs Remote Control, whichever picker you use.

## Gotchas

- **Sessions are found by label**: two projects with the same directory name share a session, and renaming a session makes the next pick create a new one.
- **Symlinked `init.lua`**: clone next to the symlink, not its target.
- **`ctrl+space` as a prefix**: to still send it to the terminal, add `rex.bind("ctrl+space>ctrl+space", "pane.send_key", { key = "ctrl+space" })`.

## Upgrade

```sh
git -C ~/.config/rex/rex-sessionizer pull && rex config reload
```

## Development

Run `bash test/run.sh` to run all tests: the Lua tests against a fake `rex` (needs `luajit` or `lua`), the directory listing against a fixture, and shellcheck when it's installed.

## Credits

Ported from [ThePrimeagen's tmux-sessionizer](https://github.com/theprimeagen/tmux-sessionizer), by way of my own variant of it, which added the nested-project listing.
