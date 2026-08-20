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
$script:SelectedDiskNumber = $null

function Find-ImagerBackend {
    $candidates = @(
        (Join-Path $Root 'backend\rpi-imager.exe'),
        (Join-Path $Root 'build\rpi-imager.exe'),
        (Join-Path $Root 'build\src\rpi-imager.exe'),
        (Join-Path $Root 'upstream\build\rpi-imager.exe')
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    $cmd = Get-Command rpi-imager.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'Raspberry Pi Imager backend was not found. Build LGHS Imager first.'
}

function Get-LghsManifest {
    try {
        return Invoke-RestMethod -Uri $ManifestUrl -Headers @{ 'User-Agent'='LGHS-Imager' } -TimeoutSec 10
    } catch {
        $local = Join-Path $Root 'os-list\lghs-os-list.json'
        if (Test-Path $local) { return Get-Content $local -Raw | ConvertFrom-Json }
        throw
    }
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
        $item.Content = "Disk $($d.Number) | $($d.FriendlyName) | $(Format-Bytes $d.Size)"
        $item.Tag = $d.Number
        [void]$DriveBox.Items.Add($item)
    }
    if ($DriveBox.Items.Count -gt 0) { $DriveBox.SelectedIndex = 0 }
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
                } else { $letter = [string]$p.DriveLetter }

                $path = "${letter}:\lghs-provision.conf"
                @(
                    "DEVICE_ID=$deviceId"
                    "TARGET_HOSTNAME=$deviceId"
                    "ROLE=$role"
                    'BOARD=Raspberry Pi 5'
                    'MEMORY_GB=8'
                    'ARCH=arm64'
                    "PROVISIONED_AT=$((Get-Date).ToUniversalTime().ToString('o'))"
                ) | Set-Content -Encoding ascii $path

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
    $StudentButton.IsChecked = ($mode -eq 'student')
    $ControlButton.IsChecked = ($mode -eq 'controller')
    $LocalButton.IsChecked = ($mode -eq 'local')
    if ($mode -eq 'student') {
        $TargetLabel.Text = "Next device: $(Get-TargetId) | Batch $($Config.batch.firstDevice)-$($Config.batch.lastDevice)"
        $ImageLabel.Text = 'LGHS Student | Raspberry Pi 5 8GB'
    } elseif ($mode -eq 'controller') {
        $TargetLabel.Text = "Controller hostname: $($Config.batch.controllerHostname)"
        $ImageLabel.Text = 'LGHS Control | Raspberry Pi 5 8GB'
    } else {
        $TargetLabel.Text = "Provision as: $(Get-TargetId)"
        $ImageLabel.Text = if ($script:LocalImage) { $script:LocalImage } else { 'Choose a local .img/.zip/.xz file' }
    }
}

function Append-Log([string]$text) {
    $LogBox.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $text`r`n")
    $LogBox.ScrollToEnd()
}

function Set-Busy([bool]$busy) {
    $script:Busy = $busy
    $WriteButton.IsEnabled = -not $busy
    $RefreshButton.IsEnabled = -not $busy
    $StudentButton.IsEnabled = -not $busy
    $ControlButton.IsEnabled = -not $busy
    $LocalButton.IsEnabled = -not $busy
    $Progress.IsIndeterminate = $busy
}

