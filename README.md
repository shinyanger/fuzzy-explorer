# fuzzy-explorer
TUI file explorer based on PowerShell and fzf.

## Features
* Cross platform.
* PowerShell style.
* Mouse support.
* Command mode.
* Extendable.

## Prerequisite
### Required
* [PowerShell](https://github.com/PowerShell/PowerShell)
* [fzf](https://github.com/junegunn/fzf)

### Optional
* [bat](https://github.com/sharkdp/bat)
* [fd](https://github.com/sharkdp/fd)
* [ripgrep](https://github.com/BurntSushi/ripgrep)

## Installation
Clone this repo and run `fuzzy.ps1`.
It is recommended to add a function to your `$PROFILE`:
```
function fe {
    & path/to/fuzzy-explorer/fuzzy.ps1
}
```

## Usage
Key   | Action
----- | ------
enter | enter directory / open file
left  | go to parent directory
right | enter directory
f5    | refresh directory
:     | select command

## Advanced
### Extension
You may add custom commands in `extensions.json`.

If `type` is `file`, the identifier `{0}` in `description` and `expression` will be replaced by selected file's name.

The shortcut format need to follow `fzf`'s.
