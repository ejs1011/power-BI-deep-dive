param(
    [string]$Server = "vm-as-dbsql0011",
    [string]$Database = "KFX_REPORTING",
    [string]$SqlUser,
    [switch]$Apply,
    [switch]$CheckOnly,
    [switch]$OpenPbip
)

$ErrorActionPreference = "Stop"

$assetsRoot = Join-Path $PSScriptRoot "04 Assets - Reporting"
$pbipPath = Join-Path $assetsRoot "Kardex-v4.5.0_Productivity-v2_try.pbip"

$scripts = @(
    "create-reporting-productivity-work-events-v4.5.0.sql",
    "patch-reporting-productivity-views-v4.5.0.sql",
    "patch-reporting-supervisor-page-views-v4.5.0.sql",
    "validate-reporting-productivity-powerbi-patch-v4.5.0.sql",
    "validate-reporting-supervisor-page-views-v4.5.0.sql"
) | ForEach-Object { Join-Path $assetsRoot $_ }

$sqlPasswordPlain = $null
if ($SqlUser -and ($Apply -or $CheckOnly)) {
    $securePassword = Read-Host "SQL password for $SqlUser" -AsSecureString
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $sqlPasswordPlain = [Runtime.InteropServices.Marshal]::PtrToStringUni($passwordPointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
}

function New-SqlCmdArgs {
    param(
        [string]$InputFile,
        [string]$Query
    )

    $args = @("-S", $Server, "-d", $Database, "-b", "-r1")

    if ($SqlUser) {
        $args += @("-U", $SqlUser, "-P", $sqlPasswordPlain)
    } else {
        $args += "-E"
    }

    if ($InputFile) {
        $args += @("-i", $InputFile)
    }

    if ($Query) {
        $args += @("-Q", $Query)
    }

    return $args
}

function Invoke-SqlCmdChecked {
    param(
        [string]$InputFile,
        [string]$Query
    )

    $args = New-SqlCmdArgs -InputFile $InputFile -Query $Query
    & sqlcmd @args
    if ($LASTEXITCODE -ne 0) {
        if ($InputFile) {
            throw "sqlcmd failed for $InputFile"
        }
        throw "sqlcmd failed"
    }
}

foreach ($script in $scripts) {
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Missing script: $script"
    }
}

if ($CheckOnly) {
    Write-Host "Checking SQL connection and reporting object readiness..."
    Invoke-SqlCmdChecked -Query @"
SET NOCOUNT ON;
SELECT @@SERVERNAME AS ServerName, DB_NAME() AS CurrentDatabase, SUSER_SNAME() AS LoginName;
SELECT name, type_desc, modify_date
FROM sys.objects
WHERE name IN (
    'v_ProductivityWorkEvents_v2',
    'v_ProductivityDailyUserPortWorkType_v2',
    'Throughput',
    'OrdersCompletedHD',
    'LinesCompletedHD',
    'UnitsPickedHD',
    'BinPresentedHD',
    'Customer_Orders_Picked',
    'Customer_Order_Lines',
    'Units_Picked',
    'Distinct_Skus_Picked'
)
ORDER BY name;
"@
} elseif (-not $Apply) {
    Write-Host "Dry run only. Re-run with -Apply to execute against SQL Server."
    Write-Host ""
    Write-Host "Server:   $Server"
    Write-Host "Database: $Database"
    if ($SqlUser) {
        Write-Host "Auth:     SQL login $SqlUser"
    } else {
        Write-Host "Auth:     Windows integrated"
    }
    Write-Host ""
    foreach ($script in $scripts) {
        if ($SqlUser) {
            Write-Host "sqlcmd -S $Server -d $Database -U $SqlUser -P <prompted> -b -r1 -i `"$script`""
        } else {
            Write-Host "sqlcmd -S $Server -d $Database -E -b -r1 -i `"$script`""
        }
    }
} else {
    foreach ($script in $scripts) {
        Write-Host ""
        Write-Host "Running $([IO.Path]::GetFileName($script))..."
        Invoke-SqlCmdChecked -InputFile $script
    }

    Write-Host ""
    Write-Host "SQL patch and validations completed. Confirm the two validation gates above show PASS."
}

if ($OpenPbip) {
    if (-not (Test-Path -LiteralPath $pbipPath)) {
        throw "Missing PBIP file: $pbipPath"
    }

    $desktopPath = "C:\Program Files\Microsoft Power BI Desktop\bin\PBIDesktop.exe"
    if (-not (Test-Path -LiteralPath $desktopPath)) {
        throw "Power BI Desktop was not found at: $desktopPath"
    }

    Start-Process -FilePath $desktopPath -ArgumentList "`"$pbipPath`""
}
