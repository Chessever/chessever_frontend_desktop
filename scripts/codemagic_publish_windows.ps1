param(
    [switch]$SkipUpload
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PubspecRelease {
    $versionLine = Get-Content pubspec.yaml |
        Select-String '^version:' |
        Select-Object -First 1
    if (-not $versionLine) {
        throw 'unable to read version from pubspec.yaml'
    }

    $versionRaw = (($versionLine.Line -split ':', 2)[1]).Trim()
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

    [PSCustomObject]@{
        Version = $version
        Build = $build
        ReleaseVersion = "$version+$build"
        ArchiveName = "$version+$build-windows"
    }
}

function Get-PubspecPackageName {
    $nameLine = Get-Content pubspec.yaml |
        Select-String '^name:' |
        Select-Object -First 1
    if (-not $nameLine) {
        throw 'unable to read package name from pubspec.yaml'
    }
    (($nameLine.Line -split ':', 2)[1]).Trim()
}

function Get-ExpectedDartDefineKeys {
    $required = @(
        'SUPABASE_URL',
        'SUPABASE_ANON_KEY',
        'GOOGLE_DESKTOP_CLIENT_ID',
        'GOOGLE_DESKTOP_CLIENT_SECRET',
        'SENTRY_FLUTTER'
    )
    $optional = @('GOOGLE_WEB_CLIENT_ID', 'BILLING_API_BASE', 'GAMEBASE_PROXY_BASE')
    $keys = New-Object System.Collections.Generic.List[string]

    foreach ($name in $required) {
        if (-not [Environment]::GetEnvironmentVariable($name)) {
            throw "$name is required for release dart-define verification"
        }
        $keys.Add($name)
    }

    foreach ($name in $optional) {
        if ([Environment]::GetEnvironmentVariable($name)) {
            $keys.Add($name)
        }
    }

    ($keys.ToArray() -join ',')
}

function Get-InnoSetupCompiler {
    $command = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    throw 'Inno Setup compiler (ISCC.exe) is required to build the Windows installer'
}

function New-WindowsInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Release,
        [Parameter(Mandatory = $true)]
        [string]$BuildDir
    )

    $iscc = Get-InnoSetupCompiler
    $installerScript = Join-Path $repo 'windows\installer\chessever.iss'
    $installerOutput = Join-Path $repo 'windows\installer\output'
    if (Test-Path $installerOutput) {
        Remove-Item $installerOutput -Recurse -Force
    }
    New-Item -ItemType Directory -Path $installerOutput -Force | Out-Null

    $isccOutput = & $iscc `
        $installerScript `
        "/DAppVersion=$($Release.Version)" `
        "/DAppBuild=$($Release.Build)" `
        "/DBuildDir=$BuildDir" `
        "/O$installerOutput" 2>&1
    $isccExitCode = $LASTEXITCODE
    if ($isccOutput) {
        $isccOutput | ForEach-Object { Write-Host $_ }
    }
    if ($isccExitCode -ne 0) {
        throw "Inno Setup failed with exit code $isccExitCode"
    }

    $installerPath = Join-Path $installerOutput "chessever-$($Release.ReleaseVersion)-setup.exe"
    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "missing Windows installer at $installerPath"
    }

    Write-Host "Built Windows installer $installerPath"
    $installerPath
}

function Invoke-ReleaseEnvCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedKeys
    )

    $exe = Get-ChildItem -Path $DirectoryPath -Filter '*.exe' |
        Sort-Object Name |
        Select-Object -First 1
    if (-not $exe) {
        throw "missing Windows app executable in $DirectoryPath"
    }

    Write-Host "Verifying release dart-defines in $($exe.FullName)"
    $stdoutPath = [IO.Path]::GetTempFileName()
    $stderrPath = [IO.Path]::GetTempFileName()
    try {
        $process = Start-Process `
            -FilePath $exe.FullName `
            -ArgumentList @("--verify-release-env=$ExpectedKeys") `
            -WorkingDirectory $DirectoryPath `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath

        $stdoutText = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
        $stderrText = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
        if ($stdoutText) {
            Write-Host $stdoutText.Trim()
        }
        if ($stderrText) {
            Write-Host $stderrText.Trim()
        }

        $probeLine = $stdoutText -split "`r?`n" |
            Where-Object { $_.TrimStart().StartsWith('{') } |
            Select-Object -Last 1
        if (-not $probeLine) {
            throw "release dart-define verification did not emit JSON for $($exe.FullName)"
        }

        $probe = $probeLine | ConvertFrom-Json
        if (-not $probe.ok) {
            throw "release dart-define verification failed for $($exe.FullName): missing $($probe.missing -join ', ')"
        }
        if ($process.ExitCode -ne 0) {
            throw "release dart-define verification exited with code $($process.ExitCode) for $($exe.FullName)"
        }
    } finally {
        Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-DesktopUpdaterArchiveContract {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchiveDir
    )

    $hashesPath = Join-Path $ArchiveDir 'hashes.json'
    if (-not (Test-Path -LiteralPath $hashesPath -PathType Leaf)) {
        throw "desktop_updater archive missing hashes.json at $ArchiveDir"
    }

    $decodedEntries = Get-Content -LiteralPath $hashesPath -Raw | ConvertFrom-Json
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($decodedEntries)) {
        if ($entry -is [Array]) {
            foreach ($nestedEntry in $entry) {
                [void]$entries.Add($nestedEntry)
            }
        } else {
            [void]$entries.Add($entry)
        }
    }
    $listed = New-Object 'System.Collections.Generic.HashSet[string]'
    $missing = New-Object 'System.Collections.Generic.List[string]'
    $unsafe = New-Object 'System.Collections.Generic.List[string]'

    foreach ($entry in $entries) {
        $pathProperty = $entry.PSObject.Properties['path']
        if (-not $pathProperty) {
            $pathProperty = $entry.PSObject.Properties['filePath']
        }
        $rel = if ($pathProperty) { [string]$pathProperty.Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($rel) -or [IO.Path]::IsPathRooted($rel) -or ($rel -split '/') -contains '..') {
            $propertyNames = @($entry.PSObject.Properties | ForEach-Object { $_.Name }) -join ','
            $unsafe.Add("<$rel properties=$propertyNames>")
            continue
        }

        [void]$listed.Add($rel)
        $localPath = Join-Path $ArchiveDir ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
            $missing.Add($rel)
        }
    }

    $extra = New-Object 'System.Collections.Generic.List[string]'
    $archiveRoot = (Resolve-Path -LiteralPath $ArchiveDir).Path.TrimEnd('\', '/')
    $archivePrefix = $archiveRoot + [IO.Path]::DirectorySeparatorChar
    Get-ChildItem -LiteralPath $ArchiveDir -Recurse -File | ForEach-Object {
        $fullPath = $_.FullName
        if (-not $fullPath.StartsWith($archivePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "archive file is outside archive root: $fullPath"
        }
        $rel = $fullPath.Substring($archivePrefix.Length) -replace '\\', '/'
        if ($rel -eq 'hashes.json' -or $rel -eq '.DS_Store' -or $rel -eq '.desktop_updater_manifest.json' -or $rel.StartsWith('update/')) {
            return
        }
        if (-not $listed.Contains($rel)) {
            $extra.Add($rel)
        }
    }

    if ($unsafe.Count -gt 0 -or $missing.Count -gt 0 -or $extra.Count -gt 0) {
        if ($unsafe.Count -gt 0) { Write-Error "unsafe hashes.json paths: $($unsafe -join ', ')" }
        if ($missing.Count -gt 0) { Write-Error "hashes.json lists missing files: $($missing -join ', ')" }
        if ($extra.Count -gt 0) { Write-Error "archive contains unhashed regular files: $($extra -join ', ')" }
        throw 'desktop_updater archive contract validation failed'
    }

    Write-Host "Validated desktop_updater archive contract: $($listed.Count) hashed files"
}

$repo = (Get-Location).Path
$release = Get-PubspecRelease
$packageName = Get-PubspecPackageName
$expectedDartDefineKeys = Get-ExpectedDartDefineKeys
$buildDir = Join-Path $repo 'build\windows\x64\runner\Release'
if (-not (Test-Path $buildDir)) {
    throw "missing $buildDir - run dart run desktop_updater:release windows first"
}

dart run tool/verify_windows_release_bundle.dart
if ($LASTEXITCODE -ne 0) {
    throw "Windows release bundle verification failed with exit code $LASTEXITCODE"
}
Invoke-ReleaseEnvCheck -DirectoryPath $buildDir -ExpectedKeys $expectedDartDefineKeys

$stagedDir = Join-Path $repo "dist\$($release.Build)\$packageName-$($release.ReleaseVersion)-windows"
if (-not (Test-Path $stagedDir)) {
    throw "missing desktop_updater release directory at $stagedDir"
}
Invoke-ReleaseEnvCheck -DirectoryPath $stagedDir -ExpectedKeys $expectedDartDefineKeys

dart run desktop_updater:archive windows
if ($LASTEXITCODE -ne 0) {
    throw "desktop_updater archive failed with exit code $LASTEXITCODE"
}

$archiveDir = Join-Path $repo "dist\$($release.Build)\$($release.ArchiveName)"
Assert-DesktopUpdaterArchiveContract -ArchiveDir $archiveDir

Write-Host "Prepared desktop_updater Windows archive $archiveDir"

$installerPath = New-WindowsInstaller -Release $release -BuildDir $buildDir

if ($SkipUpload) {
    Write-Host 'SkipUpload set; not uploading or ingesting app archive.'
    exit 0
}

if (-not $env:CODEMAGIC_PUBLISHER_KEY) {
    throw 'CODEMAGIC_PUBLISHER_KEY is required to publish the Windows archive'
}

$keyPath = Join-Path $env:TEMP 'codemagic_publisher_ed25519'
$keyContent = ($env:CODEMAGIC_PUBLISHER_KEY -replace "`r`n", "`n") + "`n"
[IO.File]::WriteAllText($keyPath, $keyContent, [Text.UTF8Encoding]::new($false))
icacls $keyPath /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null

$remote = 'codemagic-publisher@157.245.243.138'
& ssh -i $keyPath -o StrictHostKeyChecking=accept-new $remote 'prepare'
if ($LASTEXITCODE -ne 0) {
    throw "remote prepare failed with exit code $LASTEXITCODE"
}

& scp -O -r -i $keyPath -o StrictHostKeyChecking=accept-new $archiveDir "${remote}:/var/www/updates/desktop/archive/"
if ($LASTEXITCODE -ne 0) {
    throw "archive upload failed with exit code $LASTEXITCODE"
}

& ssh -i $keyPath -o StrictHostKeyChecking=accept-new $remote "ingest windows $($release.ArchiveName) $($release.ReleaseVersion)"
if ($LASTEXITCODE -ne 0) {
    throw "app archive ingest failed with exit code $LASTEXITCODE"
}

# Publish a downloadable installer to a stable URL for the website
# "Download for Windows" button. Versioned copy lives next to it.
$versionedInstallerName = "Chessever-$($release.ReleaseVersion)-Setup.exe"
& scp -O -i $keyPath -o StrictHostKeyChecking=accept-new $installerPath "${remote}:/var/www/updates/desktop/downloads/$versionedInstallerName"
if ($LASTEXITCODE -ne 0) {
    throw "windows installer upload (versioned) failed with exit code $LASTEXITCODE"
}
& scp -O -i $keyPath -o StrictHostKeyChecking=accept-new $installerPath "${remote}:/var/www/updates/desktop/downloads/Chessever-Setup.exe"
if ($LASTEXITCODE -ne 0) {
    throw "windows installer upload (latest) failed with exit code $LASTEXITCODE"
}

Write-Host "Published Windows desktop_updater archive $($release.ReleaseVersion)"
Write-Host "Published Windows installer: https://chessever.com/updates/desktop/downloads/Chessever-Setup.exe"
