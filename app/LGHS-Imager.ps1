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
$script:BatchStart = [int]$Config.batch.firstDevice
$script:BatchEnd = [int]$Config.batch.lastDevice
$script:StudentNumber = $script:BatchStart
$script:LocalImage = $null
$script:Busy = $false
$script:RangePromptShown = $false

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
    try { return Invoke-RestMethod -Uri $ManifestUrl -Headers @{ 'User-Agent'='LGHS-Imager' } -TimeoutSec 10 }
    catch {
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
    Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' -and -not $_.IsBoot -and -not $_.IsSystem -and ($_.BusType -in @('USB','SD','MMC')) } | Sort-Object Number
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
    foreach ($letter in [char[]]'ZYXWVUTSRQPONMLKJIHGFED') { if ($used -notcontains $letter) { return [string]$letter } }
    throw 'No free drive letter is available for provisioning.'
}

function ConvertTo-Base64Utf8([string]$value) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value)) }

function Show-BatchRangeConfiguration {
    [xml]$rangeXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Student deployment range" Width="520" Height="360" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner" Background="#0F1115" FontFamily="Segoe UI">
  <Grid Margin="28">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Student deployment range" FontSize="24" FontWeight="SemiBold" Foreground="#F4F6F8"/>
    <TextBlock Grid.Row="1" Margin="0,7,0,22" Foreground="#98A2B3" FontSize="12" TextWrapping="Wrap" Text="Choose which CS numbers this flashing session should cover. Use the same number twice for a single Pi."/>
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="18"/><ColumnDefinition/></Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0"><TextBlock Text="Start number" Foreground="#AAB4C0"/><TextBox x:Name="StartBox" Height="40" Margin="0,7,0,0" Padding="10,7" Background="#1D2129" Foreground="White" BorderBrush="#343B47"/></StackPanel>
      <StackPanel Grid.Column="2"><TextBlock Text="End number" Foreground="#AAB4C0"/><TextBox x:Name="EndBox" Height="40" Margin="0,7,0,0" Padding="10,7" Background="#1D2129" Foreground="White" BorderBrush="#343B47"/></StackPanel>
    </Grid>
    <TextBlock x:Name="Preview" Grid.Row="3" Margin="0,18,0,0" Foreground="#D6DAE0" FontWeight="SemiBold"/>
    <TextBlock x:Name="ValidationText" Grid.Row="4" Margin="0,12,0,0" Foreground="#E88B8B" FontSize="11"/>
    <Grid Grid.Row="5" Margin="0,20,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Button x:Name="ContinueButton" Grid.Column="1" Content="Start deployment" MinWidth="140" Padding="16,9" Background="#2E6DB4" Foreground="White" BorderBrush="#4D8BD1"/></Grid>
  </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $rangeXaml
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    if ($script:Window) { $dialog.Owner = $script:Window }
    $startBox=$dialog.FindName('StartBox'); $endBox=$dialog.FindName('EndBox'); $preview=$dialog.FindName('Preview'); $validation=$dialog.FindName('ValidationText'); $continue=$dialog.FindName('ContinueButton')
    $startBox.Text=[string]$script:BatchStart; $endBox.Text=[string]$script:BatchEnd
    $updatePreview = {
        $a=0;$b=0
        if ([int]::TryParse($startBox.Text,[ref]$a) -and [int]::TryParse($endBox.Text,[ref]$b) -and $a -ge 1 -and $b -ge $a) {
            $first=('CS-{0}' -f $a.ToString('D2')); $last=('CS-{0}' -f $b.ToString('D2')); $count=$b-$a+1
            $preview.Text = if ($count -eq 1) { "$first | 1 Pi" } else { "$first through $last | $count Pis" }
        } else { $preview.Text='Enter a valid range.' }
    }
    $startBox.Add_TextChanged($updatePreview); $endBox.Add_TextChanged($updatePreview); & $updatePreview
    $continue.Add_Click({
        $a=0;$b=0;$validation.Text=''
        if (-not [int]::TryParse($startBox.Text,[ref]$a) -or -not [int]::TryParse($endBox.Text,[ref]$b)) { $validation.Text='Start and End must be whole numbers.'; return }
        if ($a -lt 1 -or $b -lt 1 -or $a -gt 999 -or $b -gt 999) { $validation.Text='Use CS numbers from 1 through 999.'; return }
        if ($b -lt $a) { $validation.Text='End number must be the same as or greater than Start.'; return }
        $script:BatchStart=$a; $script:BatchEnd=$b; $script:StudentNumber=$a
        $dialog.DialogResult=$true; $dialog.Close()
    })
    [void]$dialog.ShowDialog()
}

