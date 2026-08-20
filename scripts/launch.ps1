$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $env:LOCALAPPDATA 'LGHS-Imager\logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ('launcher-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

function Write-LaunchLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

Write-LaunchLog "Starting LGHS Imager from $Root"
Write-LaunchLog "PowerShell $($PSVersionTable.PSVersion) / user=$env:USERNAME / elevated check pending"

try {
    # Development/source checkouts follow main automatically when they are clean.
    if (Test-Path (Join-Path $Root '.git')) {
        try {
            $dirty = git -C $Root status --porcelain
            if (-not $dirty) {
                Write-LaunchLog 'Checking GitHub main for source-tree updates.'
                git -C $Root fetch origin main --quiet
                $local = (git -C $Root rev-parse HEAD).Trim()
                $remote = (git -C $Root rev-parse origin/main).Trim()
                if ($local -ne $remote) {
                    Write-LaunchLog "Updating source checkout $local -> $remote"
                    git -C $Root pull --ff-only origin main --quiet
                }
            } else {
                Write-LaunchLog 'Source checkout is dirty; automatic git update skipped.'
            }
        } catch {
            Write-LaunchLog "Source update check failed: $($_.Exception.Message)"
        }
    }

    # Installed builds silently check checksummed GitHub release assets.
    try {
        $Updater = Join-Path $Root 'updater\LGHS-Imager-Updater.ps1'
        if (Test-Path $Updater) {
            Write-LaunchLog 'Running automatic updater check.'
            & $Updater
        }
    } catch {
        Write-LaunchLog "Updater check failed: $($_.Exception.Message)"
    }

    # Raw-disk enumeration and post-write provisioning require elevation.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-LaunchLog "Elevated=$isAdmin"

    $AppScript = Join-Path $Root 'app\LGHS-Imager.ps1'
    if (-not (Test-Path $AppScript)) {
        throw "Application script not found: $AppScript"
    }

    if (-not $isAdmin) {
        Write-LaunchLog 'Requesting elevation through UAC.'
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SkipUpdate -LauncherLog "{1}"' -f $AppScript, $LogFile
        $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine -PassThru
        Write-LaunchLog "Elevated process started, PID=$($proc.Id)"
        exit 0
    }

    Write-LaunchLog 'Launching application in current elevated process.'
    & $AppScript -SkipUpdate -LauncherLog $LogFile
    Write-LaunchLog 'Application exited normally.'
}
catch {
    $msg = $_ | Out-String
    Write-LaunchLog "FATAL: $msg"
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show(
            "LGHS Imager could not start.`n`n$($_.Exception.Message)`n`nLog:`n$LogFile",
            'LGHS Imager startup error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch {
        Write-Host $msg
        Write-Host "Log: $LogFile"
    }
    exit 1
}
