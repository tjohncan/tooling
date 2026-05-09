@echo off
REM === Polyglot single-file pattern ===
REM cmd exits at 'exit /b' below; the :: lines after are cmd comments.
REM The PowerShell loader reads this file back, extracts the section
REM between :PS_BEGIN and :PS_END, strips ::, and runs it.

setlocal

REM ====== EDIT THIS to change (initial) save folder ======
set "DEST=%USERPROFILE%\Pictures\Clipboard"
REM =======================================================

PowerShell -NoProfile -ExecutionPolicy Bypass -Command "$DEST = '%DEST%'; $c = Get-Content -Raw -LiteralPath '%~f0'; if ($c -match '(?s)\n:PS_BEGIN(.*?)\n:PS_END') { Invoke-Expression ($matches[1] -replace '(?m)^::', '') } else { Write-Host 'PS section not found.'; [void](Read-Host 'Press Enter to close') }"

endlocal
exit /b

:PS_BEGIN
::Add-Type -AssemblyName System.Windows.Forms
::$img = [System.Windows.Forms.Clipboard]::GetImage()
::if (-not $img) {
::    Write-Host 'No image in clipboard.'
::    [void](Read-Host 'Press Enter to close')
::    exit
::}
::
::if (-not (Test-Path $DEST)) {
::    New-Item -ItemType Directory -Path $DEST | Out-Null
::}
::
::$defaultName = 'clip_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.png'
::$defaultPath = Join-Path $DEST $defaultName
::$img.Save($defaultPath, [System.Drawing.Imaging.ImageFormat]::Png)
::$img.Dispose()
::Write-Host "Saved: $defaultPath"
::
::$target = (Read-Host "Move to (blank to keep)").Trim().Trim('"', "'")
::if (-not $target) { exit }
::
::if ($target.ToLower().EndsWith('.png')) {
::    $destDir = Split-Path -Parent $target
::    if (-not $destDir) { $destDir = '.' }
::    $destFile = Split-Path -Leaf $target
::} else {
::    $destDir = $target
::    $destFile = $defaultName
::}
::
::if (-not (Test-Path $destDir)) {
::    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
::}
::$movePath = Join-Path $destDir $destFile
::
::if (Test-Path $movePath) {
::    do {
::        $resp = (Read-Host "Exists. [Y]es overwrite / [N]ext number / [C]ancel move").Trim().ToUpper()
::    } while ($resp -notin 'Y','N','C')
::    if ($resp -eq 'C') {
::        Write-Host "Cancelled. Still saved at: $defaultPath"
::        exit
::    }
::    if ($resp -eq 'N') {
::        $base = [System.IO.Path]::GetFileNameWithoutExtension($destFile)
::        $ext  = [System.IO.Path]::GetExtension($destFile)
::        $i = 2
::        do {
::            $movePath = Join-Path $destDir "${base}_$i$ext"
::            $i++
::        } while (Test-Path $movePath)
::    }
::}
::
::try {
::    Move-Item -Path $defaultPath -Destination $movePath -Force
::    Write-Host "Moved to: $movePath"
::} catch {
::    Write-Host "Move failed: $_"
::    Write-Host "Still saved at: $defaultPath"
::    [void](Read-Host 'Press Enter to close')
::}
:PS_END
