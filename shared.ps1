$fgCode = "38;5;"
$bgCode = "48;5;"

$colors = [PSCustomObject]@{
    shortcut = 203
    file = 48
    directory = 81
    hidden = 149
    header = 109
    highlight = 236
    lineNumber = 238
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
        [string]$str,
        [short]$FgColor = -1,
        [short]$BgColor = -1
    )
    if (($FgColor -ge 0) -and ($BgColor -ge 0)) {
        "`e[${fgCode}${FgColor};${bgCode}${BgColor}m${str}`e[0m"
    }
    elseif (($FgColor -ge 0)) {
        "`e[${fgCode}${FgColor}m${str}`e[0m"
    }
    elseif ($BgColor -ge 0) {
        "`e[${bgCode}${BgColor}m${str}`e[0m"
    }
    else {
        $str
    }
}

function GetDirHeader {
    $outStr = Get-Item ~ | Out-String
    $fields = $outStr -split [System.Environment]::NewLine
    $fields[3..4]
}

function GetDirAttributes {
    $attributes = "!System"
    if (-not $settings.showHidden) {
        $attributes = $attributes + "+!Hidden"
    }
    return $attributes
}

function GetDirRows {
    param (
        [array]$items
    )
    if ($items) {
        if ($settings.showDetails) {
            $outStr = $items | Format-Table -HideTableHeaders | Out-String
            $fields = $outStr.TrimEnd() -split [System.Environment]::NewLine
            $count = $fields.Count
            $fields[3..($count - 1)]
        }
        else {
            $items.Name
        }
    }
}

function ColorizeRows {
    param (
        [array]$items,
        [array]$rows
    )
    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        if ($item.Attributes -band [System.IO.FileAttributes]::Hidden) {
            $rowColor = $colors.hidden
        }
        elseif ($item.PSIsContainer) {
            $rowColor = $colors.directory
        }
        else {
            $rowColor = $colors.file
        }
        FormatColor $rows[$i] -FgColor $rowColor
    }
}

function SortDir {
    param (
        [array]$items
    )
    switch ($settings.sortBy) {
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
