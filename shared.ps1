$s_colors = [PSCustomObject]@{
    shortcut   = 0xff5f5f # 203
    file       = 0x00ff87 # 48
    directory  = 0x5fd7ff # 81
    hidden     = 0xafd75f # 149
    highlight  = 0x303030 # 236
    lineNumber = 0x444444 # 238
}

class Settings {
    [bool]$preview
    [bool]$showDetails
    [bool]$showHidden
    [bool]$cyclic
    [string]$sortBy
}

function IsProgramInstalled {
    [OutputType([bool])]
    param (
        [string]$program
    )
    $null = Get-Command -Name $program -ErrorAction SilentlyContinue
    return $?
}

function FormatColor {
    [OutputType([string])]
    param (
        [string]$content,
        [int]$FgColor = -1,
        [int]$BgColor = -1
    )
    $styleColor = [string]::Empty
    if ($FgColor -ge 0) {
        $styleColor += $PSStyle.Foreground.FromRgb($FgColor)
    }
    if ($BgColor -ge 0) {
        $styleColor += $PSStyle.Background.FromRgb($BgColor)
    }
    if ($styleColor) {
        return [string]::Format("{0}{1}{2}", $styleColor, $content, $PSStyle.Reset)
    }
    else {
        return $content
    }
}

function GetDirHeader {
    [OutputType([List[string]])]
    param ()
    if (-not $s_dirHeader) {
        $outStr = Get-Item ~ | Format-Table -View children | Out-String
        $fields = $outStr.Split([System.Environment]::NewLine)
        $script:s_dirHeader = $fields[3..4]
    }
    return $s_dirHeader
}

function GetDirAttributes {
    [OutputType([string])]
    $attributes = "!System"
    if (-not $s_settings.showHidden) {
        $attributes = $attributes + "+!Hidden"
    }
    return $attributes
}

function GetDirRows {
    [OutputType([List[string]])]
    param (
        [List[System.IO.FileSystemInfo]]$items
    )
    if ($items.Count -gt 0) {
        if ($s_settings.showDetails) {
            $outStr = $items | Format-Table -View children -HideTableHeaders | Out-String
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
    [OutputType([List[string]])]
    param (
        [List[System.IO.FileSystemInfo]]$items,
        [List[string]]$rows
    )
    $result = [List[string]]::new()
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
        $row = FormatColor $rows[$i] -FgColor $rowColor
        $result.Add($row)
    }
    return $result
}

function SortDir {
    [OutputType([List[System.IO.FileSystemInfo]])]
    param (
        [List[System.IO.FileSystemInfo]]$items
    )
    switch ($s_settings.sortBy) {
        "default" {
            break
        }
        "nameasc" {
            $items = $items | Sort-Object -Property Name
            break
        }
        "namedesc" {
            $items = $items | Sort-Object -Property Name -Descending
            break
        }
        "sizeasc" {
            $items = $items | Sort-Object -Property Length
            break
        }
        "sizedesc" {
            $items = $items | Sort-Object -Property Length -Descending
            break
        }
        "timeasc" {
            $items = $items | Sort-Object -Property LastWriteTime
            break
        }
        "timedesc" {
            $items = $items | Sort-Object -Property LastWriteTime -Descending
            break
        }
        Default {}
    }
    return $items
}
