$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $env:LOCALAPPDATA 'LGHS-Imager\logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ('launcher-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

function Write-LaunchLog([string]$Message) {
    Add-Content -Path $LogFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$Message) -Encoding utf8
}

function Assert-PowerShellSyntax([string]$Path) {
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw (($errors|ForEach-Object{"line $($_.Extent.StartLineNumber): $($_.Message)"})-join"`n")}
}

function Test-LghsAdministrator {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=New-Object Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-LghsDirectEthernet {
    try {
        $adapters=@(Get-NetAdapter -Physical -ErrorAction Stop|Where-Object{$_.Status-eq'Up'-and$_.InterfaceDescription-match'(?i)(USB.*(GbE|Ethernet)|Realtek USB GbE)'})
        if(!$adapters.Count){$f=Get-NetAdapter -Name 'Ethernet' -ErrorAction SilentlyContinue;if($f-and$f.Status-eq'Up'){$adapters=@($f)}}
        if(!$adapters.Count){Write-LaunchLog 'Direct Ethernet: no active USB/wired adapter found; skipped.';return}
        $adapter=$null
        foreach($c in $adapters){$cfg=Get-NetIPConfiguration -InterfaceIndex $c.ifIndex -ErrorAction SilentlyContinue;if(-not$cfg.IPv4DefaultGateway){$adapter=$c;break}}
        if(!$adapter){Write-LaunchLog 'Direct Ethernet: refusing to alter a wired adapter with a default gateway.';return}
        $idx=[int]$adapter.ifIndex
        if(-not(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -IPAddress '192.168.50.1' -ErrorAction SilentlyContinue)){
            Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue|Where-Object{$_.IPAddress-like'169.254.*'-or$_.IPAddress-like'192.168.50.*'}|Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $idx -IPAddress '192.168.50.1' -PrefixLength 24 -AddressFamily IPv4 -ErrorAction Stop|Out-Null
        }
        Set-NetConnectionProfile -InterfaceIndex $idx -NetworkCategory Private -ErrorAction SilentlyContinue
        Write-LaunchLog "Direct Ethernet ready: $($adapter.InterfaceDescription) = 192.168.50.1/24"
    } catch {Write-LaunchLog "Direct Ethernet warning: $($_.Exception.Message)"}
}

Write-LaunchLog "Starting LGHS Imager from $Root"
$RuntimeScript=$null
try {
    if(Test-Path(Join-Path $Root '.git')){
        try{
            $dirty=git -C $Root status --porcelain
            if(-not$dirty){git -C $Root fetch origin main --quiet;$local=(git -C $Root rev-parse HEAD).Trim();$remote=(git -C $Root rev-parse origin/main).Trim();if($local-ne$remote){git -C $Root pull --ff-only origin main --quiet}}
        }catch{Write-LaunchLog "Source update warning: $($_.Exception.Message)"}
    }

    if(-not(Test-LghsAdministrator)){
        $argLine='-NoProfile -ExecutionPolicy Bypass -File "{0}"'-f$MyInvocation.MyCommand.Path
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine|Out-Null
        exit 0
    }

    Write-LaunchLog 'Direct Ethernet setup disabled; Fleet enrollment uses the configured Cloudflare SSH route.'

    $SourceApp=Join-Path $Root 'app\LGHS-Imager-v4.ps1'
    $HelperScript=Join-Path $Root 'app\LGHS-StockBootstrap-v11.ps1'
    Assert-PowerShellSyntax $SourceApp
    Assert-PowerShellSyntax $HelperScript

    $RuntimeScript=Join-Path $Root 'app\LGHS-Imager-runtime.ps1'
    $appText=Get-Content $SourceApp -Raw
    $appText=$appText.Replace('LGHS-StockBootstrap-v2.ps1','LGHS-StockBootstrap-v11.ps1')
    $appText=$appText.Replace('$credentials=$null;$firstRunPath=$null','$credentials=$null;$cloudInitPath=$null')

    # Every managed Control/Student flash explicitly chooses the Pi 5 memory
    # profile before the destructive write. Both profiles use the same arm64 OS.
    $oldFlashHead=@'
function Start-Flash {
    if($script:Busy){return}
    if(-not$DriveBox.SelectedItem){[System.Windows.MessageBox]::Show('Insert and select an SD card first.','LGHS Imager')|Out-Null;return}
'@
    $newFlashHead=@'
function Select-LghsPi5RamProfileBeforeFlash {
    $choice=[System.Windows.MessageBox]::Show("Select the Raspberry Pi 5 RAM profile for this flash.`n`nYES = Pi 5 4 GB`nNO  = Pi 5 8 GB`nCANCEL = do not flash`n`nBoth use the same Raspberry Pi OS 64-bit image.",'LGHS Pi 5 hardware profile',[System.Windows.MessageBoxButton]::YesNoCancel,[System.Windows.MessageBoxImage]::Question)
    if($choice-eq[System.Windows.MessageBoxResult]::Yes){return 4}
    if($choice-eq[System.Windows.MessageBoxResult]::No){return 8}
    return $null
}

function Start-Flash {
    if($script:Busy){return}
    if(-not$DriveBox.SelectedItem){[System.Windows.MessageBox]::Show('Insert and select an SD card first.','LGHS Imager')|Out-Null;return}
    if($script:Mode-ne'local'){
        $ramChoice=Select-LghsPi5RamProfileBeforeFlash
        if($null-eq$ramChoice){return}
        $script:LghsHardwareRamGb=[int]$ramChoice
        Append-Log "Hardware profile selected: Raspberry Pi 5 / $ramChoice GB RAM"
    }
'@
    if(-not$appText.Contains($oldFlashHead)){throw 'Could not patch the pre-flash hardware-profile selector.'}
    $appText=$appText.Replace($oldFlashHead,$newFlashHead)

    $appText=$appText.Replace('$source=Resolve-ImageSource $role','$source=Resolve-ImageSource $role;$source=Resolve-LghsCachedImage $source')

    $oldBootstrap=@'
            $firstRunPath=Join-Path $env:TEMP ("lghs-firstrun-{0}.sh" -f [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($firstRunPath,(New-LghsStockBootstrapScript $Config),[Text.UTF8Encoding]::new($false))
            $cliArgs+=@('--first-run-script',$firstRunPath);Append-Log 'LGHS stock first-run bootstrap attached.'
'@
    $newBootstrap=@'
            $cloudInitPath=Join-Path $env:TEMP ("lghs-cloudinit-{0}.yaml" -f [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($cloudInitPath,(New-LghsCloudInitUserData $role),[Text.UTF8Encoding]::new($false))
            $cliArgs+=@('--cloudinit-userdata',$cloudInitPath);Append-Log 'LGHS cloud-init attached: SSH credentials primed, LF-safe payloads, nonblocking stage-2 handoff.'
'@
    if(-not$appText.Contains($oldBootstrap)){throw 'Could not patch legacy first-run bootstrap block.'}
    $appText=$appText.Replace($oldBootstrap,$newBootstrap)
    $appText=$appText.Replace('}finally{if($firstRunPath){Remove-Item $firstRunPath -Force -ErrorAction SilentlyContinue};Set-Busy $false}','}finally{if($cloudInitPath){Remove-Item $cloudInitPath -Force -ErrorAction SilentlyContinue};Set-Busy $false}')
    $appText=$appText.Replace("Append-Log 'No published LGHS image found. Using official Raspberry Pi OS arm64 with LGHS first-run bootstrap.'","Append-Log 'Using Raspberry Pi OS with LGHS cloud-init. Image cache is reused when available.'")
    $appText=$appText.Replace("Append-Log 'Missing LGHS images use stock Raspberry Pi OS ARM64 with an injected LGHS first-run bootstrap.'","Append-Log 'Stock Raspberry Pi OS uses the local cache; Linux payloads are LF-normalized before eject.'")
    $appText=$appText.Replace("if(`$source.StockBootstrap){Append-Log 'First boot applies accounts/passwords/SSH locally. LGHS-System installation retries automatically when network becomes available.'}","if(`$source.StockBootstrap){Append-Log 'SSH credentials are primed before stage 2; all Linux boot payloads are LF-only; stage 2 runs under systemd.'}")

    if($appText-match'--first-run-script|lghs-firstrun'){throw 'Safety check failed: legacy first-run injection remains.'}
    if($appText-notmatch'--cloudinit-userdata'){throw 'Safety check failed: cloud-init injection missing.'}
    if($appText-notmatch'Resolve-LghsCachedImage'){throw 'Safety check failed: image cache hook missing.'}
    if($appText-notmatch'LghsHardwareRamGb'){throw 'Safety check failed: Pi 5 4/8 GB hardware selector missing.'}

    [IO.File]::WriteAllText($RuntimeScript,$appText,[Text.UTF8Encoding]::new($false))
    Assert-PowerShellSyntax $RuntimeScript
    Write-LaunchLog 'Runtime validation passed: bootstrap v11 + Pi 5 4/8 GB selector + image cache + LF enforcement.'
    & $RuntimeScript -SkipUpdate
}catch{
    Write-LaunchLog "FATAL: $($_|Out-String)"
    try{Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue;[System.Windows.MessageBox]::Show("LGHS Imager could not start.`n`n$($_.Exception.Message)`n`nLog:`n$LogFile",'LGHS Imager startup error')|Out-Null}catch{Write-Host $_}
    exit 1
}finally{if($RuntimeScript){Remove-Item $RuntimeScript -Force -ErrorAction SilentlyContinue}}