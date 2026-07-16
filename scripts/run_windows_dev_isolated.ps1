param(
  [string]$DevDataDir = "",
  [int]$SingleInstancePort = 47684
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

if ([string]::IsNullOrWhiteSpace($DevDataDir)) {
  $DevDataDir = Join-Path $env:APPDATA 'ChessEver Development\Recovered Dev'
}
$devTempDir = Join-Path $env:LOCALAPPDATA 'ChessEver Development\Temp'
New-Item -ItemType Directory -Force -Path $DevDataDir, $devTempDir | Out-Null

$flutterPath = 'C:\flutter\bin\flutter.bat'
if (-not (Test-Path -LiteralPath $flutterPath)) {
  throw 'Flutter was not found at C:\flutter\bin\flutter.bat.'
}

$env:CHESSEVER_DEV_ISOLATED = '1'
$env:TEMP = $devTempDir
$env:TMP = $devTempDir

Write-Host 'Starting isolated ChessEver Development'
Write-Host "  Data: $DevDataDir"
Write-Host "  Port: $SingleInstancePort"

& $flutterPath run -d windows `
  --dart-define=CHESSEVER_DATA_DIR="$DevDataDir" `
  --dart-define=CHESSEVER_SINGLE_INSTANCE_PORT=$SingleInstancePort
exit $LASTEXITCODE
