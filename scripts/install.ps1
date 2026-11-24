<#
.SYNOPSIS
  Installs (or updates) NikoDeck on this computer and, optionally, on the connected phone.

.DESCRIPTION
  1. Publishes the agent to a temporary staging folder.
  2. Stops a running agent and installs the staged build in %LOCALAPPDATA%\NikoDeck\app.
  3. Optionally adds a Start-with-Windows shortcut.
  4. Optionally installs the panel APK on the connected phone: the newest of dist\ and the last build, rebuilt
     first when the app's sources are newer (or with -BuildApk).
  5. Starts the agent (it lives in the system tray).

.EXAMPLE
  .\scripts\install.ps1                 # agent only
  .\scripts\install.ps1 -Apk -Autostart # agent + phone app + start with Windows
#>
param(
    [switch]$Apk,        # also install the Android panel on the connected phone
    [switch]$BuildApk,   # with -Apk: always build the APK first
    [switch]$Autostart,  # start the agent with Windows
    [string]$Serial      # phone serial when several devices are connected
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
. (Join-Path $PSScriptRoot 'install-apk.ps1')   # also defines Expand-Text for the accented messages below
$app = Join-Path $env:LOCALAPPDATA 'NikoDeck\app'
$exe = Join-Path $app 'NikoDeck.exe'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw (Expand-Text '\u00c9 necess\u00e1rio o .NET 10 SDK: winget install Microsoft.DotNet.SDK.10') }
$stage = Join-Path ([IO.Path]::GetTempPath()) ('phonebox-publish-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Host '==> Publicando o agente'
    dotnet publish (Join-Path $root 'agent\PhoneBox.Agent') -c Release -f net10.0-windows10.0.19041.0 -o $stage --nologo -v q --disable-build-servers
    if ($LASTEXITCODE) { throw (Expand-Text "dotnet publish falhou (c\u00f3digo de sa\u00edda $LASTEXITCODE); o agente instalado n\u00e3o foi atualizado") }
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'NikoDeck.exe') -PathType Leaf)) {
        throw (Expand-Text 'publish falhou: o execut\u00e1vel do agente n\u00e3o foi encontrado na pasta tempor\u00e1ria')
    }

    Write-Host (Expand-Text '==> Encerrando o agente em execu\u00e7\u00e3o')
    Get-Process NikoDeck, DeskAgent -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500

    Write-Host "==> Instalando em $app"
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    foreach ($entry in (Get-ChildItem -LiteralPath $stage -Force)) {
        Copy-Item -LiteralPath $entry.FullName -Destination $app -Recurse -Force
    }
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

# Leftover shortcut from the pre-PhoneBox "DeskAgent" prototype.
$startup = [Environment]::GetFolderPath('Startup')
Remove-Item (Join-Path $startup 'DeskAgent.lnk') -ErrorAction SilentlyContinue

$programs = [Environment]::GetFolderPath('Programs')
if ($programs -and (Test-Path $programs)) {
    Write-Host '==> Adicionando o atalho no menu Iniciar'
    # a shortcut that cannot be written must not stop the script before the agent is started again
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Join-Path $programs 'NikoDeck.lnk'))
        $lnk.TargetPath = $exe
        $lnk.WorkingDirectory = $app
        $lnk.Description = 'Agente do NikoDeck'
        $lnk.Save()
    } catch {
        Write-Warning (Expand-Text "N\u00e3o foi poss\u00edvel criar o atalho no menu Iniciar: $($_.Exception.Message)")
    }
}

if ($Autostart) {
    Write-Host '==> Adicionando o atalho de "Iniciar com o Windows"'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-Path $startup 'NikoDeck.lnk'))
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $app
    $lnk.Description = 'Agente do NikoDeck'
    $lnk.Save()
}

Write-Host '==> Iniciando o agente'
# A failed start must not skip the phone app below, but it is still a failure: it is raised once that step ran.
# A slow answer from a started agent is only a warning.
$launchError = $null
try { Start-Process $exe -WorkingDirectory $app } catch { $launchError = $_ }
if (-not $launchError) {
    Start-Sleep 2
    try { Invoke-RestMethod http://127.0.0.1:8765/api/info -TimeoutSec 5 | Out-Null; Write-Host (Expand-Text 'O NikoDeck est\u00e1 em execu\u00e7\u00e3o. Configura\u00e7\u00f5es: http://127.0.0.1:8765  (ou pelo \u00edcone da bandeja)') }
    catch { Write-Warning (Expand-Text "O agente n\u00e3o respondeu; veja $env:LOCALAPPDATA\NikoDeck\agent.log") }
}

if ($Apk) {
    $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
    if (-not $adb) {
        $adb = @("$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe") +
            (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter 'Google.PlatformTools*' -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'platform-tools\adb.exe' }) |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $adb) { throw (Expand-Text 'adb n\u00e3o encontrado: winget install Google.PlatformTools') }

    $built = Join-Path $root 'android\app\build\outputs\apk\release\app-release.apk'
    $apkFile = @(Get-ChildItem (Join-Path $root 'dist') -Filter 'NikoDeck-*.apk' -ErrorAction SilentlyContinue) +
        @(Get-Item $built -ErrorAction SilentlyContinue) | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (Test-Path (Join-Path $root 'android\gradlew.bat')) {
        # in a source checkout, an APK from an older release must not win over newer app sources
        $newestSource = Get-ChildItem (Join-Path $root 'android\app\src') -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($BuildApk -or -not $apkFile -or $newestSource.LastWriteTime -gt $apkFile.LastWriteTime) {
            Write-Host '==> Compilando o APK'
            Push-Location (Join-Path $root 'android')
            try { .\gradlew.bat assembleRelease --console=plain -q; if ($LASTEXITCODE) { throw (Expand-Text "o build do Android falhou (c\u00f3digo de sa\u00edda $LASTEXITCODE); o app do celular n\u00e3o foi atualizado") } } finally { Pop-Location }
            $apkFile = Get-Item $built
        }
    }
    if (-not $apkFile) { throw (Expand-Text 'Nenhum APK encontrado em dist\ e n\u00e3o h\u00e1 c\u00f3digo-fonte do Android para compilar um') }
    if (-not $Serial) {
        $devices = @(& $adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "`tdevice$" } | ForEach-Object { ($_ -split "`t")[0] })
        if ($devices.Count -eq 0) { throw (Expand-Text 'Nenhum dispositivo Android autorizado encontrado (confira o pedido de depura\u00e7\u00e3o USB no celular).') }
        if ($devices.Count -gt 1) { throw (Expand-Text "H\u00e1 v\u00e1rios dispositivos conectados; escolha um com -Serial: $($devices -join ', ')") }
        $Serial = $devices[0]
    }
    Write-Host "==> Instalando $($apkFile.Name) em $Serial"
    $target = @('-s', $Serial)
    $out = Install-PhoneBoxApk -Adb $adb -ApkPath $apkFile.FullName -Serial $Serial
    $out | Select-Object -Last 1
    & $adb @target shell am start -n com.lordsigfrid.nikodeck/net.oxog.phonebox.deskpanel.MainActivity | Out-Null
}

# the agent could not be started (see above): the phone step ran, the install still failed
if ($launchError) { throw $launchError }