function Show-DeviceConfiguration([string]$role, [string]$deviceId) {
    $kind = if ($role -eq 'controller') { 'Control Pi' } else { 'Student Pi' }
    $userName=[string]$Config.accounts.user; $adminName=[string]$Config.accounts.admin; $rootName=[string]$Config.accounts.root
    [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Configure device" Width="520" Height="550" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#0F1115" FontFamily="Segoe UI">
  <Grid Margin="26"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock x:Name="Heading" Grid.Row="0" FontSize="24" FontWeight="SemiBold" Foreground="#F4F6F8"/><TextBlock x:Name="Subheading" Grid.Row="1" Margin="0,6,0,22" FontSize="12" Foreground="#98A2B3" TextWrapping="Wrap"/>
    <TextBlock x:Name="UserLabel" Grid.Row="2" Foreground="#AAB4C0" FontSize="12"/><PasswordBox x:Name="UserPassword" Grid.Row="3" Height="38" Margin="0,6,0,16" Padding="10,7" Background="#1D2129" Foreground="White" BorderBrush="#343B47"/>
    <TextBlock x:Name="AdminLabel" Grid.Row="4" Foreground="#AAB4C0" FontSize="12"/><PasswordBox x:Name="AdminPassword" Grid.Row="5" Height="38" Margin="0,6,0,12" Padding="10,7" Background="#1D2129" Foreground="White" BorderBrush="#343B47"/>
    <CheckBox x:Name="SameRoot" Grid.Row="6" Content="Use Admin password for Root" IsChecked="True" Foreground="#F4F6F8" Margin="0,2,0,14"/>
    <StackPanel Grid.Row="7"><TextBlock x:Name="RootLabel" Foreground="#AAB4C0" FontSize="12"/><PasswordBox x:Name="RootPassword" Height="38" Margin="0,6,0,0" Padding="10,7" Background="#1D2129" Foreground="White" BorderBrush="#343B47" IsEnabled="False"/></StackPanel>
    <TextBlock Grid.Row="8" Margin="0,18,0,0" Foreground="#717C89" FontSize="11" TextWrapping="Wrap" Text="Passwords are not saved on this Windows PC. Provisioning credentials are written to the SD card for first boot and must be consumed and removed by LGHS System."/>
    <Grid Grid.Row="9" Margin="0,22,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock x:Name="ValidationText" Grid.Column="0" Foreground="#E88B8B" VerticalAlignment="Center" FontSize="11"/><Button x:Name="CancelButton" Grid.Column="1" Content="Cancel" MinWidth="88" Padding="14,8" Margin="0,0,8,0" Background="#252A33" Foreground="White" BorderBrush="#343B47"/><Button x:Name="ContinueButton" Grid.Column="2" Content="Continue" MinWidth="100" Padding="14,8" Background="#2E6DB4" Foreground="White" BorderBrush="#4D8BD1"/></Grid>
  </Grid>
</Window>
'@
    $reader=New-Object System.Xml.XmlNodeReader $dialogXaml; $dialog=[Windows.Markup.XamlReader]::Load($reader); if ($script:Window) { $dialog.Owner=$script:Window }
    $heading=$dialog.FindName('Heading');$subheading=$dialog.FindName('Subheading');$userLabel=$dialog.FindName('UserLabel');$adminLabel=$dialog.FindName('AdminLabel');$rootLabel=$dialog.FindName('RootLabel');$userPassword=$dialog.FindName('UserPassword');$adminPassword=$dialog.FindName('AdminPassword');$rootPassword=$dialog.FindName('RootPassword');$sameRoot=$dialog.FindName('SameRoot');$validationText=$dialog.FindName('ValidationText');$cancelButton=$dialog.FindName('CancelButton');$continueButton=$dialog.FindName('ContinueButton')
    $heading.Text="Configure $kind - $deviceId";$subheading.Text="Set the three local account passwords for $deviceId before this SD card is written.";$userLabel.Text="User Password  ($userName)";$adminLabel.Text="Admin Password  ($adminName)";$rootLabel.Text="Root Password  ($rootName)";$sameRoot.IsChecked=[bool]$Config.accounts.defaultRootSameAsAdmin;$rootPassword.IsEnabled=-not $sameRoot.IsChecked
    $sameRoot.Add_Checked({$rootPassword.IsEnabled=$false;$rootPassword.Clear()});$sameRoot.Add_Unchecked({$rootPassword.IsEnabled=$true;$rootPassword.Focus()});$cancelButton.Add_Click({$dialog.DialogResult=$false;$dialog.Close()})
    $continueButton.Add_Click({$validationText.Text='';if([string]::IsNullOrEmpty($userPassword.Password)){$validationText.Text='Enter the User password.';$userPassword.Focus();return};if([string]::IsNullOrEmpty($adminPassword.Password)){$validationText.Text='Enter the Admin password.';$adminPassword.Focus();return};if(-not $sameRoot.IsChecked -and [string]::IsNullOrEmpty($rootPassword.Password)){$validationText.Text='Enter the Root password.';$rootPassword.Focus();return};$dialog.DialogResult=$true;$dialog.Close()})
    $accepted=$dialog.ShowDialog();if(-not $accepted){return $null};$rootValue=if($sameRoot.IsChecked){$adminPassword.Password}else{$rootPassword.Password}
    return [pscustomobject]@{UserName=$userName;UserPassword=$userPassword.Password;AdminName=$adminName;AdminPassword=$adminPassword.Password;RootName=$rootName;RootPassword=$rootValue;RootSameAsAdmin=[bool]$sameRoot.IsChecked}
}

function Write-ProvisionFiles([int]$diskNumber,[string]$deviceId,[string]$role,$credentials) {
    $deadline=(Get-Date).AddSeconds(25)
    do { Update-HostStorageCache -ErrorAction SilentlyContinue;Start-Sleep -Milliseconds 750;$parts=@(Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue)
        foreach($p in $parts){$vol=$p|Get-Volume -ErrorAction SilentlyContinue;if($vol -and $vol.FileSystem -eq 'FAT32'){$temporary=$false;if(-not $p.DriveLetter){$letter=Get-FreeDriveLetter;Set-Partition -DiskNumber $diskNumber -PartitionNumber $p.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop;$temporary=$true}else{$letter=[string]$p.DriveLetter}
            $publicPath="${letter}:\lghs-provision.conf";@("DEVICE_ID=$deviceId","TARGET_HOSTNAME=$deviceId","ROLE=$role",'BOARD=Raspberry Pi 5','MEMORY_GB=8','ARCH=arm64',"USER_ACCOUNT=$($credentials.UserName)","ADMIN_ACCOUNT=$($credentials.AdminName)","ROOT_ACCOUNT=$($credentials.RootName)","ROOT_SAME_AS_ADMIN=$([int]$credentials.RootSameAsAdmin)","PROVISIONED_AT=$((Get-Date).ToUniversalTime().ToString('o'))")|Set-Content -Encoding ascii $publicPath
            $secretPath="${letter}:\lghs-provision-secrets.conf";@('ENCODING=base64-utf8',"USER_PASSWORD_B64=$(ConvertTo-Base64Utf8 $credentials.UserPassword)","ADMIN_PASSWORD_B64=$(ConvertTo-Base64Utf8 $credentials.AdminPassword)","ROOT_PASSWORD_B64=$(ConvertTo-Base64Utf8 $credentials.RootPassword)")|Set-Content -Encoding ascii $secretPath
            if($temporary){Remove-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $p.PartitionNumber -AccessPath "${letter}:\" -ErrorAction SilentlyContinue};return}}
    } while((Get-Date)-lt $deadline);throw 'The Pi boot partition did not become available for LGHS provisioning.'
}

function Set-Mode([string]$mode) {
    $script:Mode=$mode;$StudentButton.IsChecked=($mode -eq 'student');$ControlButton.IsChecked=($mode -eq 'controller');$LocalButton.IsChecked=($mode -eq 'local')
    if($mode -eq 'student'){$TargetLabel.Text="$(Get-TargetId)  |  session CS-$($script:BatchStart.ToString('D2')) to CS-$($script:BatchEnd.ToString('D2'))";$ImageLabel.Text='LGHS Student'}elseif($mode -eq 'controller'){$TargetLabel.Text=[string]$Config.batch.controllerHostname;$ImageLabel.Text='LGHS Control'}else{$TargetLabel.Text=Get-TargetId;$ImageLabel.Text=if($script:LocalImage){[IO.Path]::GetFileName($script:LocalImage)}else{'Choose a local image'}}
}

function Append-Log([string]$text){if($LogBox){$LogBox.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $text`r`n");$LogBox.ScrollToEnd()}}
function Set-Busy([bool]$busy){$script:Busy=$busy;$WriteButton.IsEnabled=-not $busy;$RefreshButton.IsEnabled=-not $busy;$StudentButton.IsEnabled=-not $busy;$ControlButton.IsEnabled=-not $busy;$LocalButton.IsEnabled=-not $busy;$Progress.IsIndeterminate=$busy}
function Quote-ProcessArgument([string]$value){if($null -eq $value){return '""'};if($value -notmatch '[\s"]'){return $value};return '"'+($value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'}

function Start-Flash {
    if($script:Busy){return};if(-not $DriveBox.SelectedItem){[System.Windows.MessageBox]::Show('Insert and select an SD card first.','LGHS Imager')|Out-Null;return}
    $diskNumber=[int]$DriveBox.SelectedItem.Tag;$disk=Get-Disk -Number $diskNumber;$deviceId=Get-TargetId;$role=if($script:Mode -eq 'controller'){'controller'}else{'student'}
    if($script:Mode -eq 'local'){if(-not $script:LocalImage){[System.Windows.MessageBox]::Show('Choose a local image first.','LGHS Imager')|Out-Null;return};$image=$script:LocalImage;$sha=$null}else{$entry=Get-ImageEntry $role;if(-not $entry){[System.Windows.MessageBox]::Show("No $role image is available in the LGHS manifest.",'LGHS Imager')|Out-Null;return};$image=[string]$entry.url;$sha=[string]$entry.extract_sha256;if([string]::IsNullOrWhiteSpace($image)){[System.Windows.MessageBox]::Show("The $role image has not been published yet. Use Local Image for testing.",'LGHS Imager')|Out-Null;return}}
    $credentials=Show-DeviceConfiguration $role $deviceId;if(-not $credentials){Append-Log "Configuration for $deviceId was cancelled.";return}
    $confirm=[System.Windows.MessageBox]::Show("ERASE Disk $diskNumber ($($disk.FriendlyName), $(Format-Bytes $disk.Size)) and write $deviceId?","Confirm $deviceId write",[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Warning);if($confirm -ne [System.Windows.MessageBoxResult]::Yes){return}
    Set-Busy $true;$StatusText.Text="Writing $deviceId...";Append-Log "Starting $role image for $deviceId on Disk $diskNumber. Password values are not logged."
    try{$backend=Find-ImagerBackend;$backendArgs=@('--cli','--disable-telemetry');if($sha){$backendArgs+=@('--sha256',$sha)};$backendArgs+=@($image,"\\.\PhysicalDrive$diskNumber")
        $psi=New-Object System.Diagnostics.ProcessStartInfo;$psi.FileName=$backend;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.CreateNoWindow=$true;$psi.Arguments=(($backendArgs|ForEach-Object{Quote-ProcessArgument([string]$_)})-join ' ')
        $proc=New-Object System.Diagnostics.Process;$proc.StartInfo=$psi;[void]$proc.Start();while(-not $proc.HasExited){while(-not $proc.StandardOutput.EndOfStream){Append-Log $proc.StandardOutput.ReadLine();[System.Windows.Forms.Application]::DoEvents()};while(-not $proc.StandardError.EndOfStream){Append-Log $proc.StandardError.ReadLine();[System.Windows.Forms.Application]::DoEvents()};Start-Sleep -Milliseconds 100;[System.Windows.Forms.Application]::DoEvents()};while(-not $proc.StandardOutput.EndOfStream){Append-Log $proc.StandardOutput.ReadLine()};while(-not $proc.StandardError.EndOfStream){Append-Log $proc.StandardError.ReadLine()};if($proc.ExitCode -ne 0){throw "Raspberry Pi Imager backend exited with code $($proc.ExitCode)."}
        $StatusText.Text='Writing device configuration...';Write-ProvisionFiles $diskNumber $deviceId $role $credentials;$credentials=$null;Append-Log "Provisioning data written for $deviceId.";$StatusText.Text="$deviceId complete - safe to remove the card."
        if($script:Mode -eq 'student' -and $Config.batch.autoAdvanceAfterSuccessfulWrite){if($script:StudentNumber -lt $script:BatchEnd){$script:StudentNumber++;Set-Mode 'student';Append-Log "Batch advanced to $(Get-TargetId). The next Pi will ask for new passwords."}else{Append-Log "Student deployment CS-$($script:BatchStart.ToString('D2')) through CS-$($script:BatchEnd.ToString('D2')) is complete.";$StatusText.Text='Student batch complete.'}}
        Refresh-Drives
    }catch{$credentials=$null;Append-Log "ERROR: $($_.Exception.Message)";$StatusText.Text='Write failed.';[System.Windows.MessageBox]::Show($_.Exception.Message,'LGHS Imager write failed',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Error)|Out-Null}finally{Set-Busy $false}
}

$xamlPath=Join-Path $PSScriptRoot 'LGHS-Imager.xaml';if(-not(Test-Path $xamlPath)){throw "UI file not found: $xamlPath"};[xml]$xaml=Get-Content $xamlPath -Raw;$reader=New-Object System.Xml.XmlNodeReader $xaml;$script:Window=[Windows.Markup.XamlReader]::Load($reader)
foreach($name in @('StudentButton','ControlButton','LocalButton','ImageLabel','TargetLabel','DriveBox','RefreshButton','StatusText','Progress','LogBox','WriteButton','DetailsButton')){Set-Variable -Name $name -Value $script:Window.FindName($name)-Scope Script}
$StudentButton.Add_Checked({Set-Mode 'student'});$ControlButton.Add_Checked({Set-Mode 'controller'});$LocalButton.Add_Checked({Set-Mode 'local';$dlg=New-Object Microsoft.Win32.OpenFileDialog;$dlg.Title='Select LGHS image';$dlg.Filter='Disk images|*.img;*.zip;*.xz;*.gz|All files|*.*';if($dlg.ShowDialog()){$script:LocalImage=$dlg.FileName;Set-Mode 'local'}});$RefreshButton.Add_Click({Refresh-Drives});$WriteButton.Add_Click({Start-Flash})
$DetailsButton.Add_Click({if($LogBox.Visibility -eq [System.Windows.Visibility]::Collapsed){$LogBox.Visibility=[System.Windows.Visibility]::Visible;$DetailsButton.Content='Hide details'}else{$LogBox.Visibility=[System.Windows.Visibility]::Collapsed;$DetailsButton.Content='Show details'}})
$script:Window.Add_ContentRendered({if(-not $script:RangePromptShown){$script:RangePromptShown=$true;Show-BatchRangeConfiguration};Refresh-Drives;Set-Mode 'student';Append-Log "LGHS Imager ready. Student session is CS-$($script:BatchStart.ToString('D2')) through CS-$($script:BatchEnd.ToString('D2')). Each Pi requests new passwords before writing."})
$script:Window.Add_Closing({if($script:Busy){$_.Cancel=$true}})
[void]$script:Window.ShowDialog()
