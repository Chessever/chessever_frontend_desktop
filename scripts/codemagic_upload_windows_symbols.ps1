param(
    [string]$SymbolDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PubspecReleaseVersion {
    $versionLine = Get-Content pubspec.yaml |
        Select-String '^version:' |
        Select-Object -First 1
    if (-not $versionLine) {
        throw 'unable to read version from pubspec.yaml'
    }

    $releaseVersion = (($versionLine.Line -split ':', 2)[1]).Trim()
    if ([string]::IsNullOrWhiteSpace($releaseVersion)) {
        throw 'pubspec.yaml version must not be empty'
    }
    $releaseVersion
}

function Get-SentryCommand {
    # Current Sentry CLI releases install the `sentry` executable. Keep the
    # legacy command fallback so an existing Codemagic image remains usable.
    $command = Get-Command sentry -ErrorAction SilentlyContinue
    if ($command) {
        return $command
    }
    Get-Command sentry-cli -ErrorAction SilentlyContinue
}

function Invoke-WindowsSymbolUpload {
    $repo = (Get-Location).Path
    $resolvedSymbolDir = $SymbolDir
    if ([string]::IsNullOrWhiteSpace($resolvedSymbolDir)) {
        $releaseVersion = Get-PubspecReleaseVersion
        $resolvedSymbolDir = Join-Path $repo "build\windows\x64\native-symbols\$releaseVersion"
    }

    if (-not (Test-Path -LiteralPath $resolvedSymbolDir -PathType Container)) {
        Write-Warning "Native symbol upload skipped: symbol directory is missing at $resolvedSymbolDir"
        return
    }

    $pdbs = @(
        Get-ChildItem -LiteralPath $resolvedSymbolDir -Recurse -File -Filter '*.pdb'
    )
    if ($pdbs.Count -eq 0) {
        Write-Warning "Native symbol upload skipped: no PDB files were collected in $resolvedSymbolDir"
        return
    }

    $flutterEnginePdb = Join-Path $resolvedSymbolDir 'flutter-engine\flutter_windows.dll.pdb'
    if (-not (Test-Path -LiteralPath $flutterEnginePdb -PathType Leaf)) {
        Write-Warning (
            'flutter_windows.dll.pdb was not available from the active Flutter SDK; ' +
            'uploading the available runner/plugin PDBs.'
        )
    }

    # The token remains in the process environment and is never placed on the
    # command line or written to logs.
    $requiredConfiguration = @(
        'SENTRY_AUTH_TOKEN'
        'SENTRY_ORG'
        'SENTRY_PROJECT'
    )
    $missingConfiguration = @(
        $requiredConfiguration | Where-Object {
            [string]::IsNullOrWhiteSpace(
                [Environment]::GetEnvironmentVariable($_)
            )
        }
    )
    if ($missingConfiguration.Count -gt 0) {
        Write-Warning (
            'Native symbol upload skipped. Add these protected variables to ' +
            'the chessever-desktop-release Codemagic group: ' +
            ($missingConfiguration -join ', ')
        )
        return
    }

    $sentryCommand = Get-SentryCommand
    if (-not $sentryCommand) {
        $npm = Get-Command npm -ErrorAction SilentlyContinue
        if (-not $npm) {
            Write-Warning 'Native symbol upload skipped: npm is unavailable to install the Sentry CLI.'
            return
        }

        Write-Host 'Sentry CLI is not installed; installing it for this CI job.'
        & $npm.Source install --global 'sentry'
        $npmExitCode = $LASTEXITCODE
        if ($npmExitCode -ne 0) {
            Write-Warning "Native symbol upload skipped: Sentry CLI installation exited with code $npmExitCode."
            return
        }
        $sentryCommand = Get-SentryCommand
    }

    if (-not $sentryCommand) {
        Write-Warning 'Native symbol upload skipped: Sentry CLI was not found after installation.'
        return
    }

    Write-Host "Uploading $($pdbs.Count) native Windows PDB(s) to Sentry."
    $symbolDir = $resolvedSymbolDir
    $uploadArguments = @("debug-files", "upload", "--wait", $symbolDir)
    & $sentryCommand.Source @uploadArguments
    $uploadExitCode = $LASTEXITCODE
    if ($uploadExitCode -ne 0) {
        Write-Warning "Native symbol upload failed with exit code $uploadExitCode; release publication will continue."
        return
    }

    Write-Host 'Native Windows debug symbols uploaded successfully.'
}

try {
    Invoke-WindowsSymbolUpload
} catch {
    Write-Warning (
        'Native symbol upload encountered a non-fatal error; release ' +
        "publication will continue. $($_.Exception.Message)"
    )
}
