param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$buildDir = Join-Path $root '.build'
$cacheDir = Join-Path $buildDir 'cache'
$stageDir = Join-Path $buildDir 'stage'
$runtimeDir = Join-Path $stageDir 'runtime'
$artifactsDir = Join-Path $root 'artifacts'
$runtimeVersion = '7.6.5'
$runtimeArchiveName = "PowerShell-$runtimeVersion-win-x64.zip"
$runtimeArchive = Join-Path $cacheDir $runtimeArchiveName
$runtimeUrl = "https://github.com/PowerShell/PowerShell/releases/download/v$runtimeVersion/$runtimeArchiveName"
$runtimeSha256 = '32EB8F6CDCE08F86E987D625A2733E54AC3E289AE7E1621B14C0B5BCEC2434EA'

foreach ($directory in @($cacheDir, $stageDir, $artifactsDir)) {
    if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
}

if (-not (Test-Path $runtimeArchive)) {
    Write-Host "Downloading the pinned PowerShell $runtimeVersion runtime..."
    Invoke-WebRequest -Uri $runtimeUrl -OutFile $runtimeArchive
}

$actualHash = (Get-FileHash $runtimeArchive -Algorithm SHA256).Hash
if ($actualHash -ne $runtimeSha256) {
    throw "PowerShell runtime checksum mismatch. Expected $runtimeSha256 but received $actualHash."
}

$appFiles = @('NewsFeeder.ps1', 'NewsFeeder.vbs', 'NewsFeeder.cmd', 'feeds.json', 'README.md', 'LICENSE')
$installerFiles = $appFiles + 'installer\Stop-NewsFeeder.ps1'
foreach ($file in $installerFiles) {
    $destinationName = Split-Path $file -Leaf
    Copy-Item (Join-Path $root $file) (Join-Path $stageDir $destinationName) -Force
}

if (-not (Test-Path (Join-Path $runtimeDir 'pwsh.exe'))) {
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    Expand-Archive -Path $runtimeArchive -DestinationPath $runtimeDir
}

$sourceArchive = Join-Path $artifactsDir 'NewsFeeder-Source.zip'
Compress-Archive -Path ($appFiles | ForEach-Object { Join-Path $stageDir $_ }) -DestinationPath $sourceArchive -Force

$isccCandidates = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
) | Where-Object { $_ -and (Test-Path $_) }
$iscc = $isccCandidates | Select-Object -First 1
if (-not $iscc) {
    throw 'Inno Setup 6 is required to build the installer. Install it, then run this script again.'
}

$issPath = Join-Path $PSScriptRoot 'NewsFeeder.iss'
& $iscc "/DAppVersion=$Version" "/DSourceDir=$stageDir" "/DOutputDir=$artifactsDir" $issPath
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE." }

$installer = Join-Path $artifactsDir 'NewsFeeder-Setup.exe'
if (-not (Test-Path $installer)) { throw "Expected installer was not created: $installer" }

Get-FileHash $sourceArchive, $installer -Algorithm SHA256 |
    Select-Object Path, Hash |
    Format-Table -AutoSize