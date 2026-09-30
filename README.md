# topsdo

A [todo.txt](https://github.com/todotxt/todo.txt) manager for PowerShell, inspired by
[topydo](https://github.com/topydo/topydo). Plain PowerShell, no dependencies, runs on
**Windows PowerShell 5.1** and **PowerShell 7+** (Windows, Linux, macOS).

It has the three topydo interfaces:

- **CLI** – `t add`, `t ls`, `t do 3`, ...
- **Prompt mode** – `t prompt`: an interactive shell with history and tab completion
- **Column mode** – `t columns`: a full-screen, keyboard driven view with one column per filter

Features: priorities, projects, contexts, due (`due:`) and start dates (`t:`) with relative
dates, recurrence (`rec:1w`, strict `rec:+1m`), dependencies (`id:`/`p:` with `before:`,
`after:`, `partof:` shortcuts), hidden items (`h:1`), stars, importance based sorting,
grouping, filter expressions, custom output formats, JSON and Graphviz output, archiving to
`done.txt`, undo (`revert`), aliases and text based identifiers.

## Installation

```powershell
git clone https://github.com/rubilein/topsdo.git
cd topsdo
./topsdo.ps1 help
```

To use it from anywhere, import the module (e.g. in your `$PROFILE`). It provides the
short command **`t`** (and the long form `topsdo`):

```powershell
Import-Module /path/to/topsdo/Topsdo/Topsdo.psd1
t ls
```

or copy the `Topsdo` folder into a directory from `$env:PSModulePath`
(e.g. `~\Documents\PowerShell\Modules` / `~\Documents\WindowsPowerShell\Modules` /
`~/.local/share/powershell/Modules`). On Linux/macOS `topsdo.ps1` can be run directly
(`chmod +x`); for the short command link the `t` wrapper into your PATH:
`ln -s /path/to/topsdo/t ~/.local/bin/t`. From `cmd.exe` use `t.cmd` (or `topsdo.cmd`).

If `t` collides with an alias or function of your own, use `topsdo` or remove the alias
with `Remove-Alias t` after importing (PowerShell 6+; in 5.1: `Remove-Item Alias:t`).

Windows PowerShell 5.1 may need `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`
(or `Unblock-File` on the downloaded files) before scripts can run.

## Quick start

```powershell
t add '(A) Call Bob about the offer @phone +sales due:tomorrow'
t add 'Write report +work due:fri t:wed'
t add 'Collect numbers +work partof:2'   # subtask of todo 2
t add 'Water plants rec:3d'
t ls
t ls +work -g context
t do 1
t postpone 2 1w
t revert
```

> **PowerShell quoting:** `@`, `(`, `)`, `<`, `>`, `,` and `{}` mean something to the
> PowerShell parser. Quote todo text and filter expressions that contain them:
> `t add '(A) Call @home'`, `t ls 'due:<=today'`. The prompt mode has no such
> restrictions.

The todo file is `todo.txt` in the current directory unless configured otherwise
(`filename` in the config, or `-t path`).

## Commands

| Command | Description |
|---|---|
| `add <text>` / `add -f <file\|->` | Add todos. Relative dates in `due:`/`t:` are converted; `before:ID`, `after:ID`, `partof:ID`, `children-of:ID`, `parents-of:ID` create dependencies. |
| `append <ID> <text>` (`app`) | Append text/tags to a todo. |
| `archive` | Move completed todos to `done.txt`. |
| `columns [-l FILE]` | Start column mode. |
| `del [-f] <ID>...` / `del -e <expr>` (`rm`) | Delete todos (asks about subtasks unless `-f`). |
| `dep add\|rm <ID> [to\|after\|before\|partof] <ID>` | Manage dependencies; `dep ls <ID> to`, `dep ls to <ID>`, `dep clean`. |
| `depri <ID>...` | Remove the priority. |
| `do [-d DATE] [-s] [-f] <ID>...` / `do -e <expr>` | Complete todos; handles recurrence and subtasks. |
| `edit [<ID>...]` / `edit -e <expr>` / `edit -d` | Edit in `$env:TOPSDO_EDITOR`, `$env:VISUAL`, `$env:EDITOR` (fallback: notepad / nano / vi). |
| `help [command]` | Help. |
| `ls [options] [expression]` | List todos. |
| `lscon` / `lsprj` | List contexts / projects. |
| `postpone [-s] <ID>... <pattern>` | Move the due date (and with `-s` the start date) by e.g. `3d`, `2w`, `1m`, `5b`. |
| `pri <ID>... <A-Z>` | Set the priority. |
| `prompt` | Start prompt mode. |
| `revert` / `revert ls` | Undo the last modifying command / list backups. |
| `sort [expression]` | Sort the todo file permanently. |
| `tag [-a] <ID> <name> [value]` | Set (or with no value remove) a tag. |

Global options: `-c CONFIG`, `-t TODO_FILE`, `-d DONE_FILE`, `-C 0|1` (colors), `-v`, `-h`.
IDs can be given separated by spaces or commas (`do 1,4,7`).

### Dates

`today`/`tod`, `tomorrow`/`tom`, `yesterday`, weekday names (`mo`, `mon`, `monday`,
... – always the *next* occurrence), periods `Nd` `Nw` `Nm` `Ny` and business days `Nb`
(also negative: `-2d`), or `yyyy-mm-dd`.

### ls

```
ls [-x] [-n N] [-N] [-s SORT] [-g GROUP] [-f text|json|dot] [-F FORMAT] [-i IDS] [EXPRESSION]
```

By default `ls` hides completed todos, todos with a future start date, todos with
unfinished subtasks (blocked) and hidden todos (`h:1`). `-x` shows everything.

Expression words must all match:

| Word | Meaning |
|---|---|
| `word`, `-word` | text contains (not) `word` (case-insensitive) |
| `/regex/` | regular expression |
| `+project`, `@context` | project / context |
| `(A)`, `(<B)`, `(>=C)`, `(!A)` | priority, `A` is highest |
| `key:value`, `key:!value` | tag equals / not equals |
| `due:<today`, `due:<=1w`, `t:>tomorrow`, `effort:>=3` | comparisons for dates, numbers and text |
| `due:*`, `due:!` | tag present / absent |

Sort fields (`-s`, `sort_string`): `importance`, `importance-avg`, `priority`, `due`,
`start`, `creation`, `completed`, `text`, `length`, `project`, `context`, `line` or any tag
name, each optionally prefixed with `asc:`/`desc:`, comma separated. Default:
`desc:importance,due,desc:priority`.

Format placeholders (`-F`, `list_format`): `%i` id, `%I` padded id, `%p` priority,
`%P` `(A)`, `%s` text without tags, `%k` visible tags, `%K` all tags, `%x`
completion marker, `%X` relative completion, `%c`/`%C` creation date absolute/relative,
`%d`/`%D` due, `%t`/`%T` start, `%h` relative due/start summary, `%H` including creation,
`%r` raw line, `%z` star. `%{prefix}X{suffix}` only prints prefix/suffix when the value is
not empty. Default: `%I %x %{(}p{)} %s %k %{(}h{)}`.

### Importance

Like topydo: base 2, plus 3/2/1 for priority A/B/C, plus 1 (due in 7-13 days), 2 (2-6
days), 3 (tomorrow), 5 (today) or 6 (overdue), plus 1 for `star:1` and, with
`ignore_weekends = 1`, plus 1 on weekends for items due next Monday. `importance-avg` also takes the importance of the
todos depending on an item into account.

### Dependencies

`dep add 1 to 2` (or `after`) means todo 1 depends on todo 2: todo 1 gets `id:N`, todo 2
gets `p:N`. `before`/`partof` is the reverse. A todo with unfinished subtasks is hidden
in `ls` until they are done; `do` offers to complete subtasks together with the parent.

### Recurrence

`rec:1w` creates the next instance one week after the completion day; `rec:+1w` (or
`do -s`) is strict and counts from the old due date. A start date keeps its distance to the
due date.

## Prompt mode

```
t prompt
topsdo> add (A) Call Bob @phone due:fri
topsdo> ls +work
topsdo> do 3
topsdo> exit
```

Commands are entered without the `t` prefix and without PowerShell quoting rules
(single/double quotes group words). Keys: `Tab` completes commands, `+projects`,
`@contexts` and dates after `due:`/`t:`; `Up`/`Down` history (saved in
`~/.topsdo_history`); `Ctrl+A/E/U/K/W`; `Esc` clears the line; `exit`, `quit` or `Ctrl+D`
leave. `columns` switches to column mode and returns afterwards. With redirected standard
input the prompt reads commands line by line, e.g.
`Get-Content cmds.txt | pwsh -NoProfile -File topsdo.ps1 prompt`.

## Column mode

```
t columns [-l COLUMN_FILE]
```

Every column is a saved view (filter, sort, grouping). Columns are read from
`~/.topsdo_columns` (`column_file`); see [examples/columns](examples/columns). Without a
file there is a single "All tasks" column. Columns can be created and changed inside
column mode and are saved automatically.

| Keys | Action |
|---|---|
| `j`/`k`, `Down`/`Up` | move |
| `h`/`l`, `Left`/`Right`, `Tab`/`Shift+Tab` | previous / next column |
| `gg`/`G`, `Home`/`End` | first / last item |
| `PgUp`/`PgDn`, `Ctrl+B`/`Ctrl+F`, `Ctrl+U`/`Ctrl+D` | page / half page |
| `0` / `$` | first / last column |
| `x` | complete (`do`) |
| `d` | delete |
| `e` | edit in editor |
| `pp` + `3d` / `ps` + `1w` | postpone (with start date) |
| `pr` + `A`..`Z` / `-`, `pd` | set / remove priority |
| `a`, `A`, `t` | add todo, append to item, tag item |
| `m`/`Space`, `Ctrl+A`, `Esc` | mark item, mark all, clear marks/search |
| `:` | run any topsdo command (`{}` = marked or selected ids) |
| `/` | search within the column |
| `.` | repeat the last command on the current selection |
| `u` | undo (`revert`) |
| `Enter` | details (dependencies, dates, importance) |
| `N`, `E`, `C`, `D`, `<`, `>` | new, edit, copy, delete, move column |
| `r`/`F5`, `?`, `q` | reload, help, quit |

Commands act on the marked items, or on the selected item when nothing is marked. The view
refreshes automatically when the todo file changes on disk. All keys can be rebound in the
`[column_keymap]` section: `key = action`, where the key is a character, a sequence
(`gg`), `<C-x>` for Ctrl+x or one of `<Up> <Down> <Left> <Right> <Enter> <Esc> <Tab>
<S-Tab> <BS> <Del> <Home> <End> <PgUp> <PgDn> <Space> <F1>..<F12>`, and the action is one
from the help screen (`?`) or `cmd <topsdo command>`, e.g. `S = cmd pri {} A`.

## Configuration

INI files, read in this order (later override earlier): `$XDG_CONFIG_HOME/topsdo/config`
(`~/.config/topsdo/config`), `%APPDATA%\topsdo\config`, `~/.topsdo`, `./topsdo.conf`,
`./.topsdo` – or only the file given with `-c` / `$env:TOPSDO_CONFIG`.
[examples/topsdo.conf](examples/topsdo.conf) lists every option with its default. topydo
config files mostly work as well (`[topydo]` is read as `[topsdo]`).

Aliases:

```ini
[aliases]
today = ls due:<=today
top = ls -n {}
```

`{}` is replaced by the remaining arguments (otherwise they are appended).

## PowerShell integration

- `Get-TopsdoItem [-Filter <expr>] [-All] [-Path <todo.txt>]` returns todo items as
  objects (`Id`, `Priority`, `Text`, `Due`, `Start`, `Projects`, `Contexts`, `Tags`,
  `Importance`, ...):
  `Get-TopsdoItem '+work' | Where-Object Due -lt (Get-Date).AddDays(3)`
- Output piped into another command is plain text (no colors):
  `t ls | Select-String report`. Use `-C 0` when redirecting with `>`.
- `t ls -f json | ConvertFrom-Json` for structured data.
- `$LASTEXITCODE` is 1 when a command failed.

## Tests

```powershell
pwsh -NoProfile -File tests/Run-Tests.ps1         # PowerShell 7
powershell -NoProfile -File tests/Run-Tests.ps1   # Windows PowerShell 5.1
```

The test runner has no dependencies (no Pester required).

## Differences to topydo

topsdo covers topydo's CLI, prompt and column modes, but not everything: no iCalendar
output, no `listview`/`import` commands, `edit` does not validate, the column mode truncates
long lines instead of wrapping them (press `Enter` for the full item), and colors use the
16 console colors so they work the same in Windows PowerShell 5.1.

## License

GPL-3.0, see [LICENSE](LICENSE).
