param(
    [string]$Server = "vm-as-dbsql0011",
    [string]$Database = "KFX_REPORTING",
    [string]$SqlUser,
    [switch]$Apply,
    [switch]$ValidateOnly,
    [switch]$CheckOnly,
    [switch]$DiagnoseDailyKpi,
    [switch]$DiagnoseDailyKpiSync,
    [switch]$RepairDailyKpiSync,
    [switch]$OpenPbip,
    [string]$LogPath
)

$ErrorActionPreference = "Stop"

$assetsRoot = Join-Path $PSScriptRoot "04 Assets - Reporting"
$pbipPath = Join-Path $assetsRoot "Kardex-v4.5.0_Productivity-v2_try.pbip"
$savedPbixPath = Join-Path $assetsRoot "Kardex-v4.5.0_Supervisor-Rework.pbix"
$staticValidatorPath = Join-Path $PSScriptRoot "validate-reporting-pbip-static.ps1"

$patchScripts = @(
    "create-reporting-productivity-work-events-v4.5.0.sql",
    "patch-reporting-productivity-views-v4.5.0.sql",
    "patch-reporting-supervisor-page-views-v4.5.0.sql"
) | ForEach-Object { Join-Path $assetsRoot $_ }

$validationScripts = @(
    "validate-reporting-productivity-powerbi-patch-v4.5.0.sql",
    "validate-reporting-supervisor-page-views-v4.5.0.sql",
    "validate-reporting-all-pages-smoke-v4.5.0.sql",
    "validate-reporting-visible-metrics-v4.5.0.sql"
) | ForEach-Object { Join-Path $assetsRoot $_ }

$dailyKpiDiagnosticScript = Join-Path $assetsRoot "diagnose-reporting-daily-kpi-v4.5.0.sql"
$dailyKpiSyncDiagnosticScript = Join-Path $assetsRoot "diagnose-reporting-daily-kpi-sync-v4.5.0.sql"
$dailyKpiSyncRepairScript = Join-Path $assetsRoot "repair-reporting-daily-kpi-sync-v4.5.0.sql"

$scripts = $patchScripts + $validationScripts

$expectedValidationGates = @{
    "validate-reporting-productivity-powerbi-patch-v4.5.0.sql" = "PowerBIPatchValidationGate"
    "validate-reporting-supervisor-page-views-v4.5.0.sql" = "SupervisorPageValidationGate"
    "validate-reporting-all-pages-smoke-v4.5.0.sql" = "AllPagesSmokeGate"
    "validate-reporting-visible-metrics-v4.5.0.sql" = "VisibleMetricsValidationGate"
    "repair-reporting-daily-kpi-sync-v4.5.0.sql" = "DailyKpiSyncRepairGate"
}

$script:RunLogPath = $null

function Write-RunLine {
    param([string]$Message = "")

    Write-Host $Message
    if ($script:RunLogPath) {
        Add-Content -LiteralPath $script:RunLogPath -Value $Message
    }
}

function Write-RunLines {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        Write-RunLine $line
    }
}

function Initialize-RunLog {
    param([string]$Path)

    if (-not $Path) {
        return
    }

    $resolvedPath = if ([IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path $PSScriptRoot $Path
    }
    $parentPath = Split-Path -Parent $resolvedPath
    if ($parentPath -and -not (Test-Path -LiteralPath $parentPath)) {
        New-Item -ItemType Directory -Path $parentPath | Out-Null
    }

    $script:RunLogPath = $resolvedPath
    Set-Content -LiteralPath $script:RunLogPath -Value @(
        "Kardex reporting supervisor rework run"
        "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
        "Server: $Server"
        "Database: $Database"
        "Auth: $(if ($SqlUser) { "SQL login $SqlUser" } else { "Windows integrated" })"
        ""
    )
    Write-RunLine "Logging run output to: $script:RunLogPath"
}

$sqlPasswordPlain = $null
if ($SqlUser -and ($Apply -or $ValidateOnly -or $CheckOnly -or $DiagnoseDailyKpi -or $DiagnoseDailyKpiSync -or $RepairDailyKpiSync)) {
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

function Get-SqlGateFailureMessage {
    param(
        [string]$FileName,
        [string]$ExpectedGate,
        [string[]]$OutputLines
    )

    $diagnosticLines = New-Object System.Collections.Generic.List[string]
    $gateLineIndex = -1
    for ($i = 0; $i -lt $OutputLines.Count; $i++) {
        if ($OutputLines[$i] -match [regex]::Escape($ExpectedGate)) {
            $gateLineIndex = $i
            break
        }
    }

    if ($gateLineIndex -ge 0) {
        $diagnosticLines.Add("Gate summary:")
        $lastGateLine = [Math]::Min($OutputLines.Count - 1, $gateLineIndex + 3)
        for ($i = $gateLineIndex; $i -le $lastGateLine; $i++) {
            $diagnosticLines.Add($OutputLines[$i])
        }
    }

    $failedRows = @($OutputLines | Where-Object { $_ -match '\bFAIL\b' } | Select-Object -First 8)
    if ($failedRows.Count -gt 0) {
        $diagnosticLines.Add("First FAIL row(s):")
        foreach ($line in $failedRows) {
            $diagnosticLines.Add($line)
        }
    }

    if ($diagnosticLines.Count -eq 0) {
        $diagnosticLines.Add("Last sqlcmd output lines:")
        foreach ($line in ($OutputLines | Select-Object -Last 12)) {
            $diagnosticLines.Add($line)
        }
    }

    return @(
        "Expected $ExpectedGate = PASS from $FileName."
        ($diagnosticLines -join [Environment]::NewLine)
    ) -join [Environment]::NewLine
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
    Write-RunLines $outputLines

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
            $escapedGate = [regex]::Escape($expectedGate)
            $gatePassedSameLinePattern = "(?m)^\s*$escapedGate\s+PASS\b"
            $gatePassedWrappedPattern = "(?ms)^\s*$escapedGate\b.*?\r?\n\s*-+.*?\r?\n\s*PASS\b"
            if ($outputText -notmatch $gatePassedSameLinePattern -and $outputText -notmatch $gatePassedWrappedPattern) {
                throw (Get-SqlGateFailureMessage -FileName $fileName -ExpectedGate $expectedGate -OutputLines $outputLines)
            }
        }
    }
}

