[CmdletBinding()]
param(
    [ValidateSet('Start', 'Run', 'Stop', 'Status')]
    [string]$Action = 'Status',

    [string]$ExecutablePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'build_codex_x64_live\windows\x64\runner\Debug\Chessever.exe'),

    [string]$DiagnosticsRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ChessEverDiagnostics'),

    [ValidateRange(1, 20)]
    [int]$MaxDumps = 5
)

$ErrorActionPreference = 'Stop'

$toolsDirectory = Join-Path $DiagnosticsRoot 'tools\procdump'
$dumpDirectory = Join-Path $DiagnosticsRoot 'dumps'
$logDirectory = Join-Path $DiagnosticsRoot 'logs'
$monitorStatePath = Join-Path $DiagnosticsRoot 'monitor-state.json'
$procdumpStatePath = Join-Path $DiagnosticsRoot 'procdump-state.json'
$logPath = Join-Path $logDirectory 'hang-monitor.log'
$procdumpPath = Join-Path $toolsDirectory 'procdump64.exe'

function Initialize-DiagnosticsDirectory {
    New-Item -ItemType Directory -Force -Path $DiagnosticsRoot, $dumpDirectory, $logDirectory | Out-Null
}

function Write-MonitorLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    Initialize-DiagnosticsDirectory
    $timestamp = [DateTime]::UtcNow.ToString('o')
    Add-Content -LiteralPath $logPath -Value "$timestamp $Message" -Encoding UTF8
}

function Write-ProcessState {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $state = [ordered]@{
        pid = $Process.Id
        process_name = $Process.ProcessName
        started_at_utc = $Process.StartTime.ToUniversalTime().ToString('o')
        role = $Role
        script_path = $PSCommandPath
        executable_path = $ExecutablePath
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-TrackedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string[]]$AllowedNames
    )

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        $process = Get-Process -Id ([int]$state.pid) -ErrorAction Stop
        if ($AllowedNames -notcontains $process.ProcessName) {
            return $null
        }
        $trackedStart = [DateTime]::Parse($state.started_at_utc).ToUniversalTime()
        $actualStart = $process.StartTime.ToUniversalTime()
        if ([Math]::Abs(($actualStart - $trackedStart).TotalSeconds) -gt 1) {
            return $null
        }
        return $process
    }
    catch {
        return $null
    }
}

