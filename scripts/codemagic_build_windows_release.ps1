param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PubspecValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $line = Get-Content pubspec.yaml |
        Select-String "^$Name\s*:" |
        Select-Object -First 1
    if (-not $line) {
        throw "unable to read $Name from pubspec.yaml"
    }

    (($line.Line -split ':', 2)[1]).Trim()
}

function Add-DartDefine {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Defines,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [bool]$Required
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Required) {
            throw "$Name is required"
        }
        return
    }

    $Defines.Add("--dart-define=$Name=$value")
}

$repo = (Get-Location).Path
$packageName = Get-PubspecValue -Name 'name'
$versionRaw = Get-PubspecValue -Name 'version'
$versionParts = $versionRaw -split '\+', 2
$version = $versionParts[0].Trim()
$build = if ($versionParts.Count -gt 1) {
    $versionParts[1].Trim()
} else {
    $env:CM_BUILD_NUMBER
}

if (-not $version -or -not $build) {
    throw "pubspec.yaml version must include build metadata, got '$versionRaw'"
}

$dartDefines = [System.Collections.Generic.List[string]]::new()
$required = @(
    'SUPABASE_URL',
    'SUPABASE_ANON_KEY',
    'GOOGLE_DESKTOP_CLIENT_ID',
    'GOOGLE_DESKTOP_CLIENT_SECRET',
    'SENTRY_FLUTTER'
)
$optional = @('GOOGLE_WEB_CLIENT_ID', 'BILLING_API_BASE', 'GAMEBASE_PROXY_BASE')

foreach ($name in $required) {
    Add-DartDefine -Defines $dartDefines -Name $name -Required $true
}
foreach ($name in $optional) {
    Add-DartDefine -Defines $dartDefines -Name $name -Required $false
}

flutter config --enable-windows-desktop
if (Test-Path dist) {
    Remove-Item dist -Recurse -Force
}

flutter build windows --release @dartDefines
if ($LASTEXITCODE -ne 0) {
    throw "flutter build windows failed with exit code $LASTEXITCODE"
}

$buildDir = Join-Path $repo 'build\windows\x64\runner\Release'
if (-not (Test-Path $buildDir)) {
    throw "missing Windows release directory at $buildDir"
}

$stagedDir = Join-Path $repo "dist\$build\$packageName-$version+$build-windows"
if (Test-Path $stagedDir) {
    Remove-Item $stagedDir -Recurse -Force
}
New-Item -ItemType Directory -Path $stagedDir -Force | Out-Null
Copy-Item -Path (Join-Path $buildDir '*') -Destination $stagedDir -Recurse -Force

Write-Host "Archive created at $stagedDir"
