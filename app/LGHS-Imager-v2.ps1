param([switch]$SkipUpdate)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$Root = Split-Path -Parent $PSScriptRoot
$Config = Get-Content (Join-Path $Root 'config\lghs-imager.json') -Raw | ConvertFrom-Json
$ManifestUrl = [string]$Config.repository.manifest
$script:Mode = 'student'
$script:StudentNumber = [int]$Config.batch.firstDevice
$script:LocalImage = $null
$script:Busy = $false
$script:LogsVisible = $false

function Find-ImagerBackend {
    $candidates = @(
        (Join-Path $Root 'backend\rpi-imager.exe'),
        (Join-Path $Root 'build\rpi-imager.exe'),
        (Join-Path $Root 'build\src\rpi-imager.exe')
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    $built = Get-ChildItem (Join-Path $Root 'build') -Recurse -Filter 'rpi-imager.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($built) { return $built.FullName }
    $cmd = Get-Command rpi-imager.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'Raspberry Pi Imager backend was not found. Build LGHS Imager first.'
}

function Get-LghsManifest {
    try {
        if ($ManifestUrl -match '^https?://') {
            return Invoke-RestMethod -Uri $ManifestUrl -Headers @{ 'User-Agent'='LGHS-Imager' } -TimeoutSec 10
        }
    } catch { }
    $local = Join-Path $Root 'os-list\lghs-os-list.json'
    if (Test-Path $local) { return Get-Content $local -Raw | ConvertFrom-Json }
    throw 'LGHS image manifest was not found.'
}

function Get-ImageEntry([string]$role) {
    $manifest = Get-LghsManifest
    $needle = if ($role -eq 'controller') { 'Control' } else { 'Student' }
    return $manifest.os_list | Where-Object { $_.name -match $needle -and $_.devices -contains 'pi5' } | Select-Object -First 1
}

function Get-TargetId {
    if ($script:Mode -eq 'controller') { return [string]$Config.batch.controllerHostname }
    return ('{0}{1}' -f $Config.batch.studentPrefix, $script:StudentNumber.ToString(('D{0}' -f [int]$Config.batch.padding)))
}

function Get-RemovableDisks {
    Get-Disk | Where-Object {
        $_.OperationalStatus -eq 'Online' -and
        -not $_.IsBoot -and -not $_.IsSystem -and
        ($_.BusType -in @('USB','SD','MMC'))
    } | Sort-Object Number
}

function Format-Bytes([UInt64]$bytes) {
    if ($bytes -ge 1TB) { return '{0:N1} TB' -f ($bytes/1TB) }
    if ($bytes -ge 1GB) { return '{0:N1} GB' -f ($bytes/1GB) }
    return '{0:N0} MB' -f ($bytes/1MB)
}

function Refresh-Drives {
    $DriveBox.Items.Clear()
    foreach ($d in Get-RemovableDisks) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = "Disk $($d.Number)  |  $($d.FriendlyName)  |  $(Format-Bytes $d.Size)"
        $item.Tag = $d.Number
        [void]$DriveBox.Items.Add($item)
    }
    if ($DriveBox.Items.Count -gt 0) {
        $DriveBox.SelectedIndex = 0
        if (-not $script:Busy) { $WriteButton.IsEnabled = $true }
    } else {
        $WriteButton.IsEnabled = $false
    }
}

function Get-FreeDriveLetter {
    $used = (Get-Volume | Where-Object DriveLetter).DriveLetter
    foreach ($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
        if ($used -notcontains $letter) { return [string]$letter }
    }
    throw 'No free drive letter is available for provisioning.'
}

