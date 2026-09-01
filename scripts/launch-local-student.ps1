param(
    [Parameter(Mandatory=$true)]
    [string]$ImagePath,
    [string]$Sha256 = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Test-LghsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-LghsAdministrator)) {
    $resolved = (Resolve-Path $ImagePath).Path
    $argList = @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $MyInvocation.MyCommand.Path),
        '-ImagePath',('"{0}"' -f $resolved)
    )
    if (-not [string]::IsNullOrWhiteSpace($Sha256)) { $argList += @('-Sha256',$Sha256) }
    Start-Process powershell.exe -Verb RunAs -ArgumentList ($argList -join ' ') | Out-Null
    return
}

$ImagePath = (Resolve-Path $ImagePath).Path
if (-not (Test-Path $ImagePath -PathType Leaf)) { throw "Student image not found: $ImagePath" }
if ([IO.Path]::GetExtension($ImagePath).ToLowerInvariant() -notin @('.zip','.img','.xz','.gz')) {
    throw 'Managed Student image must be .zip, .img, .xz, or .gz.'
}

if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
    $actual = (Get-FileHash $ImagePath -Algorithm SHA256).Hash
    if (-not [string]::Equals($actual,$Sha256,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Student image SHA256 mismatch. Expected $Sha256, got $actual"
    }
    Write-Host "SHA256 verified: $actual" -ForegroundColor Green
}

$configPath = Join-Path $Root 'config\lghs-imager.json'
$osListPath = Join-Path $Root 'os-list\lghs-os-list.json'
$v11Path = Join-Path $Root 'app\LGHS-StockBootstrap-v11.ps1'
$launcherPath = Join-Path $Root 'scripts\launch.ps1'

$configOriginal = [IO.File]::ReadAllText($configPath)
$osListOriginal = [IO.File]::ReadAllText($osListPath)
$v11Original = [IO.File]::ReadAllText($v11Path)

try {
    $config = $configOriginal | ConvertFrom-Json
    $config.repository.manifest = 'local-managed-student-image'
    $config.fleet.controllerHost = 'LGCSCONT-CF'
    [IO.File]::WriteAllText($configPath,($config | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))

    $osList = $osListOriginal | ConvertFrom-Json
    $student = @($osList.os_list | Where-Object { $_.name -match 'Student' -and $_.devices -contains 'pi5' }) | Select-Object -First 1
    if (-not $student) { throw 'Student Pi 5 entry not found in local OS list.' }
    $student.url = $ImagePath
    $student.extract_sha256 = ''
    $student.image_download_size = (Get-Item $ImagePath).Length
    $student.release_date = (Get-Date).ToString('yyyy-MM-dd')
    [IO.File]::WriteAllText($osListPath,($osList | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))

    # Keep the managed local path aligned with the production Cloudflare-only
    # enrollment route. ProgramData avoids OpenSSH -o path parsing problems
    # when the Windows profile name contains spaces.
    $v11 = $v11Original.Replace(
        '$known = Join-Path $env:LOCALAPPDATA ''LGHS-Imager\deployment\controller_known_hosts''',
        '$known = Join-Path $env:ProgramData ''LGHS-Imager\deployment\controller_known_hosts'''
    ).Replace(
        "if ([string]::IsNullOrWhiteSpace(`$host)) { `$host = '192.168.50.2' }",
        "if ([string]::IsNullOrWhiteSpace(`$host)) { `$host = 'LGCSCONT-CF' }"
    )

    # PowerShell variable names are case-insensitive and $Host is a built-in
    # read-only automatic variable. The v11 enrollment helper historically used
    # $host, which fails at runtime with "Cannot overwrite variable Host".
    # Rewrite that local helper before launch until all installed copies have
    # moved to the corrected controllerHost name.
    $v11 = $v11.Replace(
        '$host = [string]$Config.fleet.controllerHost',
        '$controllerHost = [string]$Config.fleet.controllerHost'
    ).Replace(
        'if ([string]::IsNullOrWhiteSpace($host)) { $host = ''LGCSCONT-CF'' }',
        'if ([string]::IsNullOrWhiteSpace($controllerHost)) { $controllerHost = ''LGCSCONT-CF'' }'
    ).Replace(
        '"$user@$host"',
        '"$user@$controllerHost"'
    ).Replace(
        'at $host. $detail',
        'at $controllerHost. $detail'
    )

    if ($v11 -match '(?m)^\s*\$host\s*=') {
        throw 'Managed Student safety check failed: enrollment helper still assigns the reserved PowerShell $Host variable.'
    }
    if ($v11 -notmatch '\$controllerHost') {
        throw 'Managed Student safety check failed: corrected controllerHost variable is missing.'
    }

    [IO.File]::WriteAllText($v11Path,$v11,[Text.UTF8Encoding]::new($false))

    Write-Host ''
    Write-Host 'LGHS managed Student image ready:' -ForegroundColor Cyan
    Write-Host "  $ImagePath"
    Write-Host 'Fleet enrollment target: LGCSCONT-CF'
    Write-Host 'Use STUDENT mode in LGHS Imager; do not choose Local mode.' -ForegroundColor Yellow
    Write-Host ''

    & $launcherPath
}
finally {
    [IO.File]::WriteAllText($configPath,$configOriginal,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($osListPath,$osListOriginal,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($v11Path,$v11Original,[Text.UTF8Encoding]::new($false))
}
