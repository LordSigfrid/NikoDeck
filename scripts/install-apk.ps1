# The messages are in Brazilian Portuguese, but the .ps1 files stay ASCII: Windows PowerShell 5.1 reads a script without
# a BOM in the ANSI code page, and a BOM would break "irm ... | iex". Accented letters are written as \u00XX (U+00C0 to
# U+00FF only) and turned into the real letters by Expand-Text; scripts/install.ps1 uses it too.
function Expand-Text([string]$Text) {
    [regex]::Replace($Text, '\\u00([c-fC-F][0-9a-fA-F])', [Text.RegularExpressions.MatchEvaluator] {
        param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}

function Install-PhoneBoxApk {
    param([Parameter(Mandatory)][string]$Adb, [Parameter(Mandatory)][string]$ApkPath, [Parameter(Mandatory)][string]$Serial)
    $target = @('-s', $Serial)
    # Windows PowerShell 5.1 turns a native program's stderr lines into errors under -ErrorAction Stop (adb prints
    # "daemon not running; starting now" there), which would hide adb's real answer.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $Adb @target install -r $ApkPath 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    if ($output -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
        throw (Expand-Text 'A chave de assinatura do APK \u00e9 diferente da do app instalado. O app instalado e os dados dele foram mantidos. Compile com a chave de assinatura original.')
    }
    if ($code -ne 0 -or -not ($output -match '^Success\s*$')) { throw ((Expand-Text 'A atualiza\u00e7\u00e3o do APK falhou; o app instalado foi mantido. ') + ($output -join ' ')) }
    $output | Select-Object -Last 1
}