function Get-TargetProcess {
    $expectedPath = [IO.Path]::GetFullPath($ExecutablePath)
    foreach ($process in Get-Process -Name 'Chessever' -ErrorAction SilentlyContinue) {
        try {
            $actualPath = [IO.Path]::GetFullPath($process.Path)
            if ([string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
                return $process
            }
        }
        catch {
            continue
        }
    }
    return $null
}

function Remove-StateFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Rotate-HangDumps {
    $dumps = @(Get-ChildItem -LiteralPath $dumpDirectory -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($dumps.Count -le $MaxDumps) {
        return
    }

    foreach ($dump in $dumps[$MaxDumps..($dumps.Count - 1)]) {
        Remove-Item -LiteralPath $dump.FullName -Force
        Write-MonitorLog "Removed old dump after retention limit: $($dump.Name)"
    }
}

function Show-MonitorStatus {
    Initialize-DiagnosticsDirectory
    $monitor = Get-TrackedProcess -StatePath $monitorStatePath -AllowedNames @('powershell', 'pwsh')
    $target = Get-TargetProcess
    $dumps = @(Get-ChildItem -LiteralPath $dumpDirectory -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)

    [pscustomobject]@{
        MonitorRunning = $null -ne $monitor
        MonitorPid = if ($monitor) { $monitor.Id } else { $null }
        TargetRunning = $null -ne $target
        TargetPid = if ($target) { $target.Id } else { $null }
        TargetResponding = if ($target) { $target.Responding } else { $null }
        TargetPath = $ExecutablePath
        DumpCount = $dumps.Count
        LatestDump = if ($dumps.Count -gt 0) { $dumps[0].FullName } else { $null }
        LogPath = $logPath
    } | Format-List
}

function Start-MonitorBackground {
    Initialize-DiagnosticsDirectory
    if (-not (Test-Path -LiteralPath $procdumpPath)) {
        throw "ProcDump is missing at $procdumpPath"
    }

    $existing = Get-TrackedProcess -StatePath $monitorStatePath -AllowedNames @('powershell', 'pwsh')
    if ($existing) {
        Show-MonitorStatus
        return
    }
    Remove-StateFile -Path $monitorStatePath
    Remove-StateFile -Path $procdumpStatePath

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-Action', 'Run',
        '-ExecutablePath', ('"{0}"' -f $ExecutablePath),
        '-DiagnosticsRoot', ('"{0}"' -f $DiagnosticsRoot),
        '-MaxDumps', $MaxDumps
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        $started = Get-TrackedProcess -StatePath $monitorStatePath -AllowedNames @('powershell', 'pwsh')
    } while (-not $started -and [DateTime]::UtcNow -lt $deadline)

    if (-not $started) {
        throw "The ChessEver hang monitor did not start. Check $logPath"
    }
    Show-MonitorStatus
}

function Stop-Monitor {
    $procdump = Get-TrackedProcess -StatePath $procdumpStatePath -AllowedNames @('procdump64', 'procdump')
    if ($procdump) {
        Stop-Process -Id $procdump.Id -Force
    }
    $monitor = Get-TrackedProcess -StatePath $monitorStatePath -AllowedNames @('powershell', 'pwsh')
    if ($monitor) {
        Stop-Process -Id $monitor.Id -Force
    }
    Remove-StateFile -Path $procdumpStatePath
    Remove-StateFile -Path $monitorStatePath
    Write-MonitorLog 'Hang monitor stopped.'
    Show-MonitorStatus
}

function Run-Monitor {
    Initialize-DiagnosticsDirectory
    if (-not (Test-Path -LiteralPath $procdumpPath)) {
        throw "ProcDump is missing at $procdumpPath"
    }

    $self = Get-Process -Id $PID
    Write-ProcessState -Process $self -Path $monitorStatePath -Role 'hang-monitor'
    Write-MonitorLog "Hang monitor started. Waiting for exact executable: $ExecutablePath"

    try {
        while ($true) {
            $target = Get-TargetProcess
            if (-not $target) {
                Start-Sleep -Seconds 2
                continue
            }

            Write-MonitorLog "Attached ProcDump hang trigger to PID $($target.Id): $ExecutablePath"
            $arguments = @(
                '-accepteula',
                '-ma',
                '-h',
                '-n', '1',
                $target.Id,
                $dumpDirectory
            )
            $capture = Start-Process -FilePath $procdumpPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
            Write-ProcessState -Process $capture -Path $procdumpStatePath -Role 'procdump-capture'
            $capture.WaitForExit()
            Remove-StateFile -Path $procdumpStatePath
            Rotate-HangDumps
            Write-MonitorLog "ProcDump exited with code $($capture.ExitCode) for ChessEver PID $($target.Id)."

            while ($true) {
                $current = Get-TargetProcess
                if (-not $current) {
                    break
                }
                try {
                    $current.Refresh()
                    if ($current.Responding) {
                        break
                    }
                }
                catch {
                    break
                }
                Start-Sleep -Seconds 2
            }
            Start-Sleep -Seconds 15
        }
    }
    finally {
        Remove-StateFile -Path $procdumpStatePath
        Remove-StateFile -Path $monitorStatePath
        Write-MonitorLog 'Hang monitor process exited.'
    }
}

switch ($Action) {
    'Start' { Start-MonitorBackground }
    'Run' { Run-Monitor }
    'Stop' { Stop-Monitor }
    'Status' { Show-MonitorStatus }
}