function Quote-ProcessArgument([string]$value) {
    if ($null -eq $value) { return '""' }
    if ($value -notmatch '[\s"]') { return $value }
    return '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Start-Flash {
    if ($script:Busy) { return }
    if (-not $DriveBox.SelectedItem) { [System.Windows.MessageBox]::Show('Insert and select an SD card first.','LGHS Imager'); return }

    $diskNumber = [int]$DriveBox.SelectedItem.Tag
    $disk = Get-Disk -Number $diskNumber
    $deviceId = Get-TargetId
    $role = if ($script:Mode -eq 'controller') { 'controller' } else { 'student' }

    if ($script:Mode -eq 'local') {
        if (-not $script:LocalImage) { [System.Windows.MessageBox]::Show('Choose a local image first.','LGHS Imager'); return }
        $image = $script:LocalImage
        $sha = $null
    } else {
        $entry = Get-ImageEntry $role
        if (-not $entry) { [System.Windows.MessageBox]::Show("No $role image is available in the LGHS manifest.",'LGHS Imager'); return }
        $image = [string]$entry.url
        $sha = [string]$entry.extract_sha256
        if ([string]::IsNullOrWhiteSpace($image)) {
            [System.Windows.MessageBox]::Show("The $role image has not been published yet. Use Local Image for testing.",'LGHS Imager') | Out-Null
            return
        }
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "ERASE Disk $diskNumber ($($disk.FriendlyName), $(Format-Bytes $disk.Size)) and write $deviceId?",
        'Confirm SD card write',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning)
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Set-Busy $true
    $StatusText.Text = "Writing $deviceId..."
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

        $StatusText.Text = 'Writing provisioning data...'
        Write-ProvisionFile $diskNumber $deviceId $role
        Append-Log "Provisioned $deviceId successfully."
        $StatusText.Text = "$deviceId complete - safe to remove the card."

        if ($script:Mode -eq 'student' -and $Config.batch.autoAdvanceAfterSuccessfulWrite) {
            if ($script:StudentNumber -lt [int]$Config.batch.lastDevice) {
                $script:StudentNumber++
                Set-Mode 'student'
                Append-Log "Batch advanced to $(Get-TargetId)."
            } else {
                Append-Log 'Student batch CS-01 through CS-14 is complete.'
                $StatusText.Text = 'Student batch complete.'
            }
        }
        Refresh-Drives
    } catch {
        Append-Log "ERROR: $($_.Exception.Message)"
        $StatusText.Text = 'Write failed.'
        [System.Windows.MessageBox]::Show($_.Exception.Message,'LGHS Imager write failed',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Error) | Out-Null
    } finally {
        Set-Busy $false
    }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LGHS Imager" Width="940" Height="680" MinWidth="760" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#111318">
  <Grid Margin="24">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,18">
      <TextBlock Text="LGHS IMAGER" FontSize="30" FontWeight="Bold" Foreground="White"/>
      <TextBlock Text="Raspberry Pi 5 | 8 GB | ARM64 classroom deployment" FontSize="14" Foreground="#A9B1BD" Margin="0,4,0,0"/>
    </StackPanel>
    <Grid Grid.Row="1" Margin="0,0,0,16">
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
      <RadioButton x:Name="StudentButton" Grid.Column="0" Content="LGHS Student" GroupName="Mode" IsChecked="True" Margin="0,0,8,0" Padding="14" Foreground="White" Background="#20242C"/>
      <RadioButton x:Name="ControlButton" Grid.Column="1" Content="LGHS Control" GroupName="Mode" Margin="4,0" Padding="14" Foreground="White" Background="#20242C"/>
      <RadioButton x:Name="LocalButton" Grid.Column="2" Content="Local Image" GroupName="Mode" Margin="8,0,0,0" Padding="14" Foreground="White" Background="#20242C"/>
    </Grid>
    <Border Grid.Row="2" Background="#1A1E25" CornerRadius="10" Padding="18" Margin="0,0,0,16">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid.ColumnDefinitions><ColumnDefinition Width="130"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock Grid.Row="0" Grid.Column="0" Text="Image" Foreground="#8993A1" VerticalAlignment="Center"/>
        <TextBlock x:Name="ImageLabel" Grid.Row="0" Grid.Column="1" Text="LGHS Student | Raspberry Pi 5 8GB" Foreground="White" FontWeight="SemiBold"/>
        <TextBlock Grid.Row="1" Grid.Column="0" Text="Target" Foreground="#8993A1" Margin="0,12,0,0"/>
        <TextBlock x:Name="TargetLabel" Grid.Row="1" Grid.Column="1" Foreground="White" Margin="0,12,0,0"/>
        <TextBlock Grid.Row="2" Grid.Column="0" Text="Storage" Foreground="#8993A1" Margin="0,12,0,0" VerticalAlignment="Center"/>
        <ComboBox x:Name="DriveBox" Grid.Row="2" Grid.Column="1" Margin="0,10,10,0" Height="34"/>
        <Button x:Name="RefreshButton" Grid.Row="2" Grid.Column="2" Content="Refresh" Margin="0,10,0,0" Padding="16,6"/>
      </Grid>
    </Border>
    <Grid Grid.Row="3">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <StackPanel Grid.Row="0" Margin="0,0,0,10">
        <TextBlock x:Name="StatusText" Text="Ready." Foreground="White" FontWeight="SemiBold"/>
        <ProgressBar x:Name="Progress" Height="5" Margin="0,8,0,0" IsIndeterminate="False"/>
      </StackPanel>
      <TextBox x:Name="LogBox" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" Background="#0C0E12" Foreground="#D6DAE0" BorderBrush="#2B313B" Padding="10"/>
    </Grid>
    <Grid Grid.Row="4" Margin="0,18,0,0">
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="SHA-256 + post-write verification enabled | telemetry disabled" Foreground="#7F8997" VerticalAlignment="Center"/>
      <Button x:Name="WriteButton" Grid.Column="1" Content="WRITE SD CARD" FontWeight="Bold" Padding="26,12"/>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($name in @('StudentButton','ControlButton','LocalButton','ImageLabel','TargetLabel','DriveBox','RefreshButton','StatusText','Progress','LogBox','WriteButton')) {
    Set-Variable -Name $name -Value $Window.FindName($name) -Scope Script
}

$StudentButton.Add_Checked({ Set-Mode 'student' })
$ControlButton.Add_Checked({ Set-Mode 'controller' })
$LocalButton.Add_Checked({
    Set-Mode 'local'
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Select LGHS image'
    $dlg.Filter = 'Disk images|*.img;*.zip;*.xz;*.gz|All files|*.*'
    if ($dlg.ShowDialog()) { $script:LocalImage = $dlg.FileName; Set-Mode 'local' }
})
$RefreshButton.Add_Click({ Refresh-Drives })
$WriteButton.Add_Click({ Start-Flash })
$Window.Add_ContentRendered({ Refresh-Drives; Set-Mode 'student'; Append-Log 'LGHS Imager ready. Target hardware is Raspberry Pi 5 8GB.' })
$Window.Add_Closing({ if ($script:Busy) { $_.Cancel = $true } })

[void]$Window.ShowDialog()
