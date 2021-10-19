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
        operation     = [string]::Empty
        selectedFiles = @()
    }
    . {
        $entries = [System.Collections.Generic.List[hashtable]]@()
        if ($settings.showDetails) {
            $rows = GetDirHeader
            foreach ($row in $rows) {
                $entries.Add( @{ name = [string]::Empty; details = $row; display = $row } )
            }
        }
        . {
            $item = Get-Item . -Force
            $row = ".."
            if ($settings.showDetails) {
                $outstr = $item | Format-Table -HideTableHeaders | Out-String
                $fields = $outstr -split [System.Environment]::NewLine
                $index = $fields[3].LastIndexOf($item.Name)
                $row = $fields[3].Substring(0, $index) + ".."
            }
            $display = ColorizeRows $item $row
            $entries.Add( @{ name = ".."; details = $row; display = $display } )
        }
        . {
            $attributes = GetDirAttributes
            $items = Get-ChildItem -Force -Attributes $attributes
            $items = SortDir $items
        }
        $rows = [string[]](GetDirRows $items)
        $displays = [string[]](ColorizeRows $items $rows)
        for ($i = 0; $i -lt $items.Count; $i++) {
            $entries.Add( @{ name = $items[$i].Name; details = $rows[$i]; display = $displays[$i] } )
        }
    }
    . {
        $location = $PWD.ToString()
        $location = $location.Replace($HOME, "~")
        if ($location.Length -gt 80) {
            $location = "..." + ($location[-80..-1] -join "")
        }
    }
    . {
        $expect = "left,right,:,f5"
        $internalShortcuts = "ctrl-q,ctrl-e,ctrl-p,ctrl-j,del,f1,f2"
        $expect += ",${internalShortcuts}"
        $externalShortcuts = $extensions.commands.shortcut.Where( { $PSItem } ) -join ","
        if ($externalShortcuts) {
            $expect += ",${externalShortcuts}"
        }
    }
    $fzfParams = [System.Collections.Generic.List[string]]@(
        "--height=80%",
        "--prompt=${location}> ",
        "--multi",
        "--ansi",
        "--expect=${expect}"
    )
    if ($settings.showDetails) {
        $fzfParams.AddRange(
            [System.Collections.Generic.List[string]]@(
                "--header-lines=2",
                "--nth=3..",
                "--delimiter=\s{2,}\d*\s"
            )
        )
        if ($settings.preview) {
            $fzfParams.Add("--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {3..}")
        }
    }
    else {
        if ($settings.preview) {
            $fzfParams.Add("--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {}")
        }
    }
    $output = $entries.display | fzf $fzfDefaultParams $fzfParams
    if ($LASTEXITCODE -eq 0) {
        if (-not $output[0]) {
            $output[0] = "enter"
        }
        $result.operation = $output[0]
        $result.selectedFiles = for ($i = 1; $i -lt $output.Count; $i++) {
            $entry = $entries.Where( { $PSItem.details -eq $output[$i] } )
            if (($entry.name -ne "..") -or (("enter", "right") -contains $output[0])) {
                Get-Item $entry.name -Force
            }
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
        [System.IO.FileSystemInfo[]]$selectedFiles
    )
    $result = [PSCustomObject]@{
        commandMode = $false
        shortcut    = [string]::Empty
    }
    switch ($operation) {
        "enter" {
            if ($selectedFiles.Count -eq 1) {
                $selectedFile = $selectedFiles[0]
                if (-not $selectedFile.PSIsContainer) {
                    if ($IsWindows) {
                        Invoke-Item $selectedFile.Name
                    }
                    elseif ($IsMacOS) {
                        open $selectedFile.Name
                    }
                }
            }
        }
        "left" {
            Set-Location ..
            break
        }
        { ("enter", "right") -contains $PSItem } {
            if ($selectedFiles.Count -eq 1) {
                $selectedFile = $selectedFiles[0]
                if ($selectedFile.PSIsContainer) {
                    $null = Get-ChildItem -Path $selectedFile
                    if ($?) {
                        Set-Location $selectedFile
                    }
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
        [System.IO.FileSystemInfo[]]$selectedFiles
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
    if ($selectedFiles) {
        . {
            $fileCommands = @(
                @{ id = ("cp", "copy"); description = "mark '{0}' for copy"; multiSupport = $true }
                @{ id = ("mv", "move", "cut"); description = "mark '{0}' for move"; multiSupport = $true }
                @{ id = ("ln", "link"); description = "mark '{0}' for link"; multiSupport = $true }
                @{ id = ("rm", "remove", "del"); description = "remove '{0}'"; shortcut = "del"; multiSupport = $true }
                @{ id = "ren"; description = "rename '{0}'"; shortcut = "f2" }
                @{ id = "duplicate"; description = "duplicate '{0}'"; multiSupport = $true }
            )
            if ($env:EDITOR) {
                $fileCommands += @{ id = "edit"; description = "open '{0}' with editor"; shortcut = "ctrl-e" }
            }
            $fileCommands += foreach ($command in $extensions.commands.Where( { $PSItem.type -eq "file" } )) {
                $command.PSObject.Copy()
            }
        }
        $commands += foreach ($command in $fileCommands) {
            if (($selectedFiles.Count -eq 1) -or $command.multiSupport) {
                $names = $selectedFiles.Name -join ";"
                $command.description = $command.description -f $names
                $command
            }
        }
    }
    if ($register.clipboard) {
        if ($register.clipboard.Count -gt 1) {
            $name = "<$($register.clipboard.Count) files>"
        }
        else {
            $name = $register.clipboard[0].FullName
        }
        $commands += @{ id = "paste"; description = "paste '${name}' in current directory" }
    }
    $commandId = [string]::Empty
    if ($shortcut) {
        $command = $commands.Where( { $PSItem.shortcut -eq $shortcut } )
        if ($command) {
            $commandId = ([string[]]($command.id))[0]
        }
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
        $null = $output -match "^\[(?<commandId>\w+)\]"
        $commandId = $Matches["commandId"]
    }
    return $commandId
}

function ProcessCommand {
    param (
        [string]$commandId,
        [System.IO.FileSystemInfo[]]$selectedFiles
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
            Write-Host "usage:"
            Write-Host $helpStr
            $null = [System.Console]::ReadKey($true)
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
            $fzfParams = [System.Collections.Generic.List[string]]@("--height=80%", "--prompt=:${PSItem} ")
            if ($settings.preview) {
                $fzfParams.Add("--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {}")
            }
            if (IsProgramInstalled "fd") {
                $fdParams = @("--color=always")
                $fzfParams.Add("--ansi")
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
            $fzfParams = [System.Collections.Generic.List[string]]@(
                "--height=80%",
                "--prompt=:${PSItem} ",
                "--delimiter=:",
                "--ansi",
                "--phony"
            )
            if ($settings.preview) {
                $fzfParams.AddRange(
                    [System.Collections.Generic.List[string]]@(
                        "--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {1} {2}",
                        "--preview-window=+{2}-/2"
                    )
                )
            }
            if (IsProgramInstalled "rg") {
                $rgParams = @("--line-number", "--no-heading", "--color=always", "--smart-case")
                $initParams = $rgParams + '""'
                $reloadParams = $rgParams + "{q}"
                $fzfParams.Add("--bind=change:reload:rg ${reloadParams}")
                $initList = rg $initParams
                $output = $initList | fzf $fzfDefaultParams $fzfParams
            }
            else {
                $fzfParams.Add("--bind=change:reload:pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} search {q}")
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
            $fzfParams = [System.Collections.Generic.List[string]]@("--height=40%", "--prompt=:${PSItem} ")
            if ($settings.preview) {
                $fzfParams.Add("--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {}")
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
            $null = $register.bookmark.Remove($PWD.ToString())
            break
        }
        "edit" {
            & $env:EDITOR $selectedFiles[0].Name
            break
        }
        { ("cp", "copy") -contains $PSItem } {
            $register.clipboard = $selectedFiles
            $register.clipMode = [ClipboardMode]::Copy
            break
        }
        { ("mv", "move", "cut") -contains $PSItem } {
            $register.clipboard = $selectedFiles
            $register.clipMode = [ClipboardMode]::Cut
            break
        }
        { ("ln", "link") -contains $PSItem } {
            $register.clipboard = $selectedFiles
            $register.clipMode = [ClipboardMode]::Link
            break
        }
        { ("rm", "remove", "del") -contains $PSItem } {
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
                $destinationName = "{0} copy{1}" -f $baseName, $selectedFile.Extension
                $index = 1
                while (Test-Path -Path (Join-Path -Path $PWD -ChildPath $destinationName)) {
                    $destinationName =  "{0} copy {1}{2}" -f $baseName, ++$index, $selectedFile.Extension
                }
                Copy-Item -Path $selectedFile -Destination $destinationName
            }
            break
        }
        "paste" {
            switch ($register.clipMode) {
                ([ClipboardMode]::Copy) {
                    Copy-Item -Path $register.clipboard -Recurse
                    break
                }
                ([ClipboardMode]::Cut) {
                    Move-Item -Path $register.clipboard
                    $register.clipboard = $null
                    $register.clipMode = [ClipboardMode]::None
                    break
                }
                ([ClipboardMode]::Link) {
                    foreach ($file in $register.clipboard) {
                        New-Item -ItemType SymbolicLink -Path $file.Name -Target $file.FullName
                    }
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
                if ($externalCommand.type -eq "file") {
                    foreach ($selectedFile in $selectedFiles) {
                        $expression = $externalCommand.expression -f $selectedFile.Name
                        Invoke-Expression $expression
                    }
                }
                else {
                    $expression = $externalCommand.expression
                    Invoke-Expression $expression
                }
            }
        }
    }
}

function ChangeSetting {
    . {
        $entries = @(
            @{ id = "preview"; description = "show preview window on" }
            @{ id = "nopreview"; description = "show preview window off" }
            @{ id = "details"; description = "show directory details on" }
            @{ id = "nodetails"; description = "show directory details off" }
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
    }
    $displays = foreach ($entry in $entries) {
        "{0,-15} : {1}" -f "[$($entry.id)]", $entry.description
    }
    $fzfParams = @("--height=40%", "--prompt=:${PSItem} ", "--exact")
    $output = $displays | fzf $fzfDefaultParams $fzfParams
    if ($LASTEXITCODE -ne 0) {
        return
    }
    $null = $output -match "^\[(?<entryId>\S+)\]"
    $entryId = $Matches["entryId"]
    switch ($entryId) {
        { $PSItem.EndsWith("preview") } {
            $settings.preview = -not $PSItem.StartsWith("no")
            break
        }
        { $PSItem.EndsWith("details") } {
            $settings.showDetails = -not $PSItem.StartsWith("no")
            break
        }
        { $PSItem.EndsWith("hidden") } {
            $settings.showHidden = -not $PSItem.StartsWith("no")
            break
        }
        { $PSItem.StartsWith("sort") } {
            $null = $PSItem -match "sort=(?<sortBy>\w+)"
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
        clipboard = @()
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
        $selectedFiles = $result.selectedFiles
        $result = ProcessOperation $operation $selectedFiles
        $commandMode = $result.commandMode
        $shortcut = $result.shortcut
        if (-not $commandMode) {
            continue
        }
        $commandId = ListCommands $shortcut $selectedFiles
        if ($commandId) {
            ProcessCommand $commandId $selectedFiles
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
