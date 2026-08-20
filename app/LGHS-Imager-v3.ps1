param([switch]$SkipUpdate)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$Root = Split-Path -Parent $PSScriptRoot
$Config = Get-Content (Join-Path $Root 'config\lghs-imager.json') -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'LGHS-StockBootstrap.ps1')

$ManifestUrl = [string]$Config.repository.manifest
$script:Mode = 'student'
$script:BatchStart = [int]$Config.batch.firstDevice
$script:BatchEnd = [int]$Config.batch.lastDevice
$script:StudentNumber = $script:BatchStart
$script:LocalImage = $null
$script:Busy = $false
$script:RangePromptShown = $false
$script:LogsVisible = $false

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
    throw 'Raspberry Pi Imager backend was not found.'
}

function Get-LghsManifest {
    try {
        if ($ManifestUrl -match '^https?://') {
            return Invoke-RestMethod -Uri $ManifestUrl -Headers @{ 'User-Agent'='LGHS-Imager' } -TimeoutSec 10
        }
    } catch { }
    $local = Join-Path $Root 'os-list\lghs-os-list.json'
    if (Test-Path $local) { return Get-Content $local -Raw | ConvertFrom-Json }
    return $null
}

function Get-ImageEntry([string]$Role) {
    $manifest = Get-LghsManifest
    if (-not $manifest) { return $null }
    $needle = if ($Role -eq 'controller') { 'Control' } else { 'Student' }
    return $manifest.os_list | Where-Object { $_.name -match $needle -and $_.devices -contains 'pi5' } | Select-Object -First 1
}

function Resolve-ImageSource([string]$Role) {
    $entry = Get-ImageEntry $Role
    if ($entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.url)) {
        return [pscustomobject]@{
            Image = [string]$entry.url
            Sha = [string]$entry.extract_sha256
            StockBootstrap = $false
            Description = 'Published LGHS image'
        }
    }

    if ([bool]$Config.features.stockImageBootstrapFallback) {
        $stock = [string]$Config.repository.stockBaseImage
        if ([string]::IsNullOrWhiteSpace($stock)) { throw 'Stock Raspberry Pi OS fallback URL is not configured.' }
        return [pscustomobject]@{
            Image = $stock
            Sha = $null
            StockBootstrap = $true
            Description = 'Official Raspberry Pi OS 64-bit Desktop + automatic LGHS first-boot build'
        }
    }
    throw "No $Role image is published and stock bootstrap fallback is disabled."
}

function Get-TargetId {
    if ($script:Mode -eq 'controller') { return [string]$Config.batch.controllerHostname }
    return ('{0}{1}' -f $Config.batch.studentPrefix, $script:StudentNumber.ToString(('D{0}' -f [int]$Config.batch.padding)))
}

function Get-RemovableDisks {
    Get-Disk | Where-Object {
        $_.OperationalStatus -eq 'Online' -and -not $_.IsBoot -and -not $_.IsSystem -and
        ($_.BusType -in @('USB','SD','MMC'))
    } | Sort-Object Number
}

function Format-Bytes([UInt64]$Bytes) {
    if ($Bytes -ge 1TB) { return '{0:N1} TB' -f ($Bytes/1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes/1GB) }
    return '{0:N0} MB' -f ($Bytes/1MB)
}

function Refresh-Drives {
    $DriveBox.Items.Clear()
    foreach ($d in Get-RemovableDisks) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = "Disk $($d.Number)  |  $($d.FriendlyName)  |  $(Format-Bytes $d.Size)"
        $item.Tag = $d.Number
        [void]$DriveBox.Items.Add($item)
    }
    if ($DriveBox.Items.Count -gt 0) { $DriveBox.SelectedIndex = 0 }
    $WriteButton.IsEnabled = (-not $script:Busy) -and ($DriveBox.Items.Count -gt 0)
}

function Get-FreeDriveLetter {
    $used = (Get-Volume | Where-Object DriveLetter).DriveLetter
    foreach ($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') {
        if ($used -notcontains $letter) { return [string]$letter }
    }
    throw 'No free drive letter is available for provisioning.'
}

