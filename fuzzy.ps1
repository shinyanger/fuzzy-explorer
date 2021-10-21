using namespace System.Collections.Generic
using namespace System.Text.Json

$sharedFile = Join-Path -Path $PSScriptRoot -ChildPath "shared.ps1"
. $sharedFile

$helperFile = Join-Path -Path $PSScriptRoot -ChildPath "helper.ps1"
$settingsFile = Join-Path -Path $PSScriptRoot -ChildPath "settings.json"
$extensionsFile = Join-Path -Path $PSScriptRoot -ChildPath "extensions.json"
$bookmarkFile = Join-Path -Path $PSScriptRoot -ChildPath "bookmark.json"
$fzfDefaultParams = ("--layout=reverse", "--border", "--info=inline")

enum ClipboardMode {
    None
    Cut
    Copy
    Link
}

class Settings {
    [bool]$preview
    [bool]$showDetails
    [bool]$showHidden
    [string]$sortBy
}

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

class DirEntry {
    [string]$name
    [string]$details
    [string]$display
    DirEntry(
        [string]$name,
        [string]$details,
        [string]$display
    ) {
        $this.name = $name
        $this.details = $details
        $this.display = $display
    }
}

class SettingEntry {
    [string]$id
    [string]$description
    SettingEntry(
        [string]$id,
        [string]$description
    ) {
        $this.id = $id
        $this.description = $description
    }
}

