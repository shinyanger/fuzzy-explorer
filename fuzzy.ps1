using namespace System.Collections.Generic
using namespace System.Text.Json

$s_sharedFile = [System.IO.Path]::Join($PSScriptRoot, "shared.ps1")
. $s_sharedFile

$s_helperFile = [System.IO.Path]::Join($PSScriptRoot, "helper.ps1")
$s_settingsFile = [System.IO.Path]::Join($PSScriptRoot, "settings.json")
$s_extensionsFile = [System.IO.Path]::Join($PSScriptRoot, "extensions.json")
$s_bookmarkFile = [System.IO.Path]::Join($PSScriptRoot, "bookmark.json")
$s_fzfDefaultParams = ("--layout=reverse", "--border", "--info=inline")

enum ClipboardMode {
    None
    Cut
    Copy
    Link
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
    DirEntry(
        [string]$name,
        [string]$details
    ) {
        $this.name = $name
        $this.details = $details
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
    $displays = [List[string]]::new()
    & {
        if ($s_settings.showDetails) {
            $rows = [List[string]](GetDirHeader)
            foreach ($row in $rows) {
                $entries.Add([DirEntry]::new([string]::Empty, $row))
            }
            $displays.AddRange($rows)
        }
        & {
            $item = Get-Item . -Force
            $row = ".."
            if ($s_settings.showDetails) {
                $outstr = $item | Format-Table -HideTableHeaders | Out-String
                $fields = $outstr.Split([System.Environment]::NewLine)
                $index = $fields[3].LastIndexOf($item.Name)
                $row = $fields[3].Substring(0, $index) + ".."
            }
            $entries.Add([DirEntry]::new("..", $row))
            $row = ColorizeRows $item $row
            $displays.Add($row)
        }
        $items = & {
            $attributes = GetDirAttributes
            $items = Get-ChildItem -Force -Attributes $attributes
            SortDir $items
        }
        $rows = [List[string]](GetDirRows $items)
        for ($i = 0; $i -lt $items.Count; $i++) {
            $entries.Add([DirEntry]::new($items[$i].Name, $rows[$i]))
        }
        $rows = [List[string]](ColorizeRows $items $rows)
        $displays.AddRange($rows)
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
        $expect = [List[string]]("left", "right", ":", "f5")
        $shortcuts = [List[string]]("ctrl-q", "ctrl-e", "ctrl-p", "ctrl-j", "del", "f1", "f2")
        $expect.AddRange($shortcuts)
        foreach ($command in $s_extensions.commands) {
            if ($command.shortcut) {
                $expect.Add($command.shortcut)
            }
        }
        [string]::Join(',', $expect)
    }
    $fzfParams = [List[string]](
        "--height=80%",
        "--prompt=${location}> ",
        "--multi",
        "--ansi",
        "--expect=${expect}"
    )
    if ($s_settings.showDetails) {
        $fzfParams.AddRange(
            [List[string]](
                "--header-lines=2",
                "--nth=3..",
                "--delimiter=\s{2,}\d*\s"
            )
        )
        if ($s_settings.preview) {
            $fzfParams.Add("--preview=pwsh -NoProfile -File ${s_helperFile} ${s_tempSettingsFile} preview {3..}")
        }
    }
    else {
        if ($s_settings.preview) {
            $fzfParams.Add("--preview=pwsh -NoProfile -File ${s_helperFile} ${s_tempSettingsFile} preview {}")
        }
    }
    $output = $displays | fzf $s_fzfDefaultParams $fzfParams
    if ($LASTEXITCODE -eq 0) {
        if ([string]::IsNullOrEmpty($output[0])) {
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
    if ($s_register.clipboard) {
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
            if (IsProgramInstalled "rg") {
                $rgParams = [List[string]]("--line-number", "--no-heading", "--color=always", "--smart-case")
                $initParams = [List[string]]::new($rgParams)
                $initParams.Add('""')
                $reloadParams = [List[string]]::new($rgParams)
                $reloadParams.Add("{q}")
                $fzfParams.Add("--bind=change:reload:rg ${reloadParams}")
                $initList = rg $initParams
                $output = $initList | fzf $s_fzfDefaultParams $fzfParams
            }
            else {
                $fzfParams.Add("--bind=change:reload:pwsh -NoProfile -File ${s_helperFile} ${s_tempSettingsFile} search {q}")
                $initList = & $s_helperFile $s_tempSettingsFile search
                $output = $initList | fzf $s_fzfDefaultParams $fzfParams
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
                    $s_register.clipboard = $null
                    $s_register.clipMode = [ClipboardMode]::None
                    break
                }
                ([ClipboardMode]::Link) {
                    foreach ($item in $s_register.clipboard) {
                        New-Item -ItemType SymbolicLink -Path $item.Name -Target $item.FullName
                    }
                    $s_register.clipboard = $null
                    $s_register.clipMode = [ClipboardMode]::None
                    break
                }
                ([ClipboardMode]::None) {}
                Default {}
            }
            break
        }
        Default {
            $externalCommand = $s_extensions.commands.Find({ param($item) $item.id.Equals($commandId) -or $item.aliases.Contains($commandId) })
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
    $displays = [List[string]]::new()
    foreach ($entry in $entries) {
        $displays.Add([string]::Format("{0,-15} : {1}", "[$($entry.id)]", $entry.description))
    }
    $fzfParams = ("--height=40%", "--prompt=:${PSItem} ", "--exact")
    $output = $displays | fzf $s_fzfDefaultParams $fzfParams
    if ($LASTEXITCODE -ne 0) {
        return
    }
    $match = [regex]::Match($output, "^\[(?<entryId>\S+)\]")
    $entryId = $match.Groups["entryId"].Value
    switch ($entryId) {
        { $PSItem.EndsWith("preview") } {
            $s_settings.preview = -not $PSItem.StartsWith("no")
            break
        }
        { $PSItem.EndsWith("details") } {
            $s_settings.showDetails = -not $PSItem.StartsWith("no")
            break
        }
        { $PSItem.EndsWith("hidden") } {
            $s_settings.showHidden = -not $PSItem.StartsWith("no")
            break
        }
        { $PSItem.StartsWith("sort") } {
            $match = [regex]::Match($PSItem, "sort=(?<sortBy>\w+)")
            $s_settings.sortBy = $match.Groups["sortBy"].Value
            break
        }
        "all" {
            & $env:EDITOR $s_settingsFile
            break
        }
        Default {}
    }
    & {
        $content = [JsonSerializer]::Serialize($s_settings, [Settings])
        [System.IO.File]::WriteAllLines($s_tempSettingsFile, $content)
    }
}

function Initialize {
    $script:s_register = [PSCustomObject]@{
        clipboard = [List[System.IO.FileSystemInfo]]::new()
        clipMode  = [ClipboardMode]::None
        bookmark  = [List[string]]::new()
    }
    if ([System.IO.File]::Exists($s_bookmarkFile)) {
        $content = [System.IO.File]::ReadAllLines($s_bookmarkFile)
        $s_register.bookmark = [JsonSerializer]::Deserialize($content, [List[string]])
    }
    $script:s_settings = & {
        $content = [System.IO.File]::ReadAllLines($s_settingsFile)
        [JsonSerializer]::Deserialize($content, [Settings])
    }
    $script:s_extensions = & {
        $content = [System.IO.File]::ReadAllLines($s_extensionsFile)
        [JsonSerializer]::Deserialize($content, [Extensions])
    }
    $script:s_tempSettingsFile = (New-TemporaryFile).FullName
    Copy-Item -Path $s_settingsFile -Destination $s_tempSettingsFile -Force
    $script:s_continue = $true
}

function Finalize {
    & {
        $options = [JsonSerializerOptions]::new()
        $options.WriteIndented = $true
        $content = [JsonSerializer]::Serialize($s_register.bookmark, [List[string]], $options)
        [System.IO.File]::WriteAllLines($s_bookmarkFile, $content)
    }
    Remove-Item -Path $s_tempSettingsFile -Force
}

function FuzzyExplorer {
    Initialize
    while ($s_continue) {
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
