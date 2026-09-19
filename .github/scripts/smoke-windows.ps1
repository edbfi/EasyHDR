# Launch the shipped Windows executable with disposable application state.
param(
    [string]$Executable = "target/release/easyhdr.exe",
    [int]$TimeoutSeconds = 30
)
$ErrorActionPreference = "Stop"
if (-not $IsWindows) { throw "EasyHDR startup smoke requires Windows." }
if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 120) { throw "Invalid startup timeout." }
if (Get-Process -Name easyhdr -ErrorAction SilentlyContinue) {
    throw "An EasyHDR instance already exists; refusing to test or stop it."
}
$binary = (Resolve-Path $Executable).Path
$state = Join-Path ([IO.Path]::GetTempPath()) ("easyhdr-smoke-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $state | Out-Null
$previousAppData = $env:APPDATA
$app = $null
try {
    $env:APPDATA = $state
    $app = Start-Process -FilePath $binary -PassThru
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    $logPath = Join-Path $state "EasyHDR/app.log"
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $app.Refresh()
        if ($app.HasExited) { throw "EasyHDR exited before readiness (exit $($app.ExitCode))." }
        $eventLoopStarted = (Test-Path $logPath) -and
            (Select-String -Path $logPath -SimpleMatch "Starting GUI event loop" -Quiet)
        if ($app.MainWindowHandle -ne 0 -and $app.MainWindowTitle -eq "EasyHDR" -and
            $app.Responding -and $eventLoopStarted) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) { throw "EasyHDR did not show a responsive main window within $TimeoutSeconds seconds." }
    # Catch an immediate post-launch crash while exercising the real event loop.
    Start-Sleep -Seconds 1
    $app.Refresh()
    if ($app.HasExited -or $app.MainWindowHandle -eq 0 -or -not $app.Responding) {
        throw "EasyHDR lost its responsive main window after startup."
    }
    Write-Output "EasyHDR release executable reached its responsive GUI in $($watch.Elapsed.TotalMilliseconds) ms."
} finally {
    try {
        if ($null -ne $app) {
            if (-not $app.HasExited) {
                Stop-Process -Id $app.Id -Force
                if (-not $app.WaitForExit(5000)) { throw "EasyHDR smoke process did not stop." }
            }
            $app.Dispose()
        }
    } finally {
        $env:APPDATA = $previousAppData
        $logPath = Join-Path $state "EasyHDR/app.log"
        if (Test-Path $logPath) { Get-Content $logPath }
        Remove-Item -LiteralPath $state -Recurse -Force
    }
}
