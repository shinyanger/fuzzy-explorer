using namespace System.Collections.Generic

class Command {
    [string]$id
    [List[string]]$aliases
    [string]$description
    [string]$shortcut
    Command() {
        $this.aliases = [List[string]]::new()
        $this.shortcut = [string]::Empty
    }
    Command(
        [string]$id,
        [List[string]]$aliases,
        [string]$description,
        [string]$shortcut
    ) {
        $this.id = $id
        $this.aliases = $aliases
        $this.description = $description
        $this.shortcut = $shortcut
    }
}

class FileCommand : Command {
    [bool]$multiSupport
    FileCommand() : base() {
        $this.multiSupport = $false
    }
    FileCommand(
        [string]$id,
        [List[string]]$aliases,
        [string]$description,
        [string]$shortcut,
        [bool]$multiSupport
    ) : base($id, $aliases, $description, $shortcut) {
        $this.multiSupport = $multiSupport
    }
}

class ExternalCommand : FileCommand, System.ICloneable {
    [string]$type
    [string]$expression
    [object]Clone() {
        $clone = [ExternalCommand]::new()
        $properties = Get-Member -InputObject $this -MemberType Property
        foreach ($property in $properties) {
            $clone.$($property.Name) = $this.$($property.Name)
        }
        return $clone
    }
}

class Extensions {
    [List[ExternalCommand]]$commands
}