function Write-ProvisionFile([int]$diskNumber, [string]$deviceId, [string]$role) {
    $deadline = (Get-Date).AddSeconds(25)
    do {
        Update-HostStorageCache -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 750
        $parts = @(Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue)
        foreach ($p in $parts) {
            $vol = $p | Get-Volume -ErrorAction SilentlyContinue
            if ($vol -and $vol.FileSystem -eq 'FAT32') {
                $temporary = $false
                if (-not $p.DriveLetter) {
                    $letter = Get-FreeDriveLetter
                    Set-Partition -DiskNumber $diskNumber -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop
                    $temporary = $true
                } else {
                    $letter = [string]$p.DriveLetter
                }
                @(
                    "DEVICE_ID=$deviceId"
                    "TARGET_HOSTNAME=$deviceId"
                    "ROLE=$role"
                    'BOARD=Raspberry Pi 5'
                    'MEMORY_GB=8'
                    'ARCH=arm64'
                    "PROVISIONED_AT=$((Get-Date).ToUniversalTime().ToString('o'))"
                ) | Set-Content -Encoding ascii "${letter}:\lghs-provision.conf"
                if ($temporary) {
                    Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $p.PartitionNumber -AccessPath "${letter}:\" -ErrorAction SilentlyContinue
                }
                return
            }
        }
    } while ((Get-Date) -lt $deadline)
    throw 'The Pi boot partition did not become available for LGHS provisioning.'
}

function Set-Mode([string]$mode) {
    $script:Mode = $mode
    if ($mode -eq 'student') {
        $ImageLabel.Text = 'LGHS Student'
        $TargetLabel.Text = Get-TargetId
    } elseif ($mode -eq 'controller') {
        $ImageLabel.Text = 'LGHS Control'
        $TargetLabel.Text = [string]$Config.batch.controllerHostname
    } else {
        $ImageLabel.Text = if ($script:LocalImage) { Split-Path $script:LocalImage -Leaf } else { 'Local Image' }
        $TargetLabel.Text = Get-TargetId
    }
}

function Append-Log([string]$text) {
    $LogBox.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $text`r`n")
    $LogBox.ScrollToEnd()
}

function Set-LogsVisible([bool]$visible) {
    $script:LogsVisible = $visible
    $LogBox.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
    $DetailsButton.Content = if ($visible) { 'Hide details' } else { 'Show details' }
}

function Set-Busy([bool]$busy) {
    $script:Busy = $busy
    $WriteButton.IsEnabled = (-not $busy) -and ($null -ne $DriveBox.SelectedItem)
    $RefreshButton.IsEnabled = -not $busy
    $StudentButton.IsEnabled = -not $busy
    $ControlButton.IsEnabled = -not $busy
    $LocalButton.IsEnabled = -not $busy
    $Progress.IsIndeterminate = $busy
    $WriteButton.Content = if ($busy) { 'WRITING...' } else { 'WRITE SD CARD' }
}