function Get-BootDriveRoot([int]$DiskNumber) {
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Update-HostStorageCache -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 750
        foreach ($p in @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)) {
            $vol = $p | Get-Volume -ErrorAction SilentlyContinue
            if ($vol -and $vol.FileSystem -eq 'FAT32') {
                $temporary = $false
                if (-not $p.DriveLetter) {
                    $letter = Get-FreeDriveLetter
                    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop
                    $temporary = $true
                } else { $letter = [string]$p.DriveLetter }
                return [pscustomobject]@{ Root="${letter}:\"; Partition=$p.PartitionNumber; Temporary=$temporary }
            }
        }
    } while ((Get-Date) -lt $deadline)
    throw 'The Raspberry Pi boot partition did not become available after writing.'
}

function Show-BatchRangeConfiguration {
    [xml]$x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
Title="Student deployment range" Width="520" Height="360" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#0F1115" FontFamily="Segoe UI">
<Grid Margin="28"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock Grid.Row="0" Text="Student deployment range" FontSize="24" FontWeight="SemiBold" Foreground="#F4F6F8"/>
<TextBlock Grid.Row="1" Margin="0,7,0,22" Foreground="#98A2B3" FontSize="12" TextWrapping="Wrap" Text="Choose the first and last CS number for this deployment. Use the same number twice for one Pi."/>
<Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="18"/><ColumnDefinition/></Grid.ColumnDefinitions>
<StackPanel Grid.Column="0"><TextBlock Text="Start number" Foreground="#AAB4C0"/><TextBox x:Name="StartBox" Height="40" Margin="0,7,0,0" Padding="10,7" Background="#1D2129" Foreground="White" BorderBrush="#343B47"/></StackPanel>
<StackPanel Grid.Column="2"><TextBlock Text="End number" Foreground="#AAB4C0"/><TextBox x:Name="EndBox" Height="40" Margin="0,7,0,0" Padding="10,7" Background="#1D2129" Foreground="White" BorderBrush="#343B47"/></StackPanel></Grid>
<TextBlock x:Name="Preview" Grid.Row="3" Margin="0,18,0,0" Foreground="#D6DAE0" FontWeight="SemiBold"/><TextBlock x:Name="ValidationText" Grid.Row="4" Margin="0,12,0,0" Foreground="#E88B8B" FontSize="11"/>
<Grid Grid.Row="5" Margin="0,20,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Button x:Name="ContinueButton" Grid.Column="1" Content="Start deployment" MinWidth="140" Padding="16,9" Background="#2E6DB4" Foreground="White"/></Grid></Grid></Window>
'@
    $reader=New-Object System.Xml.XmlNodeReader $x; $d=[Windows.Markup.XamlReader]::Load($reader);$d.Owner=$script:Window
    $aBox=$d.FindName('StartBox');$bBox=$d.FindName('EndBox');$preview=$d.FindName('Preview');$validation=$d.FindName('ValidationText');$go=$d.FindName('ContinueButton')
    $aBox.Text=[string]$script:BatchStart;$bBox.Text=[string]$script:BatchEnd
    $refresh={ $a=0;$b=0;if([int]::TryParse($aBox.Text,[ref]$a)-and[int]::TryParse($bBox.Text,[ref]$b)-and$a-ge1-and$b-ge$a){$count=$b-$a+1;$preview.Text=("CS-{0} through CS-{1}  |  {2} Pi{3}" -f $a.ToString('D2'),$b.ToString('D2'),$count,$(if($count-ne1){'s'}else{''}))}else{$preview.Text='Enter a valid range.'} }
    $aBox.Add_TextChanged($refresh);$bBox.Add_TextChanged($refresh);&$refresh
    $go.Add_Click({$a=0;$b=0;$validation.Text='';if(-not[int]::TryParse($aBox.Text,[ref]$a)-or-not[int]::TryParse($bBox.Text,[ref]$b)){$validation.Text='Use whole numbers.';return};if($a-lt1-or$b-lt$a-or$b-gt999){$validation.Text='Use a range from 1 through 999, with End >= Start.';return};$script:BatchStart=$a;$script:BatchEnd=$b;$script:StudentNumber=$a;$d.DialogResult=$true;$d.Close()})
    [void]$d.ShowDialog()
}

