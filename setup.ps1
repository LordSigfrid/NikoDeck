<#
.SYNOPSIS
  NikoDeck setup for Windows: installs the latest release, everything it needs, and the phone app.

.DESCRIPTION
  Run it from a normal PowerShell window (not "Run as administrator"):

    irm https://raw.githubusercontent.com/LordSigfrid/NikoDeck/main/setup.ps1 | iex

  With options:

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/LordSigfrid/NikoDeck/main/setup.ps1))) -NoPhone

  What it does, asking first before anything outside the NikoDeck folders:
    1. Checks this PC (Windows 10/11, x64) and finds the latest NikoDeck release.
    2. Downloads the agent and checks its SHA-256 checksum (and its build provenance when the GitHub CLI is signed in).
    3. Installs adb (Android platform tools) when it is missing: with winget, or from Google's download.
    4. Installs the agent to %LOCALAPPDATA%\NikoDeck\app. Settings in %APPDATA%\NikoDeck are kept.
    5. Adds a Start Menu shortcut, optionally starts NikoDeck with Windows, puts the app on a phone connected over USB, starts the agent and opens its settings.

  Running it again updates NikoDeck or repairs the installation.

.PARAMETER Yes
  Answer every question with its default: for unattended runs.
.PARAMETER NoPhone
  Do not install the app on a phone over USB (for example when the phone will use Wi-Fi only).
.PARAMETER Serial
  The phone to use when several are connected (see "adb devices").
.PARAMETER NoAutostart
  Do not start NikoDeck with Windows.
.PARAMETER NoStart
  Install only; do not start the agent.
.PARAMETER Version
  Install this release (for example 0.9.8) instead of the latest.
.PARAMETER DryRun
  Download and check everything, show what would happen, and change nothing.
.PARAMETER AllowAdministrator
  Run even as administrator: only for PCs where every window runs elevated (UAC turned off) and for CI.
#>
param(
    [switch]$Yes,
    [switch]$NoPhone,
    [string]$Serial,
    [switch]$NoAutostart,
    [switch]$NoStart,
    [string]$Version,
    [switch]$DryRun,
    [switch]$AllowAdministrator
)

$Repo = 'LordSigfrid/NikoDeck'
$Upstream = 'ersinkoc/phonebox'   # NikoDeck is based on PhoneBox; some known issues are tracked there
$Package = 'com.lordsigfrid.nikodeck'
$SettingsUrl = 'http://127.0.0.1:8765'

# The messages are in Brazilian Portuguese, but this file stays ASCII: Windows PowerShell 5.1 reads a script without
# a BOM in the ANSI code page, and a BOM would break "irm ... | iex" (the string would start with U+FEFF). Accented
# letters are written as \u00XX (U+00C0 to U+00FF only) and turned into the real letters here, when they are shown.
function Expand-Text([string]$Text) {
    [regex]::Replace($Text, '\\u00([c-fC-F][0-9a-fA-F])', [Text.RegularExpressions.MatchEvaluator] {
        param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}

function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $(Expand-Text $Text)" -ForegroundColor Cyan }
function Write-Info([string]$Text) { Write-Host "    $(Expand-Text $Text)" }
function Write-Ok([string]$Text) { Write-Host "    OK  $(Expand-Text $Text)" -ForegroundColor Green }
function Write-Caution([string]$Text) { Write-Host "    !   $(Expand-Text $Text)" -ForegroundColor Yellow }

function Test-Interactive {
    if ($Yes) { return $false }
    try { return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected } catch { return $false }
}

# Asks a yes/no question; with -Yes or without a console, the default answer is taken.
# Portuguese (s/sim, n/nao) and English (y/yes, n/no) answers are both accepted.
function Read-YesNo([string]$Question, [bool]$Default = $true) {
    $hint = if ($Default) { '[S/n]' } else { '[s/N]' }
    if (-not (Test-Interactive)) {
        Write-Info "$Question $hint -> $(if ($Default) { 'sim' } else { 'n\u00e3o' }) (padr\u00e3o)"
        return $Default
    }
    while ($true) {
        $answer = "$(Read-Host "    $(Expand-Text $Question) $hint")".Trim().ToLowerInvariant()
        if ($answer -eq '') { return $Default }
        if ($answer -in @('s', 'sim', 'y', 'yes')) { return $true }
        if ($answer -in @('n', 'nao', (Expand-Text 'n\u00e3o'), 'no')) { return $false }
    }
}

# Runs a native program without letting Windows PowerShell 5.1 turn its stderr lines into errors.
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $File @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ Code = $code; Output = @($output) }
}