function Invoke-StaticValidation {
    Write-RunLine "Running local static PBIP validation..."
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $outputLines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $staticValidatorPath 2>&1 | ForEach-Object { $_.ToString() })
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Write-RunLines $outputLines
    if ($LASTEXITCODE -ne 0) {
        throw "Static PBIP validation failed."
    }
}

foreach ($script in $scripts) {
    if (-not (Test-Path -LiteralPath $script)) {
        throw "Missing script: $script"
    }
}

if ($DiagnoseDailyKpi -and -not (Test-Path -LiteralPath $dailyKpiDiagnosticScript)) {
    throw "Missing Daily KPI diagnostic script: $dailyKpiDiagnosticScript"
}

if ($DiagnoseDailyKpiSync -and -not (Test-Path -LiteralPath $dailyKpiSyncDiagnosticScript)) {
    throw "Missing Daily KPI sync diagnostic script: $dailyKpiSyncDiagnosticScript"
}

if ($RepairDailyKpiSync -and -not (Test-Path -LiteralPath $dailyKpiSyncRepairScript)) {
    throw "Missing Daily KPI sync repair script: $dailyKpiSyncRepairScript"
}

if (($Apply -or $ValidateOnly -or $OpenPbip) -and -not (Test-Path -LiteralPath $staticValidatorPath)) {
    throw "Missing static validator: $staticValidatorPath"
}

Initialize-RunLog -Path $LogPath

if ($RepairDailyKpiSync) {
    Write-RunLine "Running Daily KPI sync repair..."
    Invoke-SqlCmdChecked -InputFile $dailyKpiSyncRepairScript
} elseif ($DiagnoseDailyKpiSync) {
    Write-RunLine "Running Daily KPI sync diagnostic query..."
    Invoke-SqlCmdChecked -InputFile $dailyKpiSyncDiagnosticScript
} elseif ($DiagnoseDailyKpi) {
    Write-RunLine "Running Daily KPI diagnostic query..."
    Invoke-SqlCmdChecked -InputFile $dailyKpiDiagnosticScript
} elseif ($CheckOnly) {
    Write-RunLine "Checking SQL connection and reporting object readiness..."
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
    Write-RunLine ""
    Write-RunLine "Opening PBIP without applying SQL patches."
    Write-RunLine "If SQL patches have not been applied after the latest repo changes, refresh may fail or show stale metrics."
    Write-RunLine "Use -Apply -OpenPbip to apply SQL patches, run SQL gates, and then open Power BI."
} elseif (-not $Apply -and -not $ValidateOnly) {
    Write-RunLine "Dry run only. Re-run with -Apply to execute against SQL Server."
    Write-RunLine "Use -ValidateOnly to run the validation gates without reapplying SQL patches."
    Write-RunLine "Use -DiagnoseDailyKpi to troubleshoot the Daily KPI source rows."
    Write-RunLine "Use -DiagnoseDailyKpiSync to troubleshoot the Daily KPI snapshot sync pipeline."
    Write-RunLine "Use -RepairDailyKpiSync to fix a stuck DynamicTableInsert snapshot sync."
    Write-RunLine ""
    Write-RunLine "Server:   $Server"
    Write-RunLine "Database: $Database"
    if ($SqlUser) {
        Write-RunLine "Auth:     SQL login $SqlUser"
    } else {
        Write-RunLine "Auth:     Windows integrated"
    }
    Write-RunLine ""
    foreach ($script in $scripts) {
        if ($SqlUser) {
            Write-RunLine "sqlcmd -S $Server -d $Database -U $SqlUser -P <prompted> -b -i `"$script`""
        } else {
            Write-RunLine "sqlcmd -S $Server -d $Database -E -b -i `"$script`""
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
        Write-RunLine ""
        Write-RunLine "Running $([IO.Path]::GetFileName($script))..."
        Invoke-SqlCmdChecked -InputFile $script
    }

    Write-RunLine ""
    if ($ValidateOnly -and -not $Apply) {
        Write-RunLine "SQL validations completed. All expected validation gates showed PASS."
    } else {
        Write-RunLine "SQL patch and validations completed. All expected validation gates showed PASS."
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
    Write-RunLine ""
    Write-RunLine "Opened replacement PBIP: $pbipPath"
    Write-RunLine "Confirm SQL patch/validation has run after the latest repo changes before trusting refreshed values."
    Write-RunLine "In Power BI Desktop, refresh the report and save as/over:"
    Write-RunLine $savedPbixPath
}
