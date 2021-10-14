$sharedFile = Join-Path -Path $PSScriptRoot -ChildPath "shared.ps1"
. $sharedFile

$helperFile = Join-Path -Path $PSScriptRoot -ChildPath "helper.ps1"
$settingsFile = Join-Path -Path $PSScriptRoot -ChildPath "settings.json"
$extensionsFile = Join-Path -Path $PSScriptRoot -ChildPath "extensions.json"
$bookmarkFile = Join-Path -Path $PSScriptRoot -ChildPath "bookmark.json"
$fzfDefaultParams = @("--layout=reverse", "--border", "--info=inline")

enum ClipboardMode {
    None
    Cut
    Copy
    Link
}

function ListDirectory {
    $result = [PSCustomObject]@{
        operation    = [string]::Empty
        selectedFile = $null
    }
    $entries = & {
        $entries = GetDirHeader | ForEach-Object { @{ name = [string]::Empty; details = $PSItem; display = $PSItem } }
        $entries += & {
            $item = Get-Item . -Force
            $outstr = $item | Format-Table -HideTableHeaders | Out-String
            $fields = $outstr -split [System.Environment]::NewLine
            $name = $item.Name.Replace("\", "\\")
            $row = $fields[3] -replace "(.+)${name}", "`$1.."
            $display = ColorizeRows $item $row
            @{ name = ".."; details = $row; display = $display }
        }
        $items = & {
            $attributes = GetDirAttributes
            $items = Get-ChildItem -Force -Attributes $attributes
            $items = SortDir $items
            $items
        }
        $rows = [string[]](GetDirRows $items)
        $displays = [string[]](ColorizeRows $items $rows)
        $entries += for ($i = 0; $i -lt $items.Count; $i++) {
            @{ name = $items[$i].Name; details = $rows[$i]; display = $displays[$i] }
        }
        $entries
    }
    $location = & {
        $location = $PWD.ToString()
        $location = $location.Replace($HOME, "~")
        if ($location.Length -gt 80) {
            $location = "..." + ($location[-80..-1] -join "")
        }
        $location
    }
    $expect = & {
        $expect = "left,right,:,f5"
        $internalShortcuts = "ctrl-q,ctrl-e,ctrl-p,ctrl-j,del,f1,f2"
        $expect += ",${internalShortcuts}"
        $externalShortcuts = $extensions.commands.shortcut.Where( { $PSItem } ) -join ","
        if ($externalShortcuts) {
            $expect += ",${externalShortcuts}"
        }
        $expect
    }
    $fzfParams = @(
        "--height=80%",
        "--header-lines=2",
        "--nth=3..",
        "--delimiter=\s{2,}\d*\s",
        "--prompt=${location}> ",
        "--ansi",
        "--expect=${expect}"
    )
    if ($settings.preview) {
        $fzfParams += "--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {3..}"
    }
    $output = $entries.display | fzf $fzfDefaultParams $fzfParams
    if ($LASTEXITCODE -eq 0) {
        if (-not $output[0]) {
            $output[0] = "enter"
        }
        $entry = $entries.Where( { $PSItem.details -eq $output[1] } )
        $result.operation = $output[0]
        if (($entry.name -ne "..") -or ($output[0] -ne ":")) {
            $result.selectedFile = Get-Item $entry.name -Force
        }
    }
    else {
        $result.operation = $output
    }
    return $result
}

function ProcessOperation {
    param (
        [string]$operation,
        [System.IO.FileSystemInfo]$selectedFile
    )
    $result = [PSCustomObject]@{
        commandMode = $false
        shortcut    = [string]::Empty
    }
    switch ($operation) {
        "enter" {
            if (-not $selectedFile.PSIsContainer) {
                if ($IsWindows) {
                    Invoke-Item $selectedFile.Name
                }
                elseif ($IsMacOS) {
                    open $selectedFile.Name
                }
            }
        }
        "left" {
            Set-Location ..
            break
        }
        { ("enter", "right") -contains $PSItem } {
            if ($selectedFile.PSIsContainer) {
                Get-ChildItem -Path $selectedFile | Out-Null
                if ($?) {
                    Set-Location $selectedFile
                }
            }
            break
        }
        ":" {
            $result.commandMode = $true
            break
        }
        "f5" {
            break
        }
        Default {
            if ($PSItem) {
                $result.commandMode = $true
                $result.shortcut = $PSItem
            }
            break
        }
    }
    return $result
}

function ListCommands {
    param (
        [string]$shortcut,
        [System.IO.FileSystemInfo]$selectedFile
    )
    $commands = @(
        @{ id = "help"; description = "print help"; shortcut = "f1" }
        @{ id = ("quit", "exit"); description = "quit explorer"; shortcut = "ctrl-q" }
        @{ id = "set"; description = "change setting" }
        @{ id = ("new", "touch"); description = "create new file" }
        @{ id = "mkdir"; description = "create new directory" }
        @{ id = ("fd", "find"); description = "find file/directory"; shortcut = "ctrl-p" }
        @{ id = ("rg", "grep", "search"); description = "search files contents" }
        @{ id = "jump"; description = "go to path in bookmark"; shortcut = "ctrl-j" }
    )
    if ($register.bookmark.Contains($PWD.ToString())) {
        $commands += @{ id = "unmark"; description = "remove current path in bookmark" }
    }
    else {
        $commands += @{ id = "mark"; description = "add current path in bookmark" }
    }
    $commands += $extensions.commands.Where( { $PSItem.type -eq "common" } )
    if ($selectedFile) {
        $fileCommands = & {
            $fileCommands = @(
                @{ id = ("cp", "copy"); description = "mark '{0}' for copy" }
                @{ id = ("mv", "move", "cut"); description = "mark '{0}' for move" }
                @{ id = ("ln", "link"); description = "mark '{0}' for link" }
                @{ id = ("rm", "remove", "del"); description = "remove '{0}'"; shortcut = "del" }
                @{ id = "ren"; description = "rename '{0}'"; shortcut = "f2" }
            )
            if ($env:EDITOR) {
                $fileCommands += @{ id = "edit"; description = "open '{0}' with editor"; shortcut = "ctrl-e" }
            }
            $fileCommands += $extensions.commands.Where( { $PSItem.type -eq "file" } )
            $fileCommands
        }
        $commands += foreach ($command in $fileCommands) {
            $command.description = $command.description -f $selectedFile.Name
            $command
        }
    }
    if ($register.clipboard) {
        $commands += @{ id = "paste"; description = "paste '$($register.clipboard.FullName)' in current directory" }
    }
    if ($shortcut) {
        $command = $commands.Where( { $PSItem.shortcut -eq $shortcut } )
        $commandId = ([string[]]($command.id))[0]
        return $commandId
    }
    $displays = foreach ($command in $commands) {
        $ids = [string[]]($command.id)
        foreach ($id in $ids) {
            $display = "{0,-15} : {1}" -f "[${id}]", $command.description
            if ($command.shortcut) {
                $display += (" <{0}>" -f (FormatColor $command.shortcut -FgColor $colors.shortcut))
            }
            $display
        }
    }
    $fzfParams = @("--height=40%", "--nth=1", "--prompt=:", "--exact", "--ansi")
    $output = $displays | fzf $fzfDefaultParams $fzfParams
    if ($LASTEXITCODE -eq 0) {
        $output -match "^\[(?<commandId>\w+)\]" | Out-Null
        $commandId = $Matches["commandId"]
        return $commandId
    }
}

function ProcessCommand {
    param (
        [string]$commandId,
        [System.IO.FileSystemInfo]$selectedFile
    )
    switch ($commandId) {
        "help" {
            $help = [PSCustomObject]@{
                "enter" = "enter directory / open file"
                "left"  = "go to parent directory"
                "right" = "enter directory"
                "f5"    = "refresh directory"
                ":"     = "select command"
            }
            $outStr = $help | Format-List | Out-String
            $helpStr = $outStr.TrimEnd()
            Write-Host "usage:"
            Write-Host $helpStr
            [System.Console]::ReadKey($true) | Out-Null
            break
        }
        { ("quit", "exit") -contains $PSItem } {
            $script:continue = $false
            break
        }
        "set" {
            ChangeSetting
            break
        }
        { ("new", "touch") -contains $PSItem } {
            New-Item -ItemType File
            break                        
        }
        "mkdir" {
            New-Item -ItemType Directory
            break
        }
        { ("fd", "find") -contains $PSItem } {
            $fzfParams = @("--height=80%", "--prompt=:${PSItem} ")
            if ($settings.preview) {
                $fzfParams += "--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {}"
            }
            if (IsProgramInstalled "fd") {
                $fdParams = @("--color=always")
                $fzfParams += "--ansi"
                $output = fd $fdParams | fzf $fzfDefaultParams $fzfParams
            }
            else {
                $output = fzf $fzfDefaultParams $fzfParams
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
        { ("rg", "grep", "search") -contains $PSItem } {
            $fzfParams = @(
                "--height=80%",
                "--prompt=:${PSItem} ",
                "--delimiter=:",
                "--ansi",
                "--phony"
            )
            if ($settings.preview) {
                $fzfParams += @(
                    "--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {1} {2}",
                    "--preview-window=+{2}-/2"
                )
            }
            if (IsProgramInstalled "rg") {
                $rgParams = @("--line-number", "--no-heading", "--color=always", "--smart-case")
                $initParams = $rgParams + '""'
                $reloadParams = $rgParams + "{q}"
                $fzfParams += "--bind=change:reload:rg ${reloadParams}"
                $initList = rg $initParams
                $output = $initList | fzf $fzfDefaultParams $fzfParams
            }
            else {
                $fzfParams += "--bind=change:reload:pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} search {q}"
                $initList = & $helperFile $tempSettingsFile search
                $output = $initList | fzf $fzfDefaultParams $fzfParams
            }
            if ($LASTEXITCODE -eq 0) {
                $fields = $output -split ":"
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
            $fzfParams = @("--height=40%", "--prompt=:${PSItem} ")
            if ($settings.preview) {
                $fzfParams += "--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {}"
            }
            $location = $register.bookmark | fzf $fzfDefaultParams $fzfParams
            if ($LASTEXITCODE -eq 0) {
                Set-Location $location
            }
            break
        }
        "mark" {
            $register.bookmark.Add($PWD.ToString())
            break
        }
        "unmark" {
            $register.bookmark.Remove($PWD.ToString()) | Out-Null
            break
        }
        "edit" {
            & $env:EDITOR $selectedFile.Name
            break
        }
        { ("cp", "copy") -contains $PSItem } {
            $register.clipboard = $selectedFile
            $register.clipMode = [ClipboardMode]::Copy
            break
        }
        { ("mv", "move", "cut") -contains $PSItem } {
            $register.clipboard = $selectedFile
            $register.clipMode = [ClipboardMode]::Cut
            break
        }
        { ("ln", "link") -contains $PSItem } {
            $register.clipboard = $selectedFile
            $register.clipMode = [ClipboardMode]::Link
            break
        }
        { ("rm", "remove", "del") -contains $PSItem } {
            Remove-Item -Path $selectedFile -Recurse -Force -Confirm
            break
        }
        "ren" {
            Rename-Item -Path $selectedFile
            break
        }
        "paste" {
            switch ($register.clipMode) {
                ([ClipboardMode]::Copy) {
                    Copy-Item -Path $register.clipboard -Destination . -Recurse
                    break
                }
                ([ClipboardMode]::Cut) {
                    Move-Item -Path $register.clipboard -Destination .
                    $register.clipboard = $null
                    $register.clipMode = [ClipboardMode]::None
                    break
                }
                ([ClipboardMode]::Link) {
                    $name = $register.clipboard.Name
                    New-Item -ItemType SymbolicLink -Path $name -Target $register.clipboard.FullName
                    $register.clipboard = $null
                    $register.clipMode = [ClipboardMode]::None
                    break
                }
                ([ClipboardMode]::None) {}
                Default {}
            }
            break
        }
        Default {
            $externalCommand = $extensions.commands.Where( { [string[]]($PSItem.id) -contains $commandId } )
            if ($externalCommand) {
                $expression = $externalCommand.expression
                if ($externalCommand.type -eq "file") {
                    $expression = $expression -f $selectedFile.Name
                }
                Invoke-Expression $expression
            }
        }
    }
}

function ChangeSetting {
    $entries = & {
        $entries = @(
            @{ id = "preview"; description = "show preview window on" }
            @{ id = "nopreview"; description = "show preview window off" }
            @{ id = "hidden"; description = "show hidden files on" }
            @{ id = "nohidden"; description = "show hidden files off" }
        )
        $sortEntries = @(
            @{ id = "default"; description = "sort by default" }
            @{ id = "nameasc"; description = "sort by name ascending" }
            @{ id = "namedesc"; description = "sort by name descending" }
            @{ id = "sizeasc"; description = "sort by size ascending" }
            @{ id = "sizedesc"; description = "sort by size descending" }
            @{ id = "timeasc"; description = "sort by time ascending" }
            @{ id = "timedesc"; description = "sort by time descending" }
        )
        $entries += foreach ($entry in $sortEntries) {
            $entry.id = "sort=$($entry.id)"
            $entry
        }
        if ($env:EDITOR) {
            $entries += @{ id = "all"; description = "edit settings file" }
        }
        $entries
    }
    $displays = foreach ($entry in $entries) {
        "{0,-15} : {1}" -f "[$($entry.id)]", $entry.description
    }
    $fzfParams = @("--height=40%", "--prompt=:${PSItem} ", "--exact")
    $output = $displays | fzf $fzfDefaultParams $fzfParams
    if ($LASTEXITCODE -ne 0) {
        return
    }
    $output -match "^\[(?<entryId>\w+)\]" | Out-Null
    $entryId = $Matches["entryId"]
    switch ($entryId) {
        { $PSItem.EndsWith("preview") } {
            $settings.preview = -not $PSItem.StartsWith("no")
            break
        }
        { $PSItem.EndsWith("hidden") } {
            $settings.showHidden = -not $PSItem.StartsWith("no")
            break
        }
        { $PSItem.StartsWith("sort") } {
            $PSItem -match "sort=(?<sortBy>\w+)" | Out-Null
            $settings.sortBy = $Matches["sortBy"]
            break
        }
        "all" {
            & $env:EDITOR $settingsFile
            break
        }
        Default {}
    }
    $settings | ConvertTo-Json | Out-File -FilePath $tempSettingsFile
}

function Initialize {
    $script:register = [PSCustomObject]@{
        clipboard = $null
        clipMode  = [ClipboardMode]::None
        bookmark  = [System.Collections.Generic.List[string]]@()
    }
    if (Test-Path -Path $bookmarkFile) {
        $register.bookmark = [System.Collections.Generic.List[string]](Get-Content $bookmarkFile | ConvertFrom-Json)
    }
    $script:settings = Get-Content $settingsFile | ConvertFrom-Json
    $script:extensions = Get-Content $extensionsFile | ConvertFrom-Json
    $script:tempSettingsFile = New-TemporaryFile
    Copy-Item -Path $settingsFile -Destination $tempSettingsFile -Force
    $script:continue = $true
}

function Finalize {
    $register.bookmark | ConvertTo-Json | Out-File -FilePath $bookmarkFile
    Remove-Item -Path $tempSettingsFile -Force
}

function FuzzyExplorer {
    Initialize
    while ($continue) {
        $result = ListDirectory
        $operation = $result.operation
        $selectedFile = $result.selectedFile
        $result = ProcessOperation $operation $selectedFile
        $commandMode = $result.commandMode
        $shortcut = $result.shortcut
        if ($commandMode) {
            $commandId = ListCommands $shortcut $selectedFile
            ProcessCommand $commandId $selectedFile
        }
    }
    Finalize
}

if (IsProgramInstalled "fzf") {
    FuzzyExplorer
}
else {
    Write-Error "fzf not installed!" -Category NotInstalled
}
