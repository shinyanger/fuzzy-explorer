using namespace System.Collections.Generic
using namespace System.Text.Json

$s_sharedFile = [System.IO.Path]::Join($PSScriptRoot, "shared.ps1")
. $s_sharedFile

function Preview {
    param (
        [string]$fileName,
        [int]$lineNumber
    )
    $selectedFile = Get-Item $fileName -Force -ErrorAction SilentlyContinue
    if (-not $?) {
        $fileNames = $fileName.Split(" -> ")
        $fileName = $fileNames[0]
        $selectedFile = Get-Item $fileName -Force
    }
    if ($selectedFile.PSIsContainer) {
        $script:s_settings = & {
            $content = [System.IO.File]::ReadAllLines($s_tempSettingsFile)
            [JsonSerializer]::Deserialize($content, [Settings])
        }
        $attributes = GetDirAttributes
        $items = Get-ChildItem $selectedFile -Force -Attributes $attributes
        if ($?) {
            if ($s_settings.showDetails) {
                $rows = GetDirHeader
                foreach ($row in $rows) {
                    FormatColor $row -FgColor $s_colors.header
                }
            }
            $items = SortDir $items
            $rows = GetDirRows $items
            ColorizeRows $items $rows
        }
    }
    elseif (IsProgramInstalled "bat") {
        $batParams = ("--style=numbers", "--color=always")
        if ($lineNumber) {
            bat $batParams --highlight-line $lineNumber $fileName
        }
        else {
            bat $batParams --line-range :100 $fileName
        }
    }
    else {
        $lineFormat = (FormatColor "{0,4}" -FgColor $s_colors.lineNumber) + " {1}"
        $formatter = { [string]::Format($lineFormat, ($i + 1), $content[$i]) }
        if ($lineNumber) {
            $content = [List[string]][System.IO.File]::ReadAllLines($fileName)
            $count = $content.Count
            if ($lineNumber -gt 1) {
                for ($i = 0; $i -lt $lineNumber - 1; $i++) {
                    & $formatter
                }
            }
            [string]::Format($lineFormat, $lineNumber, (FormatColor $content[$lineNumber - 1] -BgColor $s_colors.highlight))
            if ($lineNumber -lt $count) {
                for ($i = $lineNumber; $i -lt $count; $i++) {
                    & $formatter
                }
            }
        }
        else {
            $count = 0
            $content = [List[string]]::new()
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
    $script:s_tempSettingsFile = $args[0]
    switch ($args[1]) {
        "preview" {
            $fileName = $args[2]
            $lineNumber = 0
            if ($args.Count -gt 3) {
                $lineNumber = $args[3]
            }
            Preview $fileName $lineNumber
            break
        }
        "search" {
            $query = & {
                if ($args.Count -gt 2) {
                    $query = $args[2]
                }
                if (-not $query) {
                    $query = "^"
                }
                $query
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
