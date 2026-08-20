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

function Set-LghsDirectEthernet {
    try {
        $adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and $_.InterfaceDescription -match '(?i)(USB.*(GbE|Ethernet)|Realtek USB GbE)'
        })
        if ($adapters.Count -eq 0) {
            $fallback = Get-NetAdapter -Name 'Ethernet' -ErrorAction SilentlyContinue
            if ($fallback -and $fallback.Status -eq 'Up') { $adapters = @($fallback) }
        }
        if ($adapters.Count -eq 0) {
            Write-LaunchLog 'Direct Ethernet: no active USB/wired adapter found; skipped.'
            return
        }

        $adapter = $null
        foreach ($candidate in $adapters) {
            $cfg = Get-NetIPConfiguration -InterfaceIndex $candidate.ifIndex -ErrorAction SilentlyContinue
            if (-not $cfg.IPv4DefaultGateway) { $adapter = $candidate; break }
        }
        if (-not $adapter) {
            Write-LaunchLog 'Direct Ethernet: all candidate wired adapters have an IPv4 gateway; refusing to alter an Internet-facing connection.'
            return
        }

        $ifIndex = [int]$adapter.ifIndex
        $desired = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -IPAddress '192.168.50.1' -ErrorAction SilentlyContinue
        if (-not $desired) {
            Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like '169.254.*' -or $_.IPAddress -like '192.168.50.*' } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress '192.168.50.1' -PrefixLength 24 -AddressFamily IPv4 -ErrorAction Stop | Out-Null
        }
        Set-NetConnectionProfile -InterfaceIndex $ifIndex -NetworkCategory Private -ErrorAction SilentlyContinue
        Write-LaunchLog "Direct Ethernet ready: $($adapter.Name) / $($adapter.InterfaceDescription) = 192.168.50.1/24 (no gateway)."
    } catch {
        Write-LaunchLog "Direct Ethernet setup warning: $($_.Exception.Message)"
    }
}

Write-LaunchLog "Starting LGHS Imager from $Root"
Write-LaunchLog "PowerShell $($PSVersionTable.PSVersion) / user=$env:USERNAME"
$RuntimeScript = $null

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

    $SourceApp = Join-Path $Root 'app\LGHS-Imager-v4.ps1'
    $HelperScript = Join-Path $Root 'app\LGHS-StockBootstrap-v5.ps1'
    if (-not (Test-Path $SourceApp)) { throw "Application script not found: $SourceApp" }
    if (-not (Test-Path $HelperScript)) { throw "Bootstrap helper not found: $HelperScript" }
    Assert-PowerShellSyntax $SourceApp
    Assert-PowerShellSyntax $HelperScript

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

    Set-LghsDirectEthernet

    # Keep the stable v4 WPF UI, but change the stock-image path to current
    # Raspberry Pi OS cloud-init customisation. No firstrun.sh or systemd.run is
    # created by this runtime.
    $RuntimeScript = Join-Path $Root 'app\LGHS-Imager-runtime.ps1'
    $appText = Get-Content $SourceApp -Raw
    $appText = $appText.Replace('LGHS-StockBootstrap-v2.ps1','LGHS-StockBootstrap-v5.ps1')
    $appText = $appText.Replace('$credentials=$null;$firstRunPath=$null','$credentials=$null;$cloudInitPath=$null')
    $appText = $appText.Replace("Append-Log 'No published LGHS image found. Using official Raspberry Pi OS arm64 with LGHS first-run bootstrap.'","Append-Log 'No published LGHS image found. Using official Raspberry Pi OS arm64 with cloud-init provisioning.'")

    $oldBootstrap = @'
            $firstRunPath=Join-Path $env:TEMP ("lghs-firstrun-{0}.sh" -f [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($firstRunPath,(New-LghsStockBootstrapScript $Config),[Text.UTF8Encoding]::new($false))
            $cliArgs+=@('--first-run-script',$firstRunPath);Append-Log 'LGHS stock first-run bootstrap attached.'
'@
    $newBootstrap = @'
            $cloudInitPath=Join-Path $env:TEMP ("lghs-cloudinit-{0}.yaml" -f [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($cloudInitPath,(New-LghsCloudInitUserData),[Text.UTF8Encoding]::new($false))
            $cliArgs+=@('--cloudinit-userdata',$cloudInitPath);Append-Log 'LGHS cloud-init bootstrap attached; legacy firstrun disabled.'
'@
    if (-not $appText.Contains($oldBootstrap)) { throw 'Could not patch stock bootstrap block in LGHS Imager v4.' }
    $appText = $appText.Replace($oldBootstrap,$newBootstrap)
    $appText = $appText.Replace("if(`$source.StockBootstrap){Append-Log 'First boot applies accounts/passwords/SSH locally. LGHS-System installation retries automatically when network becomes available.'}","if(`$source.StockBootstrap){Append-Log 'Cloud-init starts LGHS stage 2 during a normal boot. LGHS-System installation retries when network becomes available.'}")
    $appText = $appText.Replace('}finally{if($firstRunPath){Remove-Item $firstRunPath -Force -ErrorAction SilentlyContinue};Set-Busy $false}','}finally{if($cloudInitPath){Remove-Item $cloudInitPath -Force -ErrorAction SilentlyContinue};Set-Busy $false}')
    $appText = $appText.Replace("Append-Log 'Missing LGHS images use stock Raspberry Pi OS ARM64 with an injected LGHS first-run bootstrap.'","Append-Log 'Missing LGHS images use stock Raspberry Pi OS ARM64 with cloud-init provisioning; firstrun/systemd.run is not used.'")

    if ($appText -match '--first-run-script|lghs-firstrun') {
        throw 'Safety check failed: legacy first-run injection is still present in the runtime.'
    }
    if ($appText -notmatch '--cloudinit-userdata') {
        throw 'Safety check failed: cloud-init injection was not installed in the runtime.'
    }

    [IO.File]::WriteAllText($RuntimeScript,$appText,[Text.UTF8Encoding]::new($false))
    Assert-PowerShellSyntax $RuntimeScript
    Write-LaunchLog 'LGHS Imager runtime syntax validation passed; cloud-init bootstrap v5 selected.'

    Write-LaunchLog 'Launching LGHS Imager.'
    & $RuntimeScript -SkipUpdate
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
finally {
    if ($RuntimeScript) { Remove-Item $RuntimeScript -Force -ErrorAction SilentlyContinue }
}
