$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $env:LOCALAPPDATA 'LGHS-Imager\logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ('launcher-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

function Write-LaunchLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Assert-PowerShellSyntax([string]$Path) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) {
        $detail = ($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
        throw "PowerShell syntax validation failed for $Path`n$detail"
    }
}

Write-LaunchLog "Starting LGHS Imager from $Root"
Write-LaunchLog "PowerShell $($PSVersionTable.PSVersion) / user=$env:USERNAME"

try {
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

    $AppScript = Join-Path $Root 'app\LGHS-Imager-v4.ps1'
    $HelperScript = Join-Path $Root 'app\LGHS-StockBootstrap-v2.ps1'
    if (-not (Test-Path $AppScript)) { throw "Application script not found: $AppScript" }
    if (-not (Test-Path $HelperScript)) { throw "Bootstrap helper not found: $HelperScript" }
    Assert-PowerShellSyntax $AppScript
    Assert-PowerShellSyntax $HelperScript
    Write-LaunchLog 'LGHS Imager v4 PowerShell syntax validation passed.'

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-LaunchLog "Elevated=$isAdmin"

    if (-not $isAdmin) {
        Write-LaunchLog 'Requesting elevation through UAC.'
        $Self = $MyInvocation.MyCommand.Path
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $Self
        $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine -PassThru
        Write-LaunchLog "Elevated wrapper started, PID=$($proc.Id)"
        exit 0
    }

    Write-LaunchLog 'Launching LGHS Imager v4.'
    & $AppScript -SkipUpdate
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
