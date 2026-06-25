param(
    [string]$Server = "vm-as-dbsql0011",
    [string]$Database = "KFX_REPORTING",
    [string]$SqlUser,
    [switch]$Apply,
    [switch]$ValidateOnly,
    [switch]$CheckOnly,
    [switch]$OpenPbip
)

$ErrorActionPreference = "Stop"

$assetsRoot = Join-Path $PSScriptRoot "04 Assets - Reporting"
$pbipPath = Join-Path $assetsRoot "Kardex-v4.5.0_Productivity-v2_try.pbip"
$staticValidatorPath = Join-Path $PSScriptRoot "validate-reporting-pbip-static.ps1"

$patchScripts = @(
    "create-reporting-productivity-work-events-v4.5.0.sql",
    "patch-reporting-productivity-views-v4.5.0.sql",
    "patch-reporting-supervisor-page-views-v4.5.0.sql"
) | ForEach-Object { Join-Path $assetsRoot $_ }

$validationScripts = @(
    "validate-reporting-productivity-powerbi-patch-v4.5.0.sql",
    "validate-reporting-supervisor-page-views-v4.5.0.sql",
    "validate-reporting-all-pages-smoke-v4.5.0.sql"
) | ForEach-Object { Join-Path $assetsRoot $_ }

$scripts = $patchScripts + $validationScripts

$expectedValidationGates = @{
    "validate-reporting-productivity-powerbi-patch-v4.5.0.sql" = "PowerBIPatchValidationGate"
    "validate-reporting-supervisor-page-views-v4.5.0.sql" = "SupervisorPageValidationGate"
    "validate-reporting-all-pages-smoke-v4.5.0.sql" = "AllPagesSmokeGate"
}

$sqlPasswordPlain = $null
if ($SqlUser -and ($Apply -or $ValidateOnly -or $CheckOnly)) {
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

    $args = @("-S", $Server, "-d", $Database, "-b")

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
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $outputLines = @(& sqlcmd @args 2>&1 | ForEach-Object { $_.ToString() })
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $outputLines | ForEach-Object { Write-Host $_ }

    if ($LASTEXITCODE -ne 0) {
        if ($InputFile) {
            throw "sqlcmd failed for $InputFile"
        }
        throw "sqlcmd failed"
    }

    if ($InputFile) {
        $fileName = [IO.Path]::GetFileName($InputFile)
        $expectedGate = $expectedValidationGates[$fileName]
        if ($expectedGate) {
            $outputText = $outputLines -join [Environment]::NewLine
            $gatePassedPattern = "(?ms)^\s*$([regex]::Escape($expectedGate))\b.*?\r?\n\s*-+.*?\r?\n\s*PASS\b"
            if ($outputText -notmatch $gatePassedPattern) {
                throw "Expected $expectedGate = PASS from $fileName."
            }
        }
    }
}

function Invoke-StaticValidation {
    Write-Host "Running local static PBIP validation..."
    & powershell -NoProfile -ExecutionPolicy Bypass -File $staticValidatorPath
    if ($LASTEXITCODE -ne 0) {
        throw "Static PBIP validation failed."
    }
}

foreach ($script in $scripts) {
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Missing script: $script"
    }
}

if (($Apply -or $ValidateOnly -or $OpenPbip) -and -not (Test-Path -LiteralPath $staticValidatorPath)) {
    throw "Missing static validator: $staticValidatorPath"
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
    'Distinct_Skus_Picked',
    'Total_SKUs_On_Hand',
    'Total_Units_On_Hand',
    'Total_Locations_Occupied',
    'Orders_Putaway',
    'Units_Putaway',
    'Skus_Putaway',
    'Presentations_Putaway',
    'Distinct_bin_compartments_that_had_inventory',
    'Distinct_bins_inventory_added',
    'InventoryAndLocationSummary',
    'DefragDetailByUomCompartmentSize_Table',
    'FulfillmentOrders',
    'FulfillmentOrderLines',
    'PutAwayContainers',
    'PutAwayContainerLineItems',
    'InventoryTasks',
    'InventoryTasks_CycleCount'
)
ORDER BY name;
"@
} elseif ($OpenPbip -and -not $Apply -and -not $ValidateOnly) {
    Invoke-StaticValidation
} elseif (-not $Apply -and -not $ValidateOnly) {
    Write-Host "Dry run only. Re-run with -Apply to execute against SQL Server."
    Write-Host "Use -ValidateOnly to run the validation gates without reapplying SQL patches."
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
            Write-Host "sqlcmd -S $Server -d $Database -U $SqlUser -P <prompted> -b -i `"$script`""
        } else {
            Write-Host "sqlcmd -S $Server -d $Database -E -b -i `"$script`""
        }
    }
} else {
    try {
        Invoke-StaticValidation
    } catch {
        throw "$($_.Exception.Message) SQL scripts were not applied."
    }

    $scriptsToRun = if ($ValidateOnly -and -not $Apply) { $validationScripts } else { $scripts }

    foreach ($script in $scriptsToRun) {
        Write-Host ""
        Write-Host "Running $([IO.Path]::GetFileName($script))..."
        Invoke-SqlCmdChecked -InputFile $script
    }

    Write-Host ""
    if ($ValidateOnly -and -not $Apply) {
        Write-Host "SQL validations completed. All expected validation gates showed PASS."
    } else {
        Write-Host "SQL patch and validations completed. All expected validation gates showed PASS."
    }
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