function Get-Download([string]$Url, [string]$Path) {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path -Headers @{ 'User-Agent' = 'nikodeck-setup' }
}

function Get-LatestVersion {
    try {
        $release = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$Repo/releases/latest" `
            -Headers @{ 'User-Agent' = 'nikodeck-setup'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 30
        if ($release.tag_name) { return [string]$release.tag_name }
    } catch { }
    # The API allows 60 requests an hour per address; the release page redirects to the newest tag as well.
    $request = [System.Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
    $request.AllowAutoRedirect = $false
    $request.Method = 'HEAD'
    $request.UserAgent = 'nikodeck-setup'
    $response = $request.GetResponse()
    try { $location = [string]$response.Headers['Location'] } finally { $response.Close() }
    if ($location -match '/tag/([^/?#]+)$') { return $Matches[1] }
    throw 'N\u00e3o foi poss\u00edvel encontrar a vers\u00e3o mais recente no GitHub. Verifique a conex\u00e3o com a internet ou use -Version (por exemplo, -Version 0.9.8).'
}

function Assert-Checksum([string]$File, [string]$SumsFile) {
    $name = Split-Path $File -Leaf
    $pattern = '^[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape($name) + '\s*$'
    $line = Get-Content -LiteralPath $SumsFile | Where-Object { $_ -match $pattern } | Select-Object -First 1
    if (-not $line) { throw "$name n\u00e3o est\u00e1 na lista de checksums da vers\u00e3o; o arquivo baixado n\u00e3o foi usado." }
    $expected = [regex]::Match($line, '^[0-9a-fA-F]{64}').Value
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    if ($actual -ne $expected) {
        throw "$name n\u00e3o confere com o checksum da vers\u00e3o (esperado $expected, obtido $actual). O arquivo foi danificado ou alterado no caminho; nada foi instalado. Execute a instala\u00e7\u00e3o de novo."
    }
    Write-Ok "$name confere com o checksum da vers\u00e3o"
}

function Test-Provenance([string]$File) {
    $gh = Get-Command gh -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gh -or (Invoke-Native $gh.Source @('auth', 'status')).Code -ne 0) {
        Write-Info "Origem do build n\u00e3o verificada (requer o GitHub CLI com login): gh attestation verify $(Split-Path $File -Leaf) --repo $Repo"
        return
    }
    # gh 2.92.0 and earlier send the GitHub token to the TUF mirrors during verification (GHSA-8xvp-7hj6-mcj9)
    $ghVersion = [regex]::Match("$((Invoke-Native $gh.Source @('--version')).Output)", 'gh version (\d+\.\d+\.\d+)').Groups[1].Value
    if (-not $ghVersion -or [version]$ghVersion -lt [version]'2.93.0') {
        Write-Caution "Origem do build n\u00e3o verificada: o GitHub CLI $(if ($ghVersion) { $ghVersion } else { '(vers\u00e3o desconhecida)' }) tem uma falha de seguran\u00e7a no"
        Write-Caution '"gh attestation" (ele envia seu token do GitHub para outro servidor). Atualize para a vers\u00e3o 2.93.0 ou mais recente.'
        return
    }
    $result = Invoke-Native $gh.Source @('attestation', 'verify', $File, '--repo', $Repo)
    if ($result.Code -eq 0) { Write-Ok "$(Split-Path $File -Leaf) foi gerado pelo fluxo de release deste reposit\u00f3rio (atestado do GitHub)" }
    elseif (($result.Output -join ' ') -match 'unknown command') { Write-Info 'Origem do build n\u00e3o verificada: este GitHub CLI \u00e9 antigo demais para o "gh attestation".' }
    else { throw "N\u00e3o foi poss\u00edvel verificar a origem do build de $(Split-Path $File -Leaf); nada foi instalado.`n$($result.Output -join "`n")" }
}

function Find-Adb {
    $candidates = @()
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $candidates += $command.Source }
    $candidates += Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $winget) {
        $candidates += Get-ChildItem $winget -Directory -Filter 'Google.PlatformTools*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'platform-tools\adb.exe' }
    }
    $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

function Install-Adb([string]$Temp) {
    Write-Info 'O adb (Android SDK Platform-Tools) \u00e9 um software do Google sob os termos do Android SDK:'
    Write-Info 'https://developer.android.com/studio/releases/platform-tools'
    $winget = Get-Command winget -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($winget) {
        Write-Info 'Instalando com o winget (Google.PlatformTools) ...'
        $result = Invoke-Native $winget.Source @('install', '--id', 'Google.PlatformTools', '--exact', '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements')
        $adb = Find-Adb
        if ($adb) { return $adb }
        Write-Caution "O winget n\u00e3o conseguiu instalar (c\u00f3digo de sa\u00edda $($result.Code)); baixando direto do Google."
    }
    $zip = Join-Path $Temp 'platform-tools.zip'
    Get-Download 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' $zip
    $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    New-Item -ItemType Directory -Force $sdk | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $sdk -Force
    Find-Adb
}

function Stop-PhoneBox {
    $running = @(Get-Process NikoDeck, DeskAgent -ErrorAction SilentlyContinue)
    foreach ($process in $running) {
        try { $process.Kill(); [void]$process.WaitForExit(10000) } catch { }
    }
    if ($running.Count) { Write-Info "Agente em execu\u00e7\u00e3o encerrado ($($running.Count) processo(s))" }
}

# Copies the new release over the installed one; Windows can hold a just-stopped program's files for a moment.
function Copy-Release([string]$From, [string]$To) {
    for ($attempt = 1; ; $attempt++) {
        try { Copy-Item (Join-Path $From '*') $To -Recurse -Force -ErrorAction Stop; return }
        catch {
            if ($attempt -ge 20) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Get-PortOwner([int]$Port) {
    try {
        $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1
        if ($listener) { return (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).ProcessName }
    } catch { }
    $null
}

function Get-Devices([string]$Adb) {
    foreach ($line in (Invoke-Native $Adb @('devices')).Output) {
        # "<serial><TAB><state>"; the header and adb's "daemon started" lines have no tab
        if ($line -match "^(\S+)`t(.+)$") { [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2].Trim() } }
    }
}

function Show-PhoneHelp {
    Write-Info 'No celular (Android 5.0 ou mais recente):'
    Write-Info '  1. Configura\u00e7\u00f5es > Sobre o telefone: toque 7 vezes em "N\u00famero da vers\u00e3o" para ativar as Op\u00e7\u00f5es do desenvolvedor.'
    Write-Info '  2. Configura\u00e7\u00f5es > Sistema > Op\u00e7\u00f5es do desenvolvedor: ative a "Depura\u00e7\u00e3o USB".'
    Write-Info '     Xiaomi / Redmi / POCO: ative tamb\u00e9m "Instalar via USB" e "Depura\u00e7\u00e3o USB (Configura\u00e7\u00f5es de seguran\u00e7a)".'
    Write-Info '  3. Conecte o celular com um cabo de dados (alguns cabos s\u00f3 carregam) e desbloqueie a tela.'
    Write-Info '  4. Em "Permitir a depura\u00e7\u00e3o USB?", toque em Permitir e marque "Sempre permitir neste computador".'
    Write-Info 'Se o celular nunca aparecer, o Windows pode precisar do driver USB dele: celulares Google usam o Google USB Driver;'
    Write-Info 'outras marcas oferecem o driver no site de suporte (o Gerenciador de Dispositivos mostra o celular com um alerta).'
}

# Waits for exactly one authorised phone; returns its serial, or $null to skip.
function Select-Phone([string]$Adb) {
    [void](Invoke-Native $Adb @('start-server'))
    $wanted = $Serial
    while ($true) {
        $devices = @(Get-Devices $Adb)
        if ($wanted) { $devices = @($devices | Where-Object { $_.Serial -eq $wanted }) }
        # only phones on a cable are picked automatically, not emulators or wireless-debugging connections
        $ready = @($devices | Where-Object { $_.State -eq 'device' -and ($wanted -or ($_.Serial -notmatch '^emulator-|:|\._tcp')) })
        if ($ready.Count -eq 1) { return $ready[0].Serial }
        if ($ready.Count -gt 1) {
            Write-Caution "H\u00e1 v\u00e1rios celulares conectados: $(($ready | ForEach-Object Serial) -join ', ')"
            if (-not (Test-Interactive)) { Write-Caution 'Execute a instala\u00e7\u00e3o de novo com -Serial <id> para escolher um; o app do celular foi pulado.'; return $null }
            $choice = "$(Read-Host (Expand-Text '    Digite o n\u00famero de s\u00e9rie do celular a usar (vazio para pular)'))".Trim()
            if (-not $choice) { return $null }
            $wanted = $choice
            continue
        }
        foreach ($device in $devices) {
            if ($device.State -eq 'unauthorized') { Write-Caution "$($device.Serial): aguardando voc\u00ea permitir a depura\u00e7\u00e3o USB no celular (desbloqueie e toque em Permitir)." }
            elseif ($device.State -eq 'offline') { Write-Caution "$($device.Serial): offline. Desconecte o cabo e conecte de novo." }
            elseif ($device.State -eq 'device') { Write-Caution "$($device.Serial): um emulador ou uma conex\u00e3o sem fio; s\u00f3 \u00e9 usado se voc\u00ea passar -Serial $($device.Serial)." }
            else { Write-Caution "$($device.Serial): $($device.State)" }
        }
        if (-not $devices.Count) {
            if ($wanted) { Write-Caution "Nenhum celular com o n\u00famero de s\u00e9rie $wanted est\u00e1 conectado." } else { Write-Caution 'Nenhum celular conectado via USB ainda.' }
            Show-PhoneHelp
        }
        if (-not (Test-Interactive)) { Write-Caution 'O app do celular foi pulado (nenhum celular pronto).'; return $null }
        $answer = "$(Read-Host '    Pressione Enter para verificar de novo, ou digite P para pular o celular')".Trim().ToLowerInvariant()
        if ($answer -in @('p', 'pular', 'skip')) { return $null }  # not a bare s: it means "sim" in the other prompts
        [void](Invoke-Native $Adb @('reconnect', 'offline'))
    }
}

function Install-PhoneApp([string]$Adb, [string]$Apk, [string]$Device) {
    $sdkLevel = 0
    [void][int]::TryParse(("$((Invoke-Native $Adb @('-s', $Device, 'shell', 'getprop', 'ro.build.version.sdk')).Output)").Trim(), [ref]$sdkLevel)
    if ($sdkLevel -gt 0 -and $sdkLevel -lt 21) {
        Write-Caution "Este celular tem Android API $sdkLevel; o NikoDeck precisa do Android 5.0 (API 21) ou mais recente. O app n\u00e3o foi instalado."
        return $false
    }
    Write-Info "Instalando $(Split-Path $Apk -Leaf) em $Device (o celular pode pedir confirma\u00e7\u00e3o) ..."
    $result = Invoke-Native $Adb @('-s', $Device, 'install', '-r', $Apk)
    $text = $result.Output -join ' '
    if ($text -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
        Write-Caution 'O celular tem um app NikoDeck assinado com outra chave (por exemplo, um que voc\u00ea mesmo compilou).'
        Write-Caution 'Ele foi mantido como est\u00e1, com seus dados. Para trocar pelo app oficial, desinstale o NikoDeck do celular'
        Write-Caution '(isso apaga as configura\u00e7\u00f5es dele) e execute a instala\u00e7\u00e3o de novo.'
        return $false
    }
    if ($text -match 'INSTALL_FAILED_VERSION_DOWNGRADE') { Write-Ok 'O celular j\u00e1 tem um app NikoDeck mais novo; ele foi mantido.'; return $true }
    if ($text -match 'INSTALL_FAILED_USER_RESTRICTED|INSTALL_FAILED_ABORTED') {
        Write-Caution 'O celular recusou a instala\u00e7\u00e3o. Confirme no celular; celulares Xiaomi / Redmi / POCO tamb\u00e9m precisam de'
        Write-Caution '"Instalar via USB" nas Op\u00e7\u00f5es do desenvolvedor. Depois execute a instala\u00e7\u00e3o de novo.'
        return $false
    }
    if ($result.Code -ne 0 -or $text -notmatch 'Success') {
        Write-Caution "N\u00e3o foi poss\u00edvel instalar o app: $text"
        return $false
    }
    Write-Ok 'App NikoDeck instalado no celular'
    [void](Invoke-Native $Adb @('-s', $Device, 'shell', 'am', 'start', '-n', "$Package/net.oxog.phonebox.deskpanel.MainActivity"))  # the activity keeps the upstream Kotlin package
    $true
}

function Install-PhoneBox {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes downloads in Windows PowerShell 5.1 many times slower
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Write-Host ''
    Write-Host (Expand-Text 'Instala\u00e7\u00e3o do NikoDeck') -ForegroundColor Cyan
    if ($DryRun) { Write-Host (Expand-Text 'Simula\u00e7\u00e3o: baixa e verifica tudo, sem alterar nada.') -ForegroundColor Yellow }

    Write-Step 'Verificando este PC'
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -eq 'ARM64') {
        throw "Ainda n\u00e3o existe build do NikoDeck para Windows em ARM: o build x64 funcionaria, mas n\u00e3o conseguiria se atualizar. Pe\u00e7a em https://github.com/$Repo/issues."
    }
    if ($architecture -ne 'AMD64') { throw "O NikoDeck precisa do Windows de 64 bits (este PC informa $architecture)." }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) { Write-Caution "O NikoDeck foi feito para o Windows 10 vers\u00e3o 2004 (build 19041) ou mais recente; este PC tem o build $build, ent\u00e3o algumas partes podem n\u00e3o funcionar." }
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and -not $AllowAdministrator) {
        throw 'Execute a instala\u00e7\u00e3o em uma janela normal do PowerShell, sem "Executar como administrador". O NikoDeck roda com o seu usu\u00e1rio e n\u00e3o precisa de direitos de administrador; como administrador, ele iniciaria com direitos totais ou seria instalado na conta do administrador em vez da sua.'
    }
    $scoop = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $HOME 'scoop' }
    if (Test-Path (Join-Path $scoop 'apps\nikodeck')) {
        throw 'O NikoDeck est\u00e1 instalado pelo Scoop. Atualize com "scoop update nikodeck". Para trocar para esta instala\u00e7\u00e3o, execute antes "scoop uninstall nikodeck" (suas configura\u00e7\u00f5es ficam) e depois a instala\u00e7\u00e3o de novo; duas c\u00f3pias disputariam a mesma porta.'
    }
    $app = Join-Path $env:LOCALAPPDATA 'NikoDeck\app'
    $exe = Join-Path $app 'NikoDeck.exe'
    $installed = $null
    if (Test-Path $exe) { $installed = ("$((Get-Item $exe).VersionInfo.ProductVersion)" -split '\+')[0] }
    Write-Ok "Windows build $build, x64$(if ($installed) { ", NikoDeck $installed instalado" })"
    # Smart App Control (Windows 11) blocks programs that are neither signed nor known to Microsoft: 1 on, 2 evaluation
    $smartAppControl = 0
    try { $smartAppControl = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState } catch { }
    if ($smartAppControl -eq 1) {
        Write-Caution 'O Controle Inteligente de Aplicativos est\u00e1 ativado. Ele bloqueia programas que n\u00e3o s\u00e3o assinados nem conhecidos pela Microsoft, e'
        Write-Caution 'o NikoDeck.exe n\u00e3o tem assinatura de c\u00f3digo (veja a discuss\u00e3o no projeto original, o PhoneBox:'
        Write-Caution "https://github.com/$Upstream/issues/56), ent\u00e3o o Windows provavelmente vai impedir que ele inicie. Mesmo assim, ele ser\u00e1 instalado."
        Write-Caution 'Mantenha o Controle Inteligente de Aplicativos ativado: em builds mais antigos do Windows, ele n\u00e3o pode ser reativado sem reinstalar o Windows.'
    } elseif ($smartAppControl -eq 2) {
        Write-Caution 'O Controle Inteligente de Aplicativos est\u00e1 em modo de avalia\u00e7\u00e3o: ainda n\u00e3o bloqueia nada. Se o Windows ativ\u00e1-lo depois, ele vai bloquear'
        Write-Caution "o NikoDeck.exe at\u00e9 o agente ter assinatura de c\u00f3digo (veja https://github.com/$Upstream/issues/56)."
    }

    Write-Step 'Procurando a vers\u00e3o'
    $tag = if ($Version) { $Version } else { Get-LatestVersion }
    $ver = $tag.Trim().TrimStart('v')
    if ($ver -notmatch '^\d+\.\d+\.\d+$') { throw "Vers\u00e3o inesperada: '$tag'." }
    $base = "https://github.com/$Repo/releases/download/v$ver"
    if ($installed -eq $ver) { Write-Ok "NikoDeck $ver (j\u00e1 instalado; ser\u00e1 reinstalado, as configura\u00e7\u00f5es ficam)" }
    elseif ($installed) { Write-Ok "NikoDeck $ver (atualizando a partir da $installed; as configura\u00e7\u00f5es ficam)" }
    else { Write-Ok "NikoDeck $ver" }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('nikodeck-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $temp | Out-Null
    try {
        Write-Step "Baixando o NikoDeck $ver"
        $zipName = "NikoDeckAgent-$ver-win-x64.zip"
        $sums = Join-Path $temp "SHA256SUMS-$ver.txt"
        $zip = Join-Path $temp $zipName
        try { Get-Download "$base/SHA256SUMS-$ver.txt" $sums } catch { throw "A vers\u00e3o $ver n\u00e3o foi encontrada ($base). $($_.Exception.Message)" }
        Write-Info "$zipName (cerca de 65 MB) ..."
        Get-Download "$base/$zipName" $zip
        Assert-Checksum $zip $sums
        Test-Provenance $zip
        Write-Info 'O agente ainda n\u00e3o tem assinatura de c\u00f3digo (o pedido \u00e0 SignPath Foundation est\u00e1 pendente). O Windows SmartScreen'
        Write-Info 'ou um antiv\u00edrus podem alertar sobre programas novos sem assinatura; o checksum acima mostra que este \u00e9 o arquivo'
        Write-Info "que o GitHub gerou a partir do c\u00f3digo-fonte p\u00fablico. Detalhes: https://github.com/$Repo/issues/69"

        $extract = Join-Path $temp 'agent'
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        Get-ChildItem $extract -Recurse -File | Unblock-File
        if (-not (Test-Path (Join-Path $extract 'NikoDeck.exe'))) {
            throw "O NikoDeck.exe sumiu do arquivo baixado: provavelmente um antiv\u00edrus o removeu. Veja https://github.com/$Upstream/issues/69 e restaure-o da quarentena, ou adicione uma exce\u00e7\u00e3o, e depois execute a instala\u00e7\u00e3o de novo."
        }

        Write-Step 'Verificando o adb (necess\u00e1rio para a conex\u00e3o USB com o celular)'
        $adb = Find-Adb
        if ($adb) { Write-Ok $adb }
        else {
            Write-Caution 'O adb n\u00e3o est\u00e1 instalado. Sem ele o NikoDeck ainda funciona via Wi-Fi, mas n\u00e3o alcan\u00e7a o celular pelo USB'
            Write-Caution '(acordar o celular ao conectar, instalar e atualizar o app do celular, usar o USB quando o Wi-Fi cair).'
            if ($DryRun) { Write-Info 'Ofereceria a instala\u00e7\u00e3o do adb.' }
            elseif (Read-YesNo 'Instalar o adb agora?') {
                $adb = Install-Adb $temp
                if ($adb) { Write-Ok "adb instalado: $adb" } else { Write-Caution 'N\u00e3o foi poss\u00edvel instalar o adb; o NikoDeck vai funcionar s\u00f3 via Wi-Fi at\u00e9 ele ser instalado.' }
            }
        }

        $owner = Get-PortOwner 8765
        if ($owner -and $owner -ne 'NikoDeck' -and $owner -ne 'DeskAgent') {
            Write-Caution "A porta 8765 est\u00e1 em uso por $owner. O NikoDeck precisa dessa porta; feche o $owner ou o NikoDeck n\u00e3o vai iniciar."
        }

        if ($DryRun) {
            Write-Step 'Simula\u00e7\u00e3o conclu\u00edda'
            Write-Info "Encerraria o agente em execu\u00e7\u00e3o e instalaria o NikoDeck $ver em $app (as configura\u00e7\u00f5es em $env:APPDATA\NikoDeck ficam)."
            Write-Info 'Adicionaria um atalho do NikoDeck ao menu Iniciar.'
            if (-not $NoAutostart) { Write-Info 'Perguntaria se o NikoDeck deve iniciar com o Windows.' }
            if (-not $NoPhone) { Write-Info 'Ofereceria a instala\u00e7\u00e3o do app em um celular conectado via USB.' }
            Write-Info 'Nada foi alterado.'
            return
        }

        Write-Step "Instalando em $app"
        Stop-PhoneBox
        # The files are replaced in place: the folder itself cannot be renamed while another program has it as its
        # working directory, such as the adb server the agent started.
        $old = "$app.old"
        Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $app) { Copy-Item $app $old -Recurse -Force }   # to put back if the copy fails
        try {
            New-Item -ItemType Directory -Force $app | Out-Null
            Copy-Release $extract $app
            # files the new version no longer has, for example the DLLs of a framework-dependent (source) install
            $keep = @{}
            Get-ChildItem $extract -Recurse -File | ForEach-Object { $keep[$_.FullName.Substring($extract.Length)] = $true }
            Get-ChildItem $app -Recurse -File | Where-Object { -not $keep[$_.FullName.Substring($app.Length)] } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        } catch {
            if (Test-Path $old) { try { Copy-Item (Join-Path $old '*') $app -Recurse -Force } catch { } }
            throw "A instala\u00e7\u00e3o falhou e a vers\u00e3o anterior foi restaurada: $($_.Exception.Message). Feche o NikoDeck (\u00edcone da bandeja > Sair) e execute a instala\u00e7\u00e3o de novo."
        }
        Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "NikoDeck $ver instalado; as configura\u00e7\u00f5es ficam em $env:APPDATA\NikoDeck"

        $programs = [Environment]::GetFolderPath('Programs')
        if ($programs -and (Test-Path $programs)) {
            try {
                $shell = New-Object -ComObject WScript.Shell
                $startLink = $shell.CreateShortcut((Join-Path $programs 'NikoDeck.lnk'))
                $startLink.TargetPath = $exe
                $startLink.WorkingDirectory = $app
                $startLink.Description = 'Agente do NikoDeck'
                $startLink.Save()
                Write-Ok 'Adicionado ao menu Iniciar (pesquise "NikoDeck" para abri-lo quando quiser)'
            } catch {
                Write-Caution "N\u00e3o foi poss\u00edvel criar o atalho no menu Iniciar: $($_.Exception.Message)"
            }
        }

        $startup = [Environment]::GetFolderPath('Startup')
        Remove-Item (Join-Path $startup 'DeskAgent.lnk') -ErrorAction SilentlyContinue   # the pre-PhoneBox prototype
        $shortcut = Join-Path $startup 'NikoDeck.lnk'
        if ($NoAutostart) {
            if (Test-Path $shortcut) {
                Remove-Item $shortcut -Force
                Write-Info 'Atalho de "Iniciar com o Windows" removido (-NoAutostart).'
            }
        } else {
            Write-Step 'Iniciar com o Windows'
            if (Read-YesNo 'Iniciar o NikoDeck quando voc\u00ea entrar no Windows?') {
                $shell = New-Object -ComObject WScript.Shell
                $link = $shell.CreateShortcut($shortcut)
                $link.TargetPath = $exe
                $link.WorkingDirectory = $app
                $link.Description = 'Agente do NikoDeck'
                $link.Save()
                Write-Ok 'Adicionado \u00e0 pasta Inicializar (desative em Gerenciador de Tarefas > Aplicativos de inicializa\u00e7\u00e3o)'
            } elseif (Test-Path $shortcut) {
                Remove-Item $shortcut -Force
                Write-Info 'O atalho existente de "Iniciar com o Windows" foi removido.'
            }
        }

        $phoneDone = $false
        if (-not $NoPhone) {
            Write-Step 'App do celular'
            if (-not $adb) {
                Write-Caution 'Pulado: o adb n\u00e3o est\u00e1 instalado.'
            } elseif (Read-YesNo 'Instalar agora o app NikoDeck em um celular conectado via USB?') {
                Write-Info 'A depura\u00e7\u00e3o USB permite que um computador autorizado controle o celular. Autorize apenas os seus computadores;'
                Write-Info 'voc\u00ea pode revog\u00e1-los em Op\u00e7\u00f5es do desenvolvedor > "Revogar autoriza\u00e7\u00f5es de depura\u00e7\u00e3o USB".'
                $device = Select-Phone $adb
                if ($device) {
                    # The phone app is optional: a failed download or checksum skips it, and the agent (already
                    # installed and stopped for the update) still starts below.
                    try {
                        $apk = Join-Path $temp "NikoDeck-$ver.apk"
                        Get-Download "$base/NikoDeck-$ver.apk" $apk
                        Assert-Checksum $apk $sums
                        $phoneDone = Install-PhoneApp $adb $apk $device
                    } catch {
                        Write-Caution "App do celular pulado: $($_.Exception.Message)"
                    }
                }
            }
        }

        if ($NoStart) {
            Write-Step 'Conclu\u00eddo (n\u00e3o iniciado)'
            Write-Info "Inicie com $exe"
        } else {
            Write-Step 'Iniciando o NikoDeck'
            $blocked = $false
            try {
                Start-Process -FilePath $exe -WorkingDirectory $app -ErrorAction Stop
            } catch {
                # Smart App Control and other App Control / AppLocker policies refuse the file (Win32 errors 4551 and 1260).
                # Start-Process keeps only the message, in the system language, so compare it with the system's own text.
                $why = "$($_.Exception.Message)"
                $says = { param($code) $text = ([ComponentModel.Win32Exception]::new($code).Message).Trim().TrimEnd('.'); $text -and $why.Contains($text) }
                $appControl = & $says 4551   # App Control for Business, which Smart App Control uses
                $groupPolicy = & $says 1260  # AppLocker or a software restriction policy
                if (-not ($appControl -or $groupPolicy)) { throw }
                $blocked = $true
                Write-Caution "O Windows n\u00e3o deixou o NikoDeck.exe iniciar: $why"
                if ($appControl -and $smartAppControl -eq 1) {
                    Write-Caution 'O NikoDeck est\u00e1 instalado, mas o Controle Inteligente de Aplicativos n\u00e3o vai execut\u00e1-lo at\u00e9 o agente ter assinatura de c\u00f3digo.'
                    Write-Caution "A assinatura est\u00e1 pendente: https://github.com/$Upstream/issues/56. Mantenha o Controle Inteligente de Aplicativos ativado."
                } else {
                    Write-Caution 'O NikoDeck est\u00e1 instalado, mas uma pol\u00edtica deste computador n\u00e3o permite que ele seja executado. Em um computador'
                    Write-Caution 'do trabalho ou da escola, pe\u00e7a ao administrador para liberar o NikoDeck.exe.'
                }
            }
            $up = $false
            for ($i = 0; $i -lt 30 -and -not $up -and -not $blocked; $i++) {
                Start-Sleep -Milliseconds 700
                try { Invoke-RestMethod -UseBasicParsing "$SettingsUrl/api/info" -TimeoutSec 2 | Out-Null; $up = $true } catch { }
            }
            if ($up) {
                Write-Ok "O NikoDeck est\u00e1 em execu\u00e7\u00e3o: configura\u00e7\u00f5es em $SettingsUrl (tamb\u00e9m pelo \u00edcone da bandeja)"
                try { Start-Process $SettingsUrl } catch { }
            } elseif ($blocked) {
                # explained above
            } elseif (-not (Test-Path $exe)) {
                Write-Caution "O NikoDeck.exe foi removido, provavelmente por um antiv\u00edrus. Veja https://github.com/$Upstream/issues/69."
            } else {
                Write-Caution "O agente n\u00e3o respondeu. Log dele: $env:LOCALAPPDATA\NikoDeck\agent.log"
                if ($smartAppControl -eq 1) {
                    Write-Caution 'O Controle Inteligente de Aplicativos pode t\u00ea-lo bloqueado: veja Seguran\u00e7a do Windows > Controle de aplicativos e do navegador, e o aviso acima.'
                }
            }
        }

        Write-Step 'Bom saber'
        if ($phoneDone) { Write-Info 'Deixe o celular conectado: o NikoDeck acorda o celular e abre o painel.' }
        elseif (-not $NoPhone) {
            Write-Info "App do celular depois: conecte o celular e use Configura\u00e7\u00f5es > Geral > Instalar app no celular, ou execute a instala\u00e7\u00e3o de novo."
        }
        Write-Info 'S\u00f3 Wi-Fi: instale o app pela p\u00e1gina de vers\u00f5es no celular e, no computador, abra'
        Write-Info 'Configura\u00e7\u00f5es > Geral > Wi-Fi & Tailscale > Parear celular via Wi-Fi e escaneie o QR code.'
        Write-Info 'Quando voc\u00ea ativar o Wi-Fi, o Windows vai pedir para liberar o NikoDeck no firewall: permita apenas redes privadas.'
        Write-Info "At\u00e9 l\u00e1, o NikoDeck s\u00f3 escuta neste computador. Todas as conex\u00f5es que ele faz: https://github.com/$Repo/blob/main/PRIVACY.md"
        Write-Info 'Atualiza\u00e7\u00f5es: o NikoDeck se atualiza pelas Configura\u00e7\u00f5es. Execute a instala\u00e7\u00e3o de novo quando quiser para repar\u00e1-lo.'
        Write-Info "Desinstalar: & ([scriptblock]::Create((irm https://raw.githubusercontent.com/$Repo/main/scripts/uninstall.ps1))) [-Purge] [-Apk]"
    } finally {
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Everything runs from here, so a download cut off half way cannot run half a script.
try {
    Install-PhoneBox
    $global:LASTEXITCODE = 0   # optional native checks (gh, winget) may have left a non-zero code; setup succeeded
} catch {
    $message = Expand-Text "$($_.Exception.Message)"
    Write-Host ''
    Write-Host (Expand-Text "A instala\u00e7\u00e3o parou: $message") -ForegroundColor Red
    Write-Host "Ajuda: https://github.com/$Repo#quick-start  -  problemas: https://github.com/$Repo/issues" -ForegroundColor Red
    if (-not (Test-Interactive)) { throw $message }   # unattended runs must fail visibly
}