function Show-DeviceConfiguration([string]$Role,[string]$DeviceId) {
    $kind=if($Role-eq'controller'){'Control Pi'}else{'Student Pi'};$user=[string]$Config.accounts.user;$admin=[string]$Config.accounts.admin;$root=[string]$Config.accounts.root
    [xml]$x=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Configure device" Width="520" Height="550" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#0F1115" FontFamily="Segoe UI">
<Grid Margin="26"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<TextBlock x:Name="Heading" Grid.Row="0" FontSize="24" FontWeight="SemiBold" Foreground="#F4F6F8"/><TextBlock x:Name="Subheading" Grid.Row="1" Margin="0,6,0,22" FontSize="12" Foreground="#98A2B3" TextWrapping="Wrap"/>
<TextBlock x:Name="UserLabel" Grid.Row="2" Foreground="#AAB4C0"/><PasswordBox x:Name="UserPassword" Grid.Row="3" Height="38" Margin="0,6,0,16" Padding="10,7"/>
<TextBlock x:Name="AdminLabel" Grid.Row="4" Foreground="#AAB4C0"/><PasswordBox x:Name="AdminPassword" Grid.Row="5" Height="38" Margin="0,6,0,12" Padding="10,7"/>
<CheckBox x:Name="SameRoot" Grid.Row="6" Content="Use Admin password for Root" IsChecked="True" Foreground="#F4F6F8" Margin="0,2,0,14"/>
<StackPanel Grid.Row="7"><TextBlock x:Name="RootLabel" Foreground="#AAB4C0"/><PasswordBox x:Name="RootPassword" Height="38" Margin="0,6,0,0" Padding="10,7" IsEnabled="False"/></StackPanel>
<TextBlock Grid.Row="8" Margin="0,18,0,0" Foreground="#717C89" FontSize="11" TextWrapping="Wrap" Text="Passwords are used only for this card's first-boot provisioning and are not written to LGHS Imager logs."/>
<Grid Grid.Row="9" Margin="0,22,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="Validation" Grid.Column="0" Foreground="#E88B8B"/><Button x:Name="Cancel" Grid.Column="1" Content="Cancel" MinWidth="88" Margin="0,0,8,0"/><Button x:Name="Continue" Grid.Column="2" Content="Continue" MinWidth="100" Background="#2E6DB4" Foreground="White"/></Grid></Grid></Window>
'@
    $reader=New-Object System.Xml.XmlNodeReader $x;$d=[Windows.Markup.XamlReader]::Load($reader);$d.Owner=$script:Window
    $heading=$d.FindName('Heading');$sub=$d.FindName('Subheading');$ul=$d.FindName('UserLabel');$al=$d.FindName('AdminLabel');$rl=$d.FindName('RootLabel');$up=$d.FindName('UserPassword');$ap=$d.FindName('AdminPassword');$rp=$d.FindName('RootPassword');$same=$d.FindName('SameRoot');$val=$d.FindName('Validation');$cancel=$d.FindName('Cancel');$go=$d.FindName('Continue')
    $heading.Text="Configure $kind - $DeviceId";$sub.Text="Set the local credentials for $DeviceId.";$ul.Text="User Password  ($user)";$al.Text="Admin Password  ($admin)";$rl.Text="Root Password  ($root)";$same.IsChecked=[bool]$Config.accounts.defaultRootSameAsAdmin;$rp.IsEnabled=-not$same.IsChecked
    $same.Add_Checked({$rp.IsEnabled=$false;$rp.Clear()});$same.Add_Unchecked({$rp.IsEnabled=$true});$cancel.Add_Click({$d.DialogResult=$false;$d.Close()})
    $go.Add_Click({$val.Text='';if([string]::IsNullOrEmpty($up.Password)){$val.Text='Enter User password.';return};if([string]::IsNullOrEmpty($ap.Password)){$val.Text='Enter Admin password.';return};if(-not$same.IsChecked-and[string]::IsNullOrEmpty($rp.Password)){$val.Text='Enter Root password.';return};$d.DialogResult=$true;$d.Close()})
    if(-not$d.ShowDialog()){return $null};$rootValue=if($same.IsChecked){$ap.Password}else{$rp.Password}
    return [pscustomobject]@{UserName=$user;UserPassword=$up.Password;AdminName=$admin;AdminPassword=$ap.Password;RootName=$root;RootPassword=$rootValue;RootSameAsAdmin=[bool]$same.IsChecked}
}