function Quote-ProcessArgument([string]$value) {
    if ($null -eq $value) { return '""' }
    if ($value -notmatch '[\s"]') { return $value }
    return '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Start-Flash {
    if ($script:Busy) { return }
    if (-not $DriveBox.SelectedItem) {
        [System.Windows.MessageBox]::Show('Insert and select an SD card first.','LGHS Imager') | Out-Null
        return
    }

    $diskNumber = [int]$DriveBox.SelectedItem.Tag
    $disk = Get-Disk -Number $diskNumber
    $deviceId = Get-TargetId
    $role = if ($script:Mode -eq 'controller') { 'controller' } else { 'student' }

    if ($script:Mode -eq 'local') {
        if (-not $script:LocalImage) {
            [System.Windows.MessageBox]::Show('Choose a local image first.','LGHS Imager') | Out-Null
            return
        }
        $image = $script:LocalImage
        $sha = $null
    } else {
        $entry = Get-ImageEntry $role
        if (-not $entry) {
            [System.Windows.MessageBox]::Show("No $role image is available in the LGHS manifest.",'LGHS Imager') | Out-Null
            return
        }
        $image = [string]$entry.url
        $sha = [string]$entry.extract_sha256
        if ([string]::IsNullOrWhiteSpace($image)) {
            [System.Windows.MessageBox]::Show("The $role image has not been published yet. Use Local Image for testing.",'LGHS Imager') | Out-Null
            return
        }
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Erase Disk $diskNumber ($($disk.FriendlyName), $(Format-Bytes $disk.Size)) and write $deviceId? All data on the selected drive will be destroyed.",
        'Confirm SD card write',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning)
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Set-Busy $true
    $StatusText.Text = "Writing $deviceId"
    Append-Log "Starting $role image for $deviceId on Disk $diskNumber."

    try {
        $backend = Find-ImagerBackend
        $backendArgs = @('--cli','--disable-telemetry')
        if ($sha) { $backendArgs += @('--sha256',$sha) }
        $backendArgs += @($image, "\\.\PhysicalDrive$diskNumber")

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $backend
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.Arguments = (($backendArgs | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        while (-not $proc.HasExited) {
            while (-not $proc.StandardOutput.EndOfStream) { Append-Log $proc.StandardOutput.ReadLine(); [System.Windows.Forms.Application]::DoEvents() }
            while (-not $proc.StandardError.EndOfStream) { Append-Log $proc.StandardError.ReadLine(); [System.Windows.Forms.Application]::DoEvents() }
            Start-Sleep -Milliseconds 100
            [System.Windows.Forms.Application]::DoEvents()
        }
        while (-not $proc.StandardOutput.EndOfStream) { Append-Log $proc.StandardOutput.ReadLine() }
        while (-not $proc.StandardError.EndOfStream) { Append-Log $proc.StandardError.ReadLine() }
        if ($proc.ExitCode -ne 0) { throw "Raspberry Pi Imager backend exited with code $($proc.ExitCode)." }

        $StatusText.Text = 'Finishing provisioning'
        Write-ProvisionFile $diskNumber $deviceId $role
        Append-Log "Provisioned $deviceId successfully."
        $StatusText.Text = "$deviceId is ready"

        if ($script:Mode -eq 'student' -and $Config.batch.autoAdvanceAfterSuccessfulWrite) {
            if ($script:StudentNumber -lt [int]$Config.batch.lastDevice) {
                $script:StudentNumber++
                Set-Mode 'student'
                Append-Log "Batch advanced to $(Get-TargetId)."
            } else {
                $StatusText.Text = 'Student batch complete'
                Append-Log 'Student batch CS-01 through CS-14 is complete.'
            }
        }
        Refresh-Drives
    } catch {
        Append-Log "ERROR: $($_.Exception.Message)"
        $StatusText.Text = 'Write failed'
        Set-LogsVisible $true
        [System.Windows.MessageBox]::Show($_.Exception.Message,'LGHS Imager write failed',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Error) | Out-Null
    } finally {
        Set-Busy $false
    }
}

$xamlPath = Join-Path $PSScriptRoot 'LGHS-Imager.xaml'
if (-not (Test-Path $xamlPath)) { throw "UI file not found: $xamlPath" }
[xml]$xaml = Get-Content $xamlPath -Raw
$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)

foreach ($name in @('StudentButton','ControlButton','LocalButton','ImageLabel','TargetLabel','DriveBox','RefreshButton','StatusText','Progress','LogBox','DetailsButton','WriteButton')) {
    Set-Variable -Name $name -Value $Window.FindName($name) -Scope Script
}

$StudentButton.Add_Checked({ Set-Mode 'student' })
$ControlButton.Add_Checked({ Set-Mode 'controller' })
$LocalButton.Add_Checked({
    Set-Mode 'local'
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Select LGHS image'
    $dlg.Filter = 'Disk images|*.img;*.zip;*.xz;*.gz|All files|*.*'
    if ($dlg.ShowDialog()) {
        $script:LocalImage = $dlg.FileName
        Set-Mode 'local'
    }
})
$RefreshButton.Add_Click({ Refresh-Drives })
$DriveBox.Add_SelectionChanged({ if (-not $script:Busy) { $WriteButton.IsEnabled = ($null -ne $DriveBox.SelectedItem) } })
$DetailsButton.Add_Click({ Set-LogsVisible (-not $script:LogsVisible) })
$WriteButton.Add_Click({ Start-Flash })
$Window.Add_ContentRendered({
    Refresh-Drives
    Set-Mode 'student'
    Set-LogsVisible $false
    Append-Log 'LGHS Imager ready. Target hardware is Raspberry Pi 5 8GB.'
})
$Window.Add_Closing({ if ($script:Busy) { $_.Cancel = $true } })

[void]$Window.ShowDialog()
