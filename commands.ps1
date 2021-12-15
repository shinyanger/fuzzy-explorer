using namespace System.Collections.Generic

enum CommandType {
    common
    file
}

class Command : System.ICloneable {
    [bool]$internal
    [string]$id
    [List[string]]$aliases
    [string]$type
    [string]$description
    [string]$shortcut
    [bool]$multiSupport
    [scriptblock]$predicate
    [scriptblock]$expression
    Command() {
        $this.Init()
    }
    Command(
        [string]$id,
        [string]$type,
        [string]$description
    ) {
        $this.id = $id
        $this.type = $type
        $this.description = $description
        $this.Init()
    }
    hidden Init() {
        $this.internal = $true
        $this.aliases = [List[string]]::new()
        $this.shortcut = [string]::Empty
        $this.multiSupport = $false
        $this.predicate = { $true }
    }
    hidden CopyProperties([object]$clone) {
        $properties = Get-Member -InputObject $this -MemberType Property
        foreach ($property in $properties) {
            $clone.$($property.Name) = $this.$($property.Name)
        }
    }
    [object]Clone() {
        $clone = [Command]::new()
        $this.CopyProperties($clone)
        return $clone
    }
}

class ExternalCommand : Command {
    [string]$predicate
    [string]$expression
    ExternalCommand() : base() {
        $this.internal = $false
        $this.predicate = "`$true"
    }
    [object]Clone() {
        $clone = [ExternalCommand]::new()
        $this.CopyProperties($clone)
        return $clone
    }
}

class Extensions {
    [List[ExternalCommand]]$commands
}

