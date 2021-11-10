using namespace System.Collections.Generic
using namespace System.Text.Json

$s_sharedFile = [System.IO.Path]::Join($PSScriptRoot, "shared.ps1")
. $s_sharedFile

function Preview {
    param (
        [string]$fileName,
        [int]$lineNumber
    )
    if ($fileName.Contains(" -> ")) {
        $fields = $fileName.Split(" -> ")
        $fileName = $fields[0]
    }
    $selectedFile = Get-Item $fileName -Force
    if ($selectedFile.PSIsContainer) {
        $script:s_settings = & {
            $content = [System.IO.File]::ReadAllLines($s_tempSettingsFile)
            [JsonSerializer]::Deserialize($content, [Settings])
        }
        $attributes = GetDirAttributes
        $items = Get-ChildItem $selectedFile -Force -Attributes $attributes
        if ($?) {
            $displays = [List[string]]::new()
            if ($s_settings.showDetails) {
                $rows = [List[string]](GetDirHeader)
                $displays.AddRange($rows)
            }
            $items = SortDir $items
            $rows = [List[string]](GetDirRows $items)
            $rows = [List[string]](ColorizeRows $items $rows)
            if ($rows.Count -gt 0) {
                $displays.AddRange($rows)
            }
            foreach ($display in $displays) {
                [System.Console]::WriteLine($display)
            }
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
            $content = [System.IO.File]::ReadAllLines($fileName)
            $count = $content.Count
            $displays = [List[string]]::new()
            if ($lineNumber -gt 1) {
                for ($i = 0; $i -lt $lineNumber - 1; $i++) {
                    $row = & $formatter
                    $displays.Add($row)
                }
            }
            & {
                $row = [string]::Format($lineFormat, $lineNumber, (FormatColor $content[$lineNumber - 1] -BgColor $s_colors.highlight))
                $displays.Add($row)
            }
            if ($lineNumber -lt $count) {
                for ($i = $lineNumber; $i -lt $count; $i++) {
                    $row = & $formatter
                    $displays.Add($row)
                }
            }
            foreach ($display in $displays) {
                [System.Console]::WriteLine($display)
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
                $display = & $formatter
                [System.Console]::WriteLine($display)
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
            $query = [string]::Empty
            if ($args.Count -gt 2) {
                $query = $args[2]
            }
            $output = Get-ChildItem -File -Recurse -Attributes !System | Select-String -Pattern $query
            if ($output) {
                $display = ($output | Out-String).Trim()
                [System.Console]::WriteLine($display)
            }
            break
        }
        Default {}
    }
}

$PSStyle.OutputRendering = [System.Management.Automation.OutputRendering]::Ansi
FuzzyHelper @args
