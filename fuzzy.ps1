using namespace System.Collections.Generic
using namespace System.Text.Json

. ([System.IO.Path]::Join($PSScriptRoot, "commands.ps1"))
. ([System.IO.Path]::Join($PSScriptRoot, "shared.ps1"))

$s_helperFile = [System.IO.Path]::Join($PSScriptRoot, "helper.ps1")
$s_settingsFile = [System.IO.Path]::Join($PSScriptRoot, "settings.json")
$s_extensionsFile = [System.IO.Path]::Join($PSScriptRoot, "extensions.json")
$s_bookmarkFile = [System.IO.Path]::Join($PSScriptRoot, "bookmark.json")
$s_fzfDefaultParams = ("--layout=reverse", "--border", "--info=inline")
$s_pwshDefaultParams = ("-NoLogo", "-NoProfile", "-File", $s_helperFile)

enum ClipboardMode {
    None
    Cut
    Copy
    Link
}

function ListDirectory {
    $result = [PSCustomObject]@{
        operation     = [string]::Empty
        selectedFiles = [List[System.IO.FileSystemInfo]]::new()
    }
    $entries = [Dictionary[string, string]]::new()
    $displays = [List[string]]::new()
    & {
        if ($s_settings.showDetails) {
            $rows = [List[string]](GetDirHeader)
            foreach ($row in $rows) {
                $entries[$row] = [string]::Empty
            }
            $displays.AddRange($rows)
        }
        & {
            $item = Get-Item -Path . -Force
            $row = ".."
            if ($s_settings.showDetails) {
                $outstr = $item | Format-Table -View children -HideTableHeaders | Out-String -Width 200
                $fields = $outstr.Split([System.Environment]::NewLine)
                $row = $fields[3].Substring(0, $s_nameIndex) + ".."
            }
            $entries[$row] = ".."
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
            $row = $rows[$i]
            $entries[$row] = $items[$i].Name
        }
        $rows = [List[string]](ColorizeRows $items $rows)
        if ($rows.Count -gt 0) {
            $displays.AddRange($rows)
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
        $expect = [List[string]]("left", "right", ":", "f5")
        foreach ($command in $s_commands) {
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
        $fzfParams.Add("--header-lines=2")
        $fzfParams.Add("--nth=4..")
    }
    if ($s_settings.preview) {
        if ($s_settings.showDetails) {
            $pwshParams = ($s_tempSettingsFile, "preview-detail", "+{}", ($s_nameIndex + 1))
        }
        else {
            $pwshParams = ($s_tempSettingsFile, "preview", "{}")
        }
        $fzfParams.Add("--preview=pwsh ${s_pwshDefaultParams} ${pwshParams}")
    }
    if ($s_settings.cyclic) {
        $fzfParams.Add("--cycle")
    }
    $output = $displays | fzf $s_fzfDefaultParams $fzfParams
    if ($LASTEXITCODE -eq 0) {
        if ([string]::IsNullOrEmpty($output[0])) {
            $output[0] = "enter"
        }
        $result.operation = $output[0]
        for ($i = 1; $i -lt $output.Count; $i++) {
            $row = $output[$i]
            $fileName = $entries[$row]
            $fullName = [System.IO.Path]::Join($PWD.ToString(), $fileName)
            if (-not ([System.IO.File]::Exists($fullName) -or [System.IO.Directory]::Exists($fullName)))
            {
                continue
            }
            if ((-not $fileName.Equals("..")) -or ([List[string]]("enter", "right")).Contains($result.operation)) {
                $item = Get-Item -LiteralPath $fileName -Force
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

function ChangeSetting {
    $entries = [Dictionary[string, string]]::new()
    & {
        $entries.Add("preview", "show preview window on")
        $entries.Add("nopreview", "show preview window off")
        $entries.Add("details", "show directory details on")
        $entries.Add("nodetails", "show directory details off")
        $entries.Add("hidden", "show hidden files on")
        $entries.Add("nohidden", "show hidden files off")
        $entries.Add("cyclic", "cyclic scroll on")
        $entries.Add("nocyclic", "cyclic scroll off")
        $entries.Add("sort=default", "sort by default"),
        $entries.Add("sort=nameasc", "sort by name ascending"),
        $entries.Add("sort=namedesc", "sort by name descending"),
        $entries.Add("sort=sizeasc", "sort by size ascending"),
        $entries.Add("sort=sizedesc", "sort by size descending"),
        $entries.Add("sort=timeasc", "sort by time ascending"),
        $entries.Add("sort=timedesc", "sort by time descending")
        if ($env:EDITOR) {
            $entries.Add("all", "edit settings file")
        }
    }
    $displays = [List[string]]::new()
    foreach ($entry in $entries.GetEnumerator()) {
        $displays.Add([string]::Format("{0,-15} : {1}", "[$($entry.Key)]", $entry.Value))
    }
    $fzfParams = ("--height=40%", "--prompt=:${PSItem} ", "--exact", "--no-sort")
    if ($s_settings.cyclic) {
        $fzfParams.Add("--cycle")
    }
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
        { $PSItem.EndsWith("cyclic") } {
            $s_settings.cyclic = -not $PSItem.StartsWith("no")
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
    if ([System.IO.File]::Exists($s_tempSettingsFile)) {
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
    & {
        $content = [System.IO.File]::ReadAllLines($s_settingsFile)
        $script:s_settings = [JsonSerializer]::Deserialize($content, [Settings])
    }
    & {
        $content = [System.IO.File]::ReadAllLines($s_extensionsFile)
        $extensions = [JsonSerializer]::Deserialize($content, [Extensions])
        $s_commands.AddRange($extensions.commands)
    }
    & {
        $script:s_tempSettingsFile = (New-TemporaryFile).FullName
        Copy-Item -Path $s_settingsFile -Destination $s_tempSettingsFile -Force
    }
    $script:s_continue = $true
}

function Finalize {
    & {
        $options = [JsonSerializerOptions]::new()
        $options.WriteIndented = $true
        $content = [JsonSerializer]::Serialize($s_register.bookmark, [List[string]], $options)
        [System.IO.File]::WriteAllLines($s_bookmarkFile, $content)
    }
    if ([System.IO.File]::Exists($s_tempSettingsFile)) {
        Remove-Item -Path $s_tempSettingsFile -Force
    }
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
