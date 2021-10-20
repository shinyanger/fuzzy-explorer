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
        $script:settings = [System.IO.File]::ReadAllLines($tempSettingsFile) | ConvertFrom-Json
        $attributes = GetDirAttributes
        $items = Get-ChildItem $selectedFile -Force -Attributes $attributes
        if ($?) {
            if ($settings.showDetails) {
                $rows = GetDirHeader
                foreach ($row in $rows) {
                    FormatColor $row -FgColor $colors.header
                }
            }
            $items = SortDir $items
            $rows = GetDirRows $items
            ColorizeRows $items $rows
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
        $lineFormat = (FormatColor "{0,4}" -FgColor $colors.lineNumber) + " {1}"
        $formatter = { $lineFormat -f ($i + 1), $content[$i] }
        if ($line) {
            $content = [string[]][System.IO.File]::ReadAllLines($fileName)
            $count = $content.Length
            if ($line -gt 1) {
                for ($i = 0; $i -lt $line - 1; $i++) {
                    & $formatter
                }
            }
            $lineFormat -f $line, (FormatColor $content[$line - 1] -BgColor $colors.highlight)
            if ($line -lt $count) {
                for ($i = $line; $i -lt $count; $i++) {
                    & $formatter
                }
            }
        }
        else {
            $count = 0
            $content = [System.Collections.Generic.List[string]]::new()
            foreach ($text in [System.IO.File]::ReadLines($fileName)) {
                $content.Add($text)
                if (++$count -ge 100) {
                    break
                }
            }
            for ($i = 0; $i -lt $count; $i++) {
                & $formatter
            }
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
            . {
                if ($args.Count -gt 2) {
                    $query = $args[2]
                }
                if (-not $query) {
                    $query = "^"
                }
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
