function IsProgramInstalled {
    param (
        [string]$program
    )
    Get-Command -Name $program -ErrorAction SilentlyContinue | Out-Null
    return $?
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
        $outStr = $items | Format-Table -HideTableHeaders | Out-String
        $fields = $outStr.TrimEnd() -split [System.Environment]::NewLine
        $count = $fields.Count
        $fields[3..($count - 1)]
    }
}

function SortDir {
    param (
        [array]$items
    )
    switch ($settings.sortBy) {
        "nameasc" {
            $items
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