function ListCommands {
    param (
        [string]$shortcut,
        [List[System.IO.FileSystemInfo]]$selectedFiles
    )
    if (-not $s_commands) {
        $script:s_commands = [List[Command]](
            [Command]::new("help", [List[string]]::new(), "print help", "f1"),
            [Command]::new("quit", [List[string]]("exit"), "quit explorer", "ctrl-q"),
            [Command]::new("set", [List[string]]::new(), "change setting", [string]::Empty),
            [Command]::new("new", [List[string]]("touch"), "create new file", [string]::Empty),
            [Command]::new("mkdir", [List[string]]::new(), "create new directory", [string]::Empty),
            [Command]::new("fd", [List[string]]("find"), "find file/directory", "ctrl-p"),
            [Command]::new("rg", [List[string]]("grep", "search"), "search files contents", [string]::Empty),
            [Command]::new("jump", [List[string]]::new(), "go to path in bookmark", "ctrl-j")
        )
    }
    $commands = [List[Command]]::new($s_commands)
    if ($s_register.bookmark.Contains($PWD.ToString())) {
        $commands.Add([Command]::new("unmark", [List[string]]::new(), "remove current path in bookmark", [string]::Empty))
    }
    else {
        $commands.Add([Command]::new("mark", [List[string]]::new(), "add current path in bookmark", [string]::Empty))
    }
    foreach ($command in $s_extensions.commands) {
        if ($command.type.Equals("common")) {
            $commands.Add($command)
        }
    }
    if ($selectedFiles.Count -gt 0) {
        $fileCommands = & {
            $fileCommands = [List[FileCommand]](
                [FileCommand]::new("cp", [List[string]]("copy"), "mark '{0}' for copy", [string]::Empty, $true),
                [FileCommand]::new("mv", [List[string]]("move", "cut"), "mark '{0}' for move", [string]::Empty, $true),
                [FileCommand]::new("ln", [List[string]]("link"), "mark '{0}' for link", [string]::Empty, $true),
                [FileCommand]::new("rm", [List[string]]("remove", "del"), "remove '{0}'", "del", $true),
                [FileCommand]::new("ren", [List[string]]::new(), "rename '{0}'", "f2", $false),
                [FileCommand]::new("duplicate", [List[string]]::new(), "duplicate '{0}'", [string]::Empty, $true)
            )
            if ($env:EDITOR) {
                $fileCommands.Add([FileCommand]::new("edit", [List[string]]::new(), "open '{0}' with editor", "ctrl-e", $false))
            }
            foreach ($command in $s_extensions.commands) {
                if ($command.type.Equals("file")) {
                    $fileCommands.Add($command.Clone())
                }
            }
            $fileCommands
        }
        foreach ($command in $fileCommands) {
            if (($selectedFiles.Count -eq 1) -or $command.multiSupport) {
                $names = & {
                    $names = [List[string]]::new()
                    foreach ($selectedFile in $selectedFiles) {
                        $names.Add($selectedFile.Name)
                    }
                    [string]::Join(';', $names)
                }
                $command.description = [string]::Format($command.description, $names)
                $commands.Add($command)
            }
        }
    }
    if ($s_register.clipboard.Count -gt 0) {
        if ($s_register.clipboard.Count -gt 1) {
            $name = [string]::Format("<{0} files>", $s_register.clipboard.Count)
        }
        else {
            $name = $s_register.clipboard[0].FullName
        }
        $commands.Add([Command]::new("paste", [List[string]]::new(), "paste '${name}' in current directory", [string]::Empty))
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
    switch ($commandId) {
        "help" {
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
            break
        }
        { ([List[string]]("quit", "exit")).Contains($PSItem) } {
            $script:s_continue = $false
            break
        }
        "set" {
            ChangeSetting
            break
        }
        { ([List[string]]("new", "touch")).Contains($PSItem) } {
            New-Item -ItemType File
            break                        
        }
        "mkdir" {
            New-Item -ItemType Directory
            break
        }
        { ([List[string]]("fd", "find")).Contains($PSItem) } {
            $fzfParams = [List[string]]("--height=80%", "--prompt=:${PSItem} ")
            if ($s_settings.preview) {
                $fzfParams.Add("--preview=pwsh -NoProfile -File ${s_helperFile} ${s_tempSettingsFile} preview {}")
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
            break
        }
        { ([List[string]]("rg", "grep", "search")).Contains($PSItem) } {
            $fzfParams = [List[string]](
                "--height=80%",
                "--prompt=:${PSItem} ",
                "--delimiter=:",
                "--ansi",
                "--phony"
            )
            if ($s_settings.preview) {
                $fzfParams.AddRange(
                    [List[string]](
                        "--preview=pwsh -NoProfile -File ${s_helperFile} ${s_tempSettingsFile} preview {1} {2}",
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
                $fzfParams.Add("--bind=change:reload:pwsh -NoProfile -File ${s_helperFile} ${s_tempSettingsFile} search {q}")
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
            break
        }
        "jump" {
            $fzfParams = [List[string]]("--height=40%", "--prompt=:${PSItem} ")
            if ($s_settings.preview) {
                $fzfParams.Add("--preview=pwsh -NoProfile -File ${s_helperFile} ${s_tempSettingsFile} preview {}")
            }
            if ($s_settings.cyclic) {
                $fzfParams.Add("--cycle")
            }
            $location = $s_register.bookmark | fzf $s_fzfDefaultParams $fzfParams
            if ($LASTEXITCODE -eq 0) {
                Set-Location $location
            }
            break
        }
        "mark" {
            $s_register.bookmark.Add($PWD.ToString())
            break
        }
        "unmark" {
            $null = $s_register.bookmark.Remove($PWD.ToString())
            break
        }
        "edit" {
            & $env:EDITOR $selectedFiles[0].Name
            break
        }
        { ([List[string]]("cp", "copy")).Contains($PSItem) } {
            $s_register.clipboard = $selectedFiles
            $s_register.clipMode = [ClipboardMode]::Copy
            break
        }
        { ([List[string]]("mv", "move", "cut")).Contains($PSItem) } {
            $s_register.clipboard = $selectedFiles
            $s_register.clipMode = [ClipboardMode]::Cut
            break
        }
        { ([List[string]]("ln", "link")).Contains($PSItem) } {
            $s_register.clipboard = $selectedFiles
            $s_register.clipMode = [ClipboardMode]::Link
            break
        }
        { ([List[string]]("rm", "remove", "del")).Contains($PSItem) } {
            Remove-Item -Path $selectedFiles -Recurse -Force -Confirm
            break
        }
        "ren" {
            Rename-Item -Path $selectedFiles[0]
            break
        }
        "duplicate" {
            foreach ($selectedFile in $selectedFiles) {
                $baseName = $selectedFile.BaseName
                $destinationName = [string]::Format("{0} copy{1}", $baseName, $selectedFile.Extension)
                $index = 1
                while ([System.IO.File]::Exists([System.IO.Path]::Join($PWD, $destinationName))) {
                    $destinationName = [string]::Format("{0} copy {1}{2}", $baseName, ++$index, $selectedFile.Extension)
                }
                Copy-Item -Path $selectedFile -Destination $destinationName
            }
            break
        }
        "paste" {
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
            break
        }
        Default {
            $command = $s_extensions.commands.Find({ param($item) $item.id.Equals($commandId) -or $item.aliases.Contains($commandId) })
            if ($command.type.Equals("file")) {
                foreach ($selectedFile in $selectedFiles) {
                    $expression = [string]::Format($command.expression, $selectedFile.Name)
                    Invoke-Expression $expression
                }
            }
            else {
                $expression = $command.expression
                Invoke-Expression $expression
            }
        }
    }
}
