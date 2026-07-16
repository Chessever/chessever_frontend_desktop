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

& $flutterPath build windows --debug `
  --dart-define=CHESSEVER_DATA_DIR="$DevDataDir" `
  --dart-define=CHESSEVER_SINGLE_INSTANCE_PORT=$SingleInstancePort
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$exe = Join-Path $repo 'build\windows\x64\runner\Debug\ChessEverDev.exe'
if (-not (Test-Path -LiteralPath $exe)) {
  throw "Build finished but the isolated executable was not found at $exe"
}
Write-Host "Built isolated ChessEver Development: $exe"
Write-Host "Development data: $DevDataDir"
