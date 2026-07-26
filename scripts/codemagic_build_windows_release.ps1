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

function Assert-NoRuntimePdbs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    $runtimePdbs = @(
        Get-ChildItem -LiteralPath $DirectoryPath -Recurse -File -Filter '*.pdb'
    )
    if ($runtimePdbs.Count -gt 0) {
        $relativeNames = $runtimePdbs | ForEach-Object { $_.Name }
        throw "runtime package contains native debug symbols: $($relativeNames -join ', ')"
    }
}

function Get-StablePathHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        $digest = $algorithm.ComputeHash($bytes)
        ([BitConverter]::ToString($digest)).Replace('-', '').Substring(0, 16)
    } finally {
        $algorithm.Dispose()
    }
}

function Copy-DebugSymbols {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BuildRoot,
        [Parameter(Mandatory = $true)]
        [string]$ReleaseVersion
    )

    $symbolRoot = Join-Path $BuildRoot 'native-symbols'
    $symbolDir = Join-Path $symbolRoot $ReleaseVersion
    if (Test-Path -LiteralPath $symbolDir) {
        Remove-Item -LiteralPath $symbolDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $symbolDir -Force | Out-Null

    $resolvedBuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path.TrimEnd('\', '/')
    $buildPrefix = $resolvedBuildRoot + [IO.Path]::DirectorySeparatorChar
    $resolvedSymbolRoot = (Resolve-Path -LiteralPath $symbolRoot).Path.TrimEnd('\', '/')
    $symbolPrefix = $resolvedSymbolRoot + [IO.Path]::DirectorySeparatorChar

    # Preserve each target/compiler PDB under a stable short directory. Keeping
    # the original filename helps symbol tooling, while hashing the relative
    # source path prevents collisions and Windows MAX_PATH failures.
    $builtPdbs = @(
        Get-ChildItem -LiteralPath $BuildRoot -Recurse -File -Filter '*.pdb' |
            Where-Object {
                -not $_.FullName.StartsWith(
                    $symbolPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    foreach ($pdb in $builtPdbs) {
        if (-not $pdb.FullName.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "debug symbol is outside the Windows build root: $($pdb.FullName)"
        }
        $relativePath = $pdb.FullName.Substring($buildPrefix.Length)
        $pathHash = Get-StablePathHash -Value $relativePath
        $destinationDir = Join-Path (Join-Path $symbolDir 'cmake-build') $pathHash
        $destination = Join-Path $destinationDir $pdb.Name
        $destinationParent = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath $pdb.FullName -Destination $destination -Force
    }

    # flutter_windows.dll is copied from this exact engine artifact during the
    # Flutter build. Its adjacent PDB is therefore the matching engine symbol
    # file; do not substitute a PDB from a different engine/configuration.
    $flutterCommand = Get-Command flutter -ErrorAction Stop
    $flutterBin = Split-Path -Parent $flutterCommand.Source
    $flutterRoot = Split-Path -Parent $flutterBin
    $enginePdbCandidates = @(
        (Join-Path $repo 'windows\flutter\ephemeral\flutter_windows.dll.pdb')
        (Join-Path $flutterRoot 'bin\cache\artifacts\engine\windows-x64\flutter_windows.dll.pdb')
    )
    $flutterEnginePdb = $enginePdbCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    if ($flutterEnginePdb) {
        $engineSymbolDir = Join-Path $symbolDir 'flutter-engine'
        New-Item -ItemType Directory -Path $engineSymbolDir -Force | Out-Null
        Copy-Item `
            -LiteralPath $flutterEnginePdb `
            -Destination (Join-Path $engineSymbolDir 'flutter_windows.dll.pdb') `
            -Force
        Write-Host "Collected exact Flutter engine PDB from the active Windows engine cache."
    } else {
        Write-Warning (
            'The active Flutter SDK did not provide flutter_windows.dll.pdb; ' +
            'runner/plugin symbols will still be uploaded.'
        )
    }

    $collectedPdbs = @(
        Get-ChildItem -LiteralPath $symbolDir -Recurse -File -Filter '*.pdb'
    )
    if ($collectedPdbs.Count -eq 0) {
        Write-Warning "No native Windows PDBs were produced for $ReleaseVersion."
    } else {
        Write-Host "Collected $($collectedPdbs.Count) native Windows PDB(s) in $symbolDir"
    }

    $symbolDir
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
    'SENTRY_FLUTTER',
    'CHESSEVER_CLOUDFLARE_API_BASE'
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

$windowsBuildRoot = Join-Path $repo 'build\windows\x64'
$releaseVersion = "$version+$build"
$symbolDir = Copy-DebugSymbols `
    -BuildRoot $windowsBuildRoot `
    -ReleaseVersion $releaseVersion

# Linker PDBs can initially land next to their DLL/EXE. They have already been
# preserved above; remove them before either runtime directory is staged.
Get-ChildItem -LiteralPath $buildDir -Recurse -File -Filter '*.pdb' |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
    }
Assert-NoRuntimePdbs -DirectoryPath $buildDir

$stagedDir = Join-Path $repo "dist\$build\$packageName-$version+$build-windows"
if (Test-Path $stagedDir) {
    Remove-Item $stagedDir -Recurse -Force
}
New-Item -ItemType Directory -Path $stagedDir -Force | Out-Null
Copy-Item -Path (Join-Path $buildDir '*') -Destination $stagedDir -Recurse -Force
Assert-NoRuntimePdbs -DirectoryPath $stagedDir

Write-Host "Archive created at $stagedDir"
Write-Host "Native symbols staged separately at $symbolDir"