function ListDirectory {
    $result = [PSCustomObject]@{
        operation     = [string]::Empty
        selectedFiles = [List[System.IO.FileSystemInfo]]::new()
    }
    $entries = [List[DirEntry]]::new()
    & {
        if ($settings.showDetails) {
            $rows = GetDirHeader
            foreach ($row in $rows) {
                $entries.Add([DirEntry]::new([string]::Empty, $row, $row))
            }
        }
        & {
            $item = Get-Item . -Force
            $row = ".."
            if ($settings.showDetails) {
                $outstr = $item | Format-Table -HideTableHeaders | Out-String
                $fields = $outstr.Split([System.Environment]::NewLine)
                $index = $fields[3].LastIndexOf($item.Name)
                $row = $fields[3].Substring(0, $index) + ".."
            }
            $display = ColorizeRows $item $row
            $entries.Add([DirEntry]::new("..", $row, $display))
        }
        $items = & {
            $attributes = GetDirAttributes
            $items = Get-ChildItem -Force -Attributes $attributes
            SortDir $items
        }
        $rows = [List[string]](GetDirRows $items)
        $displays = [List[string]](ColorizeRows $items $rows)
        for ($i = 0; $i -lt $items.Count; $i++) {
            $entries.Add([DirEntry]::new($items[$i].Name, $rows[$i], $displays[$i]))
        }
    }
    $location = & {
        $location = $PWD.ToString()
        $location = $location.Replace($HOME, "~")
        if ($location.Length -gt 80) {
            $index = $location.Length - 80
            $location = "..." + $location.Substring($index)
        }
        $location
    }
    $expect = & {
        $expect = "left,right,:,f5"
        $internalShortcuts = "ctrl-q,ctrl-e,ctrl-p,ctrl-j,del,f1,f2"
        $expect += ",${internalShortcuts}"
        $externalShortcuts = & {
            $shortcuts = [List[string]]::new()
            foreach ($command in $extensions.commands) {
                if ($command.shortcut) {
                    $shortcuts.Add($command.shortcut)
                }
            }
            [string]::Join(',', $shortcuts)
        }
        if ($externalShortcuts) {
            $expect += ",${externalShortcuts}"
        }
        $expect
    }
    $fzfParams = [List[string]](
        "--height=80%",
        "--prompt=${location}> ",
        "--multi",
        "--ansi",
        "--expect=${expect}"
    )
    if ($settings.showDetails) {
        $fzfParams.AddRange(
            [List[string]](
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
        for ($i = 1; $i -lt $output.Count; $i++) {
            $entry = $entries.Find({ param($item) $item.details.Equals($output[$i]) })
            if ((-not $entry.name.Equals("..")) -or ([List[string]]("enter", "right")).Contains($output[0])) {
                $item = Get-Item $entry.name -Force
                $result.selectedFiles.Add($item)
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
        [List[System.IO.FileSystemInfo]]$selectedFiles
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
        { ([List[string]]("enter", "right")).Contains($PSItem) } {
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
        [List[System.IO.FileSystemInfo]]$selectedFiles
    )
    $commands = [List[Command]](
        [Command]::new("help", [List[string]]::new(), "print help", "f1"),
        [Command]::new("quit", [List[string]]("exit"), "quit explorer", "ctrl-q"),
        [Command]::new("set", [List[string]]::new(), "change setting", [string]::Empty),
        [Command]::new("new", [List[string]]("touch"), "create new file", [string]::Empty),
        [Command]::new("mkdir", [List[string]]::new(), "create new directory", [string]::Empty),
        [Command]::new("fd", [List[string]]("find"), "find file/directory", "ctrl-p"),
        [Command]::new("rg", [List[string]]("grep", "search"), "search files contents", [string]::Empty),
        [Command]::new("jump", [List[string]]::new(), "go to path in bookmark", "ctrl-j")
    )
    if ($register.bookmark.Contains($PWD.ToString())) {
        $commands.Add([Command]::new("unmark", [List[string]]::new(), "remove current path in bookmark", [string]::Empty))
    }
    else {
        $commands.Add([Command]::new("mark", [List[string]]::new(), "add current path in bookmark", [string]::Empty))
    }
    foreach ($command in $extensions.commands) {
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
            foreach ($command in $extensions.commands) {
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
    if ($register.clipboard) {
        if ($register.clipboard.Count -gt 1) {
            $name = [string]::Format("<{0} files>", $register.clipboard.Count)
        }
        else {
            $name = $register.clipboard[0].FullName
        }
        $commands.Add([Command]::new("paste", [List[string]]::new(), "paste '${name}' in current directory", [string]::Empty, $false))
    }
    $commandId = [string]::Empty
    if ($shortcut) {
        $command = $commands.Find({ param($item) $item.shortcut.Equals($shortcut) })
        if ($command) {
            $commandId = $command.id
        }
        return $commandId
    }
    $displays = foreach ($command in $commands) {
        $ids = [List[string]]($command.id)
        $ids.AddRange($command.aliases)
        foreach ($id in $ids) {
            $display = [string]::Format("{0,-15} : {1}", "[${id}]", $command.description)
            if ($command.shortcut) {
                $display += ([string]::Format(" <{0}>", (FormatColor $command.shortcut -FgColor $colors.shortcut)))
            }
            $display
        }
    }
    $fzfParams = ("--height=40%", "--nth=1", "--prompt=:", "--exact", "--ansi")
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
            $script:continue = $false
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
            if ($settings.preview) {
                $fzfParams.Add("--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {}")
            }
            if (IsProgramInstalled "fd") {
                $fdParams = ("--color=always")
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
        { ([List[string]]("rg", "grep", "search")).Contains($PSItem) } {
            $fzfParams = [List[string]](
                "--height=80%",
                "--prompt=:${PSItem} ",
                "--delimiter=:",
                "--ansi",
                "--phony"
            )
            if ($settings.preview) {
                $fzfParams.AddRange(
                    [List[string]](
                        "--preview=pwsh -NoProfile -File ${helperFile} ${tempSettingsFile} preview {1} {2}",
                        "--preview-window=+{2}-/2"
                    )
                )
            }
            if (IsProgramInstalled "rg") {
                $rgParams = ("--line-number", "--no-heading", "--color=always", "--smart-case")
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
                $fields = $output.Split(":")
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
        { ([List[string]]("cp", "copy")).Contains($PSItem) } {
            $register.clipboard = $selectedFiles
            $register.clipMode = [ClipboardMode]::Copy
            break
        }
        { ([List[string]]("mv", "move", "cut")).Contains($PSItem) } {
            $register.clipboard = $selectedFiles
            $register.clipMode = [ClipboardMode]::Cut
            break
        }
        { ([List[string]]("ln", "link")).Contains($PSItem) } {
            $register.clipboard = $selectedFiles
            $register.clipMode = [ClipboardMode]::Link
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
                while (Test-Path -Path (Join-Path -Path $PWD -ChildPath $destinationName)) {
                    $destinationName = [string]::Format("{0} copy {1}{2}", $baseName, ++$index, $selectedFile.Extension)
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
            $externalCommand = $extensions.commands.Find({ param($item) $item.id.Equals($commandId) -or $item.aliases.Contains($commandId) })
            if ($externalCommand) {
                if ($externalCommand.type.Equals("file")) {
                    foreach ($selectedFile in $selectedFiles) {
                        $expression = [string]::Format($externalCommand.expression, $selectedFile.Name)
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
    $entries = & {
        $entries = [List[SettingEntry]](
            [SettingEntry]::new("preview", "show preview window on"),
            [SettingEntry]::new("nopreview", "show preview window off"),
            [SettingEntry]::new("details", "show directory details on"),
            [SettingEntry]::new("nodetails", "show directory details off"),
            [SettingEntry]::new("hidden", "show hidden files on"),
            [SettingEntry]::new("nohidden", "show hidden files off")
        )
        $sortEntries = [List[SettingEntry]](
            [SettingEntry]::new("default", "sort by default"),
            [SettingEntry]::new("nameasc", "sort by name ascending"),
            [SettingEntry]::new("namedesc", "sort by name descending"),
            [SettingEntry]::new("sizeasc", "sort by size ascending"),
            [SettingEntry]::new("sizedesc", "sort by size descending"),
            [SettingEntry]::new("timeasc", "sort by time ascending"),
            [SettingEntry]::new("timedesc", "sort by time descending")
        )
        foreach ($entry in $sortEntries) {
            $entry.id = [string]::Format("sort={0}", $entry.id)
            $entries.Add($entry)
        }
        if ($env:EDITOR) {
            $entries.Add([SettingEntry]::new("all", "edit settings file"))
        }
        $entries
    }
    $displays = foreach ($entry in $entries) {
        [string]::Format("{0,-15} : {1}", "[$($entry.id)]", $entry.description)
    }
    $fzfParams = ("--height=40%", "--prompt=:${PSItem} ", "--exact")
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
    & {
        $content = [JsonSerializer]::Serialize($settings, [Settings])
        [System.IO.File]::WriteAllLines($tempSettingsFile, $content)
    }
}

function Initialize {
    $script:register = [PSCustomObject]@{
        clipboard = [List[System.IO.FileSystemInfo]]::new()
        clipMode  = [ClipboardMode]::None
        bookmark  = [List[string]]::new()
    }
    if (Test-Path -Path $bookmarkFile) {
        $content = [System.IO.File]::ReadAllLines($bookmarkFile)
        $register.bookmark = [JsonSerializer]::Deserialize($content, [List[string]])
    }
    $script:settings = & {
        $content = [System.IO.File]::ReadAllLines($settingsFile)
        [JsonSerializer]::Deserialize($content, [Settings])
    }
    $script:extensions = & {
        $content = [System.IO.File]::ReadAllLines($extensionsFile)
        [JsonSerializer]::Deserialize($content, [Extensions])
    }
    $script:tempSettingsFile = New-TemporaryFile
    Copy-Item -Path $settingsFile -Destination $tempSettingsFile -Force
    $script:continue = $true
}

function Finalize {
    & {
        $options = [JsonSerializerOptions]::new()
        $options.WriteIndented = $true
        $content = [JsonSerializer]::Serialize($register.bookmark, [List[string]], $options)
        [System.IO.File]::WriteAllLines($bookmarkFile, $content)
    }
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
