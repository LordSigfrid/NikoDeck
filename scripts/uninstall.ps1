<#
.SYNOPSIS
  Removes PhoneBox from this computer (and optionally from the phone).
.EXAMPLE
  .\scripts\uninstall.ps1               # remove the agent, keep settings
  .\scripts\uninstall.ps1 -Purge -Apk   # also delete settings and remove the phone app
#>
param([switch]$Purge, [switch]$Apk)

# This file stays ASCII (it also runs through "irm ... | iex", where a BOM would break it): accented letters are
# written as \u00XX (U+00C0 to U+00FF only) and turned into the real letters here.
function Expand-Text([string]$Text) {
    [regex]::Replace($Text, '\\u00([c-fC-F][0-9a-fA-F])', [Text.RegularExpressions.MatchEvaluator] {
        param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}

Get-Process PhoneBoxAgent -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'PhoneBox.lnk') -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'PhoneBox.lnk') -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Item (Join-Path $env:LOCALAPPDATA 'PhoneBox') -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Agente removido.'

if ($Purge) {
    Remove-Item (Join-Path $env:APPDATA 'PhoneBox') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host (Expand-Text 'Configura\u00e7\u00f5es removidas.')
}
if ($Apk) {
    $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
    if ($adb) { & $adb uninstall net.oxog.phonebox.deskpanel } else { Write-Warning (Expand-Text 'adb n\u00e3o encontrado; remova o app PhoneBox do celular manualmente.') }
}