function Set-Mode([string]$Mode) {
    $script:Mode=$Mode
    if($Mode-eq'student'){$StudentButton.IsChecked=$true;$ImageLabel.Text='LGHS Student';$TargetLabel.Text="$(Get-TargetId)  |  CS-$($script:BatchStart.ToString('D2')) to CS-$($script:BatchEnd.ToString('D2'))"}
    elseif($Mode-eq'controller'){$ControlButton.IsChecked=$true;$ImageLabel.Text='LGHS Control';$TargetLabel.Text=[string]$Config.batch.controllerHostname}
    else{$LocalButton.IsChecked=$true;$ImageLabel.Text=if($script:LocalImage){[IO.Path]::GetFileName($script:LocalImage)}else{'Choose a local image'};$TargetLabel.Text=Get-TargetId}
}

function Append-Log([string]$Text){$LogBox.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $Text`r`n");$LogBox.ScrollToEnd()}
function Set-LogsVisible([bool]$Visible){$script:LogsVisible=$Visible;$LogBox.Visibility=if($Visible){'Visible'}else{'Collapsed'};$DetailsButton.Content=if($Visible){'Hide details'}else{'Show details'}}
function Set-Busy([bool]$Busy){$script:Busy=$Busy;$WriteButton.IsEnabled=(-not$Busy)-and($null-ne$DriveBox.SelectedItem);$RefreshButton.IsEnabled=-not$Busy;$StudentButton.IsEnabled=-not$Busy;$ControlButton.IsEnabled=-not$Busy;$LocalButton.IsEnabled=-not$Busy;$Progress.IsIndeterminate=$Busy;$WriteButton.Content=if($Busy){'WRITING...'}else{'WRITE SD CARD'}}
function Quote-ProcessArgument([string]$Value){if($null-eq$Value){return '""'};if($Value-notmatch'[\s"]'){return $Value};return '"'+($Value-replace'(\\*)"','$1$1\"'-replace'(\\+)$','$1$1')+'"'}

function Start-Flash {
    if($script:Busy){return}
    if(-not$DriveBox.SelectedItem){[System.Windows.MessageBox]::Show('Insert and select an SD card first.','LGHS Imager')|Out-Null;return}
    $diskNumber=[int]$DriveBox.SelectedItem.Tag;$disk=Get-Disk -Number $diskNumber;$deviceId=Get-TargetId;$role=if($script:Mode-eq'controller'){'controller'}else{'student'}

    if($script:Mode-eq'local'){
        if(-not$script:LocalImage){[System.Windows.MessageBox]::Show('Choose a local image first.','LGHS Imager')|Out-Null;return}
        $source=[pscustomobject]@{Image=$script:LocalImage;Sha=$null;StockBootstrap=$false;Description='Local image'}
    }else{
        try{$source=Resolve-ImageSource $role}catch{[System.Windows.MessageBox]::Show($_.Exception.Message,'LGHS Imager')|Out-Null;return}
    }

    $credentials=Show-DeviceConfiguration $role $deviceId;if(-not$credentials){return}
    try{[void](Get-LghsFleetKeyPair $Config)}catch{[System.Windows.MessageBox]::Show($_.Exception.Message,'LGHS fleet key setup failed')|Out-Null;return}

    $confirm=[System.Windows.MessageBox]::Show("Erase Disk $diskNumber ($($disk.FriendlyName), $(Format-Bytes $disk.Size)) and write $deviceId?`n`nImage source: $($source.Description)","Confirm $deviceId write",[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Warning)
    if($confirm-ne[System.Windows.MessageBoxResult]::Yes){return}

    Set-Busy $true;$StatusText.Text="Writing $deviceId...";Append-Log "Image source: $($source.Description)";if($source.StockBootstrap){Append-Log 'No published LGHS image found. Using official Raspberry Pi OS arm64 and staging automatic LGHS self-build.'}
    try{
        $backend=Find-ImagerBackend;$args=@('--cli','--disable-telemetry');if($source.Sha){$args+=@('--sha256',[string]$source.Sha)};$args+=@([string]$source.Image,"\\.\PhysicalDrive$diskNumber")
        $psi=New-Object System.Diagnostics.ProcessStartInfo;$psi.FileName=$backend;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true;$psi.Arguments=(($args|ForEach-Object{Quote-ProcessArgument([string]$_)})-join' ')
        $p=New-Object System.Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start()
        while(-not$p.HasExited){while(-not$p.StandardOutput.EndOfStream){Append-Log $p.StandardOutput.ReadLine();[System.Windows.Forms.Application]::DoEvents()};while(-not$p.StandardError.EndOfStream){Append-Log $p.StandardError.ReadLine();[System.Windows.Forms.Application]::DoEvents()};Start-Sleep -Milliseconds 100;[System.Windows.Forms.Application]::DoEvents()}
        while(-not$p.StandardOutput.EndOfStream){Append-Log $p.StandardOutput.ReadLine()};while(-not$p.StandardError.EndOfStream){Append-Log $p.StandardError.ReadLine()};if($p.ExitCode-ne0){throw "Raspberry Pi Imager backend exited with code $($p.ExitCode)."}

        $StatusText.Text='Staging LGHS provisioning...';$boot=Get-BootDriveRoot $diskNumber
        try{Write-LghsProvisioning $boot.Root $deviceId $role $credentials $Config ([bool]$source.StockBootstrap)}finally{if($boot.Temporary){Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $boot.Partition -AccessPath $boot.Root -ErrorAction SilentlyContinue}}
        $credentials=$null;Append-Log "Provisioning staged for $deviceId.";if($source.StockBootstrap){Append-Log 'First boot will apply identity/passwords locally, then finish LGHS installation automatically when network is available.'}
        $StatusText.Text="$deviceId complete - safe to remove the card."
        if($script:Mode-eq'student'-and[bool]$Config.batch.autoAdvanceAfterSuccessfulWrite){if($script:StudentNumber-lt$script:BatchEnd){$script:StudentNumber++;Set-Mode'student';Append-Log "Batch advanced to $(Get-TargetId)."}else{$StatusText.Text='Student batch complete.';Append-Log "Student deployment CS-$($script:BatchStart.ToString('D2')) through CS-$($script:BatchEnd.ToString('D2')) is complete."}}
        Refresh-Drives
    }catch{$credentials=$null;Append-Log "ERROR: $($_.Exception.Message)";$StatusText.Text='Write failed.';Set-LogsVisible $true;[System.Windows.MessageBox]::Show($_.Exception.Message,'LGHS Imager write failed',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Error)|Out-Null}finally{Set-Busy $false}
}

$xamlPath=Join-Path $PSScriptRoot 'LGHS-Imager.xaml';if(-not(Test-Path$xamlPath)){throw "UI file not found: $xamlPath"};[xml]$xaml=Get-Content $xamlPath -Raw;$reader=New-Object System.Xml.XmlNodeReader $xaml;$script:Window=[Windows.Markup.XamlReader]::Load($reader)
foreach($name in @('StudentButton','ControlButton','LocalButton','ImageLabel','TargetLabel','DriveBox','RefreshButton','StatusText','Progress','LogBox','WriteButton','DetailsButton')){Set-Variable -Name $name -Value $script:Window.FindName($name)-Scope Script}
$StudentButton.Add_Checked({if($script:Mode-ne'student'){Set-Mode'student'}});$ControlButton.Add_Checked({if($script:Mode-ne'controller'){Set-Mode'controller'}});$LocalButton.Add_Checked({if($script:Mode-ne'local'){$script:Mode='local';$dlg=New-Object Microsoft.Win32.OpenFileDialog;$dlg.Title='Select image';$dlg.Filter='Disk images|*.img;*.zip;*.xz;*.gz|All files|*.*';if($dlg.ShowDialog()){$script:LocalImage=$dlg.FileName};Set-Mode'local'}})
$RefreshButton.Add_Click({Refresh-Drives});$WriteButton.Add_Click({Start-Flash});$DetailsButton.Add_Click({Set-LogsVisible(-not$script:LogsVisible)})
$script:Window.Add_ContentRendered({if(-not$script:RangePromptShown){$script:RangePromptShown=$true;Show-BatchRangeConfiguration};Refresh-Drives;Set-Mode'student';Append-Log "LGHS Imager ready. Student range CS-$($script:BatchStart.ToString('D2')) through CS-$($script:BatchEnd.ToString('D2')).";Append-Log 'Missing LGHS images automatically fall back to official Raspberry Pi OS arm64 + LGHS first-boot self-build.'})
$script:Window.Add_Closing({if($script:Busy){$_.Cancel=$true}})
[void]$script:Window.ShowDialog()
