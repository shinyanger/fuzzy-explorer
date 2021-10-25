$s_fgCode = "38;5;"
$s_bgCode = "48;5;"

$s_colors = [PSCustomObject]@{
    shortcut = 203
    file = 48
    directory = 81
    hidden = 149
    header = 109
    highlight = 236
    lineNumber = 238
}

class Settings {
    [bool]$preview
    [bool]$showDetails
    [bool]$showHidden
    [string]$sortBy
}

function IsProgramInstalled {
    param (
        [string]$program
    )
    $null = Get-Command -Name $program -ErrorAction SilentlyContinue
    return $?
}

function FormatColor {
    param (
        [string]$content,
        [short]$FgColor = -1,
        [short]$BgColor = -1
    )
    if (($FgColor -ge 0) -and ($BgColor -ge 0)) {
        return [string]::Format("`e[{0}{1};{2}{3}m{4}`e[0m", $s_fgCode, $FgColor, $s_bgCode, $BgColor, $content)
    }
    elseif (($FgColor -ge 0)) {
        return [string]::Format("`e[{0}{1}m{2}`e[0m", $s_fgCode, $FgColor, $content)
    }
    elseif ($BgColor -ge 0) {
        return [string]::Format("`e[{0}{1}m{2}`e[0m", $s_bgCode, $BgColor, $content)
    }
    else {
        return $content
    }
}

function GetDirHeader {
    if (-not $s_dirHeader) {
        $outStr = Get-Item ~ | Out-String
        $fields = $outStr.Split([System.Environment]::NewLine)
        $script:s_dirHeader = $fields[3..4]
    }
    return $s_dirHeader
}

function GetDirAttributes {
    $attributes = "!System"
    if (-not $s_settings.showHidden) {
        $attributes = $attributes + "+!Hidden"
    }
    return $attributes
}

function GetDirRows {
    param (
        [List[System.IO.FileSystemInfo]]$items
    )
    if ($items) {
        if ($s_settings.showDetails) {
            $outStr = $items | Format-Table -HideTableHeaders | Out-String
            $fields = $outStr.TrimEnd().Split([System.Environment]::NewLine)
            $count = $fields.Count
            return $fields[3..($count - 1)]
        }
        else {
            return $items.Name
        }
    }
}

function ColorizeRows {
    param (
        [List[System.IO.FileSystemInfo]]$items,
        [List[string]]$rows
    )
    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        if ($item.Attributes -band [System.IO.FileAttributes]::Hidden) {
            $rowColor = $s_colors.hidden
        }
        elseif ($item.PSIsContainer) {
            $rowColor = $s_colors.directory
        }
        else {
            $rowColor = $s_colors.file
        }
        FormatColor $rows[$i] -FgColor $rowColor
    }
}

function SortDir {
    param (
        [List[System.IO.FileSystemInfo]]$items
    )
    switch ($s_settings.sortBy) {
        "default" {
            $items
            break
        }
        "nameasc" {
            $items | Sort-Object -Property Name
            break
        }
        "namedesc" {
            $items | Sort-Object -Property Name -Descending
            break
        }
        "sizeasc" {
            $items | Sort-Object -Property Length
            break
        }
        "sizedesc" {
            $items | Sort-Object -Property Length -Descending
            break
        }
        "timeasc" {
            $items | Sort-Object -Property LastWriteTime
            break
        }
        "timedesc" {
            $items | Sort-Object -Property LastWriteTime -Descending
            break
        }
        Default {}
    }
}