& {
    $script:s_commands = [List[Command]]::new()
    #region command help
    & {
        $command = [Command]::new("help", [CommandType]::common, "print help")
        $command.shortcut = "f1"
        $command.expression = {
            $help = [PSCustomObject]@{
                "enter" = "enter directory / open file"
                "left"  = "go to parent directory"
                "right" = "enter directory"
                "f5"    = "refresh directory"
                "tab"   = "mark for multiple selection"
                ":"     = "select command"
            }
            $outStr = $help | Format-List | Out-String
            $helpStr = $outStr.TrimEnd()
            "usage:"
            $helpStr
            $null = [System.Console]::ReadKey($true)
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command quit
    & {
        $command = [Command]::new("quit", [CommandType]::common, "quit explorer")
        $command.aliases = ("exit")
        $command.shortcut = "ctrl-q"
        $command.expression = {
            $script:s_continue = $false
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command set
    & {
        $command = [Command]::new("set", [CommandType]::common, "change setting")
        $command.expression = {
            ChangeSetting
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command new
    & {
        $command = [Command]::new("new", [CommandType]::common, "create new file")
        $command.aliases = ("touch")
        $command.expression = {
            New-Item -ItemType File
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command mkdir
    & {
        $command = [Command]::new("mkdir", [CommandType]::common, "create new directory")
        $command.expression = {
            New-Item -ItemType Directory
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command fd
    & {
        $command = [Command]::new("fd", [CommandType]::common, "find file/directory")
        $command.aliases = ("find")
        $command.shortcut = "ctrl-p"
        $command.expression = {
            $fzfParams = [List[string]]("--height=80%", "--prompt=:${PSItem} ")
            if ($s_settings.preview) {
                $pwshParams = ($s_tempSettingsFile, "preview", "{}")
                $fzfParams.Add("--preview=pwsh ${s_pwshDefaultParams} ${pwshParams}")
            }
            if ($s_settings.cyclic) {
                $fzfParams.Add("--cycle")
            }
            if (IsProgramInstalled "fd") {
                $fdParams = ("--color=always")
                $fzfParams.Add("--ansi")
                $output = fd $fdParams | fzf $s_fzfDefaultParams $fzfParams
            }
            else {
                $output = fzf $s_fzfDefaultParams $fzfParams
            }
            if ($LASTEXITCODE -eq 0) {
                if ($env:EDITOR) {
                    & $env:EDITOR $output
                }
                else {
                    $output
                }
            }
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command rg
    & {
        $command = [Command]::new("rg", [CommandType]::common, "search files contents")
        $command.aliases = ("grep", "search")
        $command.expression = {
            $fzfParams = [List[string]](
                "--height=80%",
                "--prompt=:${PSItem} ",
                "--delimiter=:",
                "--ansi",
                "--phony"
            )
            if ($s_settings.preview) {
                $pwshParams = ($s_tempSettingsFile, "preview", "{1}", "{2}")
                $fzfParams.AddRange(
                    [List[string]](
                        "--preview=pwsh ${s_pwshDefaultParams} ${pwshParams}",
                        "--preview-window=+{2}-/2"
                    )
                )
            }
            if ($s_settings.cyclic) {
                $fzfParams.Add("--cycle")
            }
            if (IsProgramInstalled "rg") {
                $rgParams = [List[string]]("--line-number", "--no-heading", "--color=always", "--smart-case")
                $initParams = [List[string]]::new($rgParams)
                $initParams.Add('""')
                $reloadParams = [List[string]]::new($rgParams)
                $reloadParams.Add("{q}")
                $fzfParams.Add("--bind=change:reload:rg ${reloadParams}")
                $output = rg $initParams | fzf $s_fzfDefaultParams $fzfParams
            }
            else {
                $pwshParams = ($s_tempSettingsFile, "search", "{q}")
                $fzfParams.Add("--bind=change:reload:pwsh ${s_pwshDefaultParams} ${pwshParams}")
                $output = $null | fzf $s_fzfDefaultParams $fzfParams
            }
            if ($LASTEXITCODE -eq 0) {
                $fields = $output.Split(':')
                $fileName = $fields[0]
                if ($env:EDITOR) {
                    & $env:EDITOR $fileName
                }
                else {
                    $fileName
                }
            }
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command mark
    & {
        $command = [Command]::new("mark", [CommandType]::common, "add current path in bookmark")
        $command.predicate = {
            return (-not $s_register.bookmark.Contains($PWD.ToString()))
        }
        $command.expression = {
            $s_register.bookmark.Add($PWD.ToString())
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command unmark
    & {
        $command = [Command]::new("unmark", [CommandType]::common, "remove current path in bookmark")
        $command.predicate = {
            return $s_register.bookmark.Contains($PWD.ToString())
        }
        $command.expression = {
            $null = $s_register.bookmark.Remove($PWD.ToString())
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command jump
    & {
        $command = [Command]::new("jump", [CommandType]::common, "go to path in bookmark")
        $command.shortcut = "ctrl-j"
        $command.expression = {
            $fzfParams = [List[string]]("--height=40%", "--prompt=:${PSItem} ")
            if ($s_settings.preview) {
                $pwshParams = ($s_tempSettingsFile, "preview", "{}")
                $fzfParams.Add("--preview=pwsh ${s_pwshDefaultParams} ${pwshParams}")
            }
            if ($s_settings.cyclic) {
                $fzfParams.Add("--cycle")
            }
            $location = $s_register.bookmark | fzf $s_fzfDefaultParams $fzfParams
            if ($LASTEXITCODE -eq 0) {
                Set-Location $location
            }
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command cp
    & {
        $command = [Command]::new("cp", [CommandType]::file, "mark '{0}' for copy")
        $command.aliases = ("copy")
        $command.multiSupport = $true
        $command.expression = {
            $s_register.clipboard = $selectedFiles
            $s_register.clipMode = [ClipboardMode]::Copy
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command mv
    & {
        $command = [Command]::new("mv", [CommandType]::file, "mark '{0}' for move")
        $command.aliases = ("move", "cut")
        $command.multiSupport = $true
        $command.expression = {
            $s_register.clipboard = $selectedFiles
            $s_register.clipMode = [ClipboardMode]::Cut
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command ln
    & {
        $command = [Command]::new("ln", [CommandType]::file, "mark '{0}' for link")
        $command.aliases = ("link")
        $command.multiSupport = $true
        $command.expression = {
            $s_register.clipboard = $selectedFiles
            $s_register.clipMode = [ClipboardMode]::Link
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command rm
    & {
        $command = [Command]::new("rm", [CommandType]::file, "remove '{0}'")
        $command.aliases = ("remove", "del")
        $command.shortcut = "del"
        $command.multiSupport = $true
        $command.expression = {
            Remove-Item -Path $selectedFiles -Recurse -Force -Confirm
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command ren
    & {
        $command = [Command]::new("ren", [CommandType]::file, "rename '{0}'")
        $command.shortcut = "f2"
        $command.expression = {
            Rename-Item -Path $selectedFiles[0]
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command duplicate
    & {
        $command = [Command]::new("duplicate", [CommandType]::file, "duplicate '{0}'")
        $command.multiSupport = $true
        $command.expression = {
            foreach ($selectedFile in $selectedFiles) {
                $baseName = $selectedFile.BaseName
                $destinationName = [string]::Format("{0} copy{1}", $baseName, $selectedFile.Extension)
                $index = 1
                while ([System.IO.File]::Exists([System.IO.Path]::Join($PWD, $destinationName))) {
                    $destinationName = [string]::Format("{0} copy {1}{2}", $baseName, ++$index, $selectedFile.Extension)
                }
                Copy-Item -Path $selectedFile -Destination $destinationName
            }
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command edit
    & {
        $command = [Command]::new("edit", [CommandType]::file, "open '{0}' with editor")
        $command.shortcut = "ctrl-e"
        $command.predicate = {
            return (-not [string]::IsNullOrEmpty($env:EDITOR))
        }
        $command.expression = {
            & $env:EDITOR $selectedFiles[0].Name
        }
        $s_commands.Add($command)
    }
    #endregion
    #region command paste
    & {
        $command = [Command]::new("paste", [CommandType]::common, "paste files in current directory")
        $command.predicate = {
            return ($s_register.clipboard.Count -gt 0)
        }
        $command.expression = {
            switch ($s_register.clipMode) {
                ([ClipboardMode]::Copy) {
                    Copy-Item -Path $s_register.clipboard -Recurse
                    break
                }
                ([ClipboardMode]::Cut) {
                    Move-Item -Path $s_register.clipboard
                    $s_register.clipboard.Clear()
                    $s_register.clipMode = [ClipboardMode]::None
                    break
                }
                ([ClipboardMode]::Link) {
                    foreach ($item in $s_register.clipboard) {
                        New-Item -ItemType SymbolicLink -Path $item.Name -Target $item.FullName
                    }
                    $s_register.clipboard.Clear()
                    $s_register.clipMode = [ClipboardMode]::None
                    break
                }
                ([ClipboardMode]::None) {}
                Default {}
            }
        }
        $s_commands.Add($command)
    }
    #endregion
}

function ListCommands {
    param (
        [string]$shortcut,
        [List[System.IO.FileSystemInfo]]$selectedFiles
    )
    $commands = [List[Command]]::new()
    foreach ($command in $s_commands) {
        if ($command.internal) {
            $predicateResult = Invoke-Command $command.predicate
        }
        else {
            $expression = [scriptblock]::Create($command.predicate)
            $predicateResult = Invoke-Command $expression
        }
        if (-not $predicateResult) {
            continue
        }
        if ($command.type.Equals([CommandType]::file.ToString())) {
            if ($selectedFiles.Count -eq 0) {
                continue
            }
            if (($selectedFiles.Count -eq 1) -or $command.multiSupport) {
                $names = & {
                    $names = [List[string]]::new()
                    foreach ($selectedFile in $selectedFiles) {
                        $names.Add($selectedFile.Name)
                    }
                    [string]::Join(';', $names)
                }
                $fileCommand = $command.Clone()
                $fileCommand.description = [string]::Format($command.description, $names)
                $commands.Add($fileCommand)
            }
        }
        else {
            $commands.Add($command)
        }
    }
    $commandId = [string]::Empty
    if ($shortcut) {
        $command = $commands.Find({ param($item) $item.shortcut.Equals($shortcut) })
        if ($command) {
            $commandId = $command.id
        }
        return $commandId
    }
    $displays = [List[string]]::new()
    foreach ($command in $commands) {
        $ids = [List[string]]::new()
        $ids.Add($command.id)
        $ids.AddRange($command.aliases)
        foreach ($id in $ids) {
            $display = [string]::Format("{0,-15} : {1}", "[${id}]", $command.description)
            if ($command.shortcut) {
                $display += [string]::Format(" <{0}>", (FormatColor $command.shortcut -FgColor $s_colors.shortcut))
            }
            $displays.Add($display)
        }
    }
    $fzfParams = ("--height=40%", "--nth=1", "--prompt=:", "--exact", "--ansi")
    if ($s_settings.cyclic) {
        $fzfParams.Add("--cycle")
    }
    $output = $displays | fzf $s_fzfDefaultParams $fzfParams
    if ($LASTEXITCODE -eq 0) {
        $match = [regex]::Match($output, "^\[(?<commandId>\w+)\]")
        $commandId = $match.Groups["commandId"].Value
    }
    return $commandId
}

function ProcessCommand {
    param (
        [string]$commandId,
        [List[System.IO.FileSystemInfo]]$selectedFiles
    )
    $command = $s_commands.Find({ param($item) $item.id.Equals($commandId) -or $item.aliases.Contains($commandId) })
    if ($command.internal) {
        Invoke-Command $command.expression
    }
    else {
        if ($command.type.Equals([CommandType]::file.ToString())) {
            foreach ($selectedFile in $selectedFiles) {
                $expression = [scriptblock]::Create([string]::Format($command.expression, $selectedFile.Name))
                Invoke-Command $expression
            }
        }
        else {
            $expression = [scriptblock]::Create($command.expression)
            Invoke-Command $expression
        }
    }
}
