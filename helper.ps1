$sharedFile = Join-Path -Path $PSScriptRoot -ChildPath "shared.ps1"
. $sharedFile

function Preview {
    param (
        [string]$fileName,
        [int]$line
    )
    $selectedFile = Get-Item $fileName -Force -ErrorAction SilentlyContinue
    if (-not $?) {
        $fileNames = $fileName -split " -> "
        $fileName = $fileNames[0]
        $selectedFile = Get-Item $fileName -Force
    }
    if ($selectedFile.PSIsContainer) {
        $script:settings = Get-Content $tempSettingsFile | ConvertFrom-Json
        $attributes = GetDirAttributes
        $items = Get-ChildItem $selectedFile -Force -Attributes $attributes
        $items = SortDir $items
        if ($?) {
            GetDirHeader
            GetDirRows $items
        }
    }
    elseif (IsProgramInstalled "bat") {
        $batParams = @("--style=numbers", "--color=always")
        if ($line) {
            bat $batParams --highlight-line $line $fileName
        }
        else {
            bat $batParams --line-range :100 $fileName
        }
    }
    else {
        $lineFormat = "`e[38;5;238m{0,4}`e[0m {1}"
        $formatter = { $lineFormat -f ($PSItem + 1), $content[$PSItem] }
        if ($line) {
            $hlFormat = "`e[48;5;236m{0}`e[m"
            $content = [string[]](Get-Content $fileName -ReadCount 0)
            $count = $content.Length
            if ($line -gt 1) {
                0..($line - 2) | ForEach-Object { & $formatter }
            }
            $lineFormat -f $line, ($hlFormat -f $content[$line - 1])
            if ($line -lt $count) {
                $line..($count - 1) | ForEach-Object { & $formatter }
            }
        }
        else {
            $content = [string[]](Get-Content $fileName -TotalCount 100 -ReadCount 0)
            $count = $content.Length
            0..($count - 1) | ForEach-Object { & $formatter }
        }
    }
}

function FuzzyHelper {
    $script:tempSettingsFile = $args[0]
    switch ($args[1]) {
        "preview" {
            $fileName = $args[2]
            $line = 0
            if ($args.Count -gt 3) {
                $line = $args[3]
            }
            Preview $fileName $line
            break
        }
        "search" {
            if ($args.Count -gt 2) {
                $query = $args[2]
            }
            if (-not $query) {
                $query = "^"
            }
            $output = Get-ChildItem -File -Recurse -Attributes !System | Select-String -Pattern $query
            if ($output) {
                ($output | Out-String).Trim()
            }
            break
        }
        Default {}
    }
}

FuzzyHelper @args