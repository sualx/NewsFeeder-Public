$ErrorActionPreference = 'Stop'

$applicationScript = Join-Path $PSScriptRoot 'NewsFeeder.ps1'
$processes = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.CommandLine.IndexOf($applicationScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    }

foreach ($process in $processes) {
    Stop-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
    Wait-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
}