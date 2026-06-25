param(
    [string]$ProjectRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

$assetsRoot = Join-Path $ProjectRoot "04 Assets - Reporting"
$pbipPath = Join-Path $assetsRoot "Kardex-v4.5.0_Productivity-v2_try.pbip"
$reportRoot = Join-Path $assetsRoot "Kardex-v4.5.0_Productivity-v2_try.Report"
$modelRoot = Join-Path $assetsRoot "Kardex-v4.5.0_Productivity-v2_try.SemanticModel"
$tablesRoot = Join-Path $modelRoot "definition\tables"
$relationshipsPath = Join-Path $modelRoot "definition\relationships.tmdl"
$bMeasurePath = Join-Path $tablesRoot "B Measure.tmdl"
$distinctUsersPath = Join-Path $tablesRoot "DistinctUsersTable.tmdl"
$distinctPortsPath = Join-Path $tablesRoot "%2F%2F DistinctPortsTable.tmdl"
$throughputPath = Join-Path $tablesRoot "Throughput.tmdl"
$orderPath = Join-Path $tablesRoot "Order.tmdl"
$supervisorPatchPath = Join-Path $assetsRoot "patch-reporting-supervisor-page-views-v4.5.0.sql"
$supervisorValidationPath = Join-Path $assetsRoot "validate-reporting-supervisor-page-views-v4.5.0.sql"
$allPagesSmokeValidationPath = Join-Path $assetsRoot "validate-reporting-all-pages-smoke-v4.5.0.sql"
$runnerPath = Join-Path $ProjectRoot "run-reporting-supervisor-rework.ps1"

$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Details = ""
    )

    $checks.Add([pscustomobject]@{
        Check = $Name
        Status = if ($Passed) { "PASS" } else { "FAIL" }
        Details = $Details
    })
}

function Test-FileContains {
    param(
        [string]$Path,
        [string]$Pattern
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    return [bool](Select-String -LiteralPath $Path -Pattern $Pattern -Quiet)
}

function Get-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }
    return Get-Content -LiteralPath $Path -Raw
}

function Test-PageRelativeDateDefault {
    param(
        [string]$PagePath,
        [string]$Entity,
        [string]$Property,
        [int]$Days
    )

    if (-not (Test-Path -LiteralPath $PagePath)) {
        return $false
    }

    try {
        $page = Get-Content -LiteralPath $PagePath -Raw | ConvertFrom-Json
    } catch {
        return $false
    }

    foreach ($filter in @($page.filterConfig.filters)) {
        $fieldColumn = $filter.field.Column
        if (-not $fieldColumn) {
            continue
        }

        $fieldEntity = $fieldColumn.Expression.SourceRef.Entity
        $fieldProperty = $fieldColumn.Property
        if ($filter.type -ne "RelativeDate" -or $fieldEntity -ne $Entity -or $fieldProperty -ne $Property) {
            continue
        }

        $between = $filter.filter.Where[0].Condition.Between
        if (-not $between) {
            continue
        }

        $expressionColumn = $between.Expression.Column
        $lowerDateAdd = $between.LowerBound.DateSpan.Expression.DateAdd
        $upperNow = $between.UpperBound.DateSpan.Expression.Now

        $isSameField = ($expressionColumn.Property -eq $Property)
        $isLastDays = ($lowerDateAdd.Amount -eq -$Days -and $lowerDateAdd.TimeUnit -eq 0 -and $lowerDateAdd.Expression.DateAdd.Amount -eq 1 -and $lowerDateAdd.Expression.DateAdd.TimeUnit -eq 0)
        $hasUpperNow = ($null -ne $upperNow)

        if ($isSameField -and $isLastDays -and $hasUpperNow) {
            return $true
        }
    }

    return $false
}

Add-Check "Replacement PBIP exists" (Test-Path -LiteralPath $pbipPath) $pbipPath
Add-Check "Replacement report folder exists" (Test-Path -LiteralPath $reportRoot) $reportRoot
Add-Check "Replacement semantic model folder exists" (Test-Path -LiteralPath $modelRoot) $modelRoot

$badJson = @()
if (Test-Path -LiteralPath $reportRoot) {
    Get-ChildItem -Path $reportRoot -Recurse -Filter *.json | ForEach-Object {
        try {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json | Out-Null
        } catch {
            $badJson += $_.FullName
        }
    }
}
Add-Check "All report JSON parses" ($badJson.Count -eq 0) (($badJson -join "; "))

$expectedPages = @(
    "Daily KPI Summary Report",
    "Inventory & Location Table Summary",
    "Productivity by User / Port",
    "Throughput",
    "Open Work History",
    "Historical Dashboard",
    "Consolidation Report"
)

$actualPages = @()
if (Test-Path -LiteralPath (Join-Path $reportRoot "definition\pages")) {
    $actualPages = Get-ChildItem -Path (Join-Path $reportRoot "definition\pages") -Directory | ForEach-Object {
        $pageJsonPath = Join-Path $_.FullName "page.json"
        if (Test-Path -LiteralPath $pageJsonPath) {
            (Get-Content -LiteralPath $pageJsonPath -Raw | ConvertFrom-Json).displayName
        }
    }
}
$missingPages = $expectedPages | Where-Object { $_ -notin $actualPages }
$extraPages = $actualPages | Where-Object { $_ -notin $expectedPages }
Add-Check "Report has exactly the expected 7 pages" (($missingPages.Count -eq 0) -and ($extraPages.Count -eq 0) -and ($actualPages.Count -eq 7)) ("Missing: $($missingPages -join ', '); Extra: $($extraPages -join ', ')")

$badPatterns = @{
    "No old SQL IP source in PBIP" = "10\.0\.26\.70"
    "No fake P-1 port labels" = "P-1"
    "No blocked report interactions" = '"type":\s*"NoFilter"'
    "No stale 2024 saved date range" = "datetime'2024-"
    "No stale Feb/Apr 2025 saved date range" = "datetime'2025-(02-20|04-09)"
    "No stale Mar/May 2026 saved date range" = "datetime'2026-(03-01|05-31)"
}

$scanFiles = @()
if (Test-Path -LiteralPath $reportRoot) {
    $scanFiles += Get-ChildItem -Path $reportRoot -Recurse -File
}
if (Test-Path -LiteralPath $modelRoot) {
    $scanFiles += Get-ChildItem -Path $modelRoot -Recurse -File
}

foreach ($item in $badPatterns.GetEnumerator()) {
    $hits = @()
    foreach ($file in $scanFiles) {
        if (Select-String -LiteralPath $file.FullName -Pattern $item.Value -Quiet) {
            $hits += $file.FullName
        }
    }
    Add-Check $item.Key ($hits.Count -eq 0) (($hits | Select-Object -First 5) -join "; ")
}

$reportFixedOldDateHits = @()
if (Test-Path -LiteralPath $reportRoot) {
    foreach ($file in (Get-ChildItem -Path $reportRoot -Recurse -File)) {
        if (Select-String -LiteralPath $file.FullName -Pattern "datetime'202[0-5]-" -Quiet) {
            $reportFixedOldDateHits += $file.FullName
        }
    }
}
Add-Check "No stale fixed pre-2026 report date selections" ($reportFixedOldDateHits.Count -eq 0) (($reportFixedOldDateHits | Select-Object -First 5) -join "; ")

$relationships = Get-Text $relationshipsPath
Add-Check "Productivity date relationship exists" ($relationships -match "fromColumn:\s+ProductivityDailyUserPortWorkType_v2\.EventDate\s+toColumn:\s+Calender\.DateOnly") "ProductivityDailyUserPortWorkType_v2.EventDate -> Calender.DateOnly"
Add-Check "Productivity user relationship exists" ($relationships -match "fromColumn:\s+ProductivityDailyUserPortWorkType_v2\.Users\s+toColumn:\s+DistinctUsersTable\.Users") "ProductivityDailyUserPortWorkType_v2.Users -> DistinctUsersTable.Users"
Add-Check "Productivity port relationship exists" ($relationships -match "fromColumn:\s+ProductivityDailyUserPortWorkType_v2\.Ports\s+toColumn:\s+'// DistinctPortsTable'\.Ports") "ProductivityDailyUserPortWorkType_v2.Ports -> // DistinctPortsTable.Ports"

$bMeasure = Get-Text $bMeasurePath
$requiredProductivityMeasures = @(
    "Total Logged Time per User",
    "Average Handle Time/Presentation per User",
    "Orders Completed per User",
    "Bin Presentations Completed per User",
    "Lines Completed per User",
    "Units Completed per User",
    "Orders/HR per User",
    "Bins/HR per User",
    "Units/HR per User",
    "Lines/HR per User",
    "Machine wait time per User",
    "Total Logged Time per Port",
    "Average Handle Time/Presentation per Port",
    "Bin Presentations Completed per Port",
    "Bins/HR per Port",
    "Lines Completed per Port",
    "Lines/HR per Port",
    "Machine wait time per Port",
    "Orders Completed per Port",
    "Orders/HR per Port",
    "Units Completed per Port",
    "Units/HR per Port"
)
$missingMeasures = $requiredProductivityMeasures | Where-Object { $bMeasure -notmatch [regex]::Escape("measure '$_'") }
Add-Check "All visible productivity measures exist" ($missingMeasures.Count -eq 0) (($missingMeasures -join ", "))
Add-Check "Productivity measures use daily event table" (([regex]::Matches($bMeasure, "ProductivityDailyUserPortWorkType_v2").Count) -ge 40) "References: $([regex]::Matches($bMeasure, 'ProductivityDailyUserPortWorkType_v2').Count)"
Add-Check "Productivity measures use 2 decimal display" (([regex]::Matches($bMeasure, "formatString:\s+0\.00").Count) -ge 22) "0.00 formats: $([regex]::Matches($bMeasure, 'formatString:\s+0\.00').Count)"

$helperMeasurePattern = "SUM\((TotalLoggedTimePerUser|AverageHandlingTimePerUser|OrdersCompletedPerUser|BinPresentationsCompletedPerUser|LinesCompletedPerUser|UnitsCompletedPerUser|OrdersPerHourPerUser|BinsPerHourPerUser|UnitsPerHourPerUser|LinesperHourPerUser|MachineWaitTimePerUser|TotalLoggedTimePerPort|AverageHandlingTimePerPort|OrdersCompletedPerPort|BinPresentationsCompletedPerPort|LinesCompletedPerPort|UnitsCompletedPerPort|OrdersPerHourPerPort|BinsPerHourPerPort|UnitsPerHourPerPort|LinesperHourPerPort|MachineWaitTimePerPort)"
Add-Check "Visible productivity measures no longer sum old helper views" (-not ($bMeasure -match $helperMeasurePattern)) ""

$distinctUsers = Get-Text $distinctUsersPath
$distinctPorts = Get-Text $distinctPortsPath
Add-Check "User slicer dimension uses daily productivity table" ($distinctUsers -match "ProductivityDailyUserPortWorkType_v2") ""
Add-Check "Port slicer dimension uses daily productivity table" ($distinctPorts -match "ProductivityDailyUserPortWorkType_v2") ""

$throughput = Get-Text $throughputPath
$order = Get-Text $orderPath
Add-Check "Throughput port sort preserves labels" (($throughput -match "Added PortSortOrder") -and ($throughput -match "parsedPort") -and ($throughput -notmatch "Table\.ReplaceValue\(.*P-1")) ""
Add-Check "Order port sort preserves labels" (($order -match "Added PortSortOrder") -and ($order -match "parsedPort") -and ($order -notmatch "Table\.ReplaceValue\(.*P-1")) ""

$productivityPageRoot = Join-Path $reportRoot "definition\pages\9dedfc2d00346dac59c6"
$productivityDateSlicer = Join-Path $productivityPageRoot "visuals\d8b91a4f2c7040eab315\visual.json"
Add-Check "Productivity page has date range slicer" ((Test-FileContains -Path $productivityDateSlicer -Pattern "Calender\.DateOnly") -and (Test-FileContains -Path $productivityDateSlicer -Pattern "'Between'")) $productivityDateSlicer

$dailyKpiPagePath = Join-Path $reportRoot "definition\pages\52a086fe840462b9286a\page.json"
$productivityPagePath = Join-Path $reportRoot "definition\pages\9dedfc2d00346dac59c6\page.json"
$throughputPagePath = Join-Path $reportRoot "definition\pages\16bd7bc02aabba06407d\page.json"
$openWorkPagePath = Join-Path $reportRoot "definition\pages\e390a00747581a892dea\page.json"
Add-Check "Daily KPI defaults to last 7 days" (Test-PageRelativeDateDefault -PagePath $dailyKpiPagePath -Entity "Calendar_1" -Property "DateOnly" -Days 7) $dailyKpiPagePath
Add-Check "Productivity defaults to last 7 days" (Test-PageRelativeDateDefault -PagePath $productivityPagePath -Entity "Calender" -Property "DateOnly" -Days 7) $productivityPagePath
Add-Check "Throughput defaults to last 7 days" (Test-PageRelativeDateDefault -PagePath $throughputPagePath -Entity "Throughput" -Property "Date" -Days 7) $throughputPagePath
Add-Check "Open Work History defaults to last 7 days" (Test-PageRelativeDateDefault -PagePath $openWorkPagePath -Entity "Calender" -Property "DateOnly" -Days 7) $openWorkPagePath

$productivityVisuals = @(
    (Join-Path $productivityPageRoot "visuals\60144cc4ee55004dc503\visual.json"),
    (Join-Path $productivityPageRoot "visuals\eaf9b8194b56ba1f624c\visual.json")
)
$requiredLabels = @(
    "Orders Completed \(orders\)",
    "Bin Presentations Completed \(bins\)",
    "Lines Completed \(lines\)",
    "Units Completed \(units\)",
    "Orders/hr",
    "Bins/hr",
    "Units/hr",
    "Lines/hr",
    "Machine Wait \(min\)",
    "Avg Handle \(min/pres\)",
    "Total Logged \(min\)"
)
$labelFailures = @()
foreach ($visualPath in $productivityVisuals) {
    $text = Get-Text $visualPath
    foreach ($label in $requiredLabels) {
        if ($text -notmatch $label) {
            $labelFailures += "$visualPath missing $label"
        }
    }
}
Add-Check "Productivity visual labels include units" ($labelFailures.Count -eq 0) (($labelFailures | Select-Object -First 5) -join "; ")

$supervisorPatch = Get-Text $supervisorPatchPath
$expectedViews = @(
    "OrdersCompletedHD",
    "LinesCompletedHD",
    "UnitsPickedHD",
    "BinPresentedHD",
    "Customer_Orders_Picked",
    "Customer_Order_Lines",
    "Units_Picked",
    "Distinct_Skus_Picked",
    "Throughput"
)
$missingViews = $expectedViews | Where-Object { $supervisorPatch -notmatch "CREATE OR ALTER VIEW \[dbo\]\.\[$_\]" }
Add-Check "Supervisor SQL patch defines all expected page views" ($missingViews.Count -eq 0) (($missingViews -join ", "))
Add-Check "Supervisor SQL patch rebuilds inventory summary from latest snapshots" (
    $supervisorPatch -match "CREATE OR ALTER PROCEDURE \[dbo\]\.\[InventoryAndLocationSummaryData\]" -and
    $supervisorPatch -match "MAX\(Snapshot_Id\)" -and
    $supervisorPatch -match "EXEC dbo\.InventoryAndLocationSummaryData"
) ""

$supervisorValidation = Get-Text $supervisorValidationPath
Add-Check "Supervisor SQL validation has gate" ($supervisorValidation -match "SupervisorPageValidationGate") ""
Add-Check "Supervisor SQL validation checks Daily KPI picking" ($supervisorValidation -match "Daily KPI picked orders" -and $supervisorValidation -match "Daily KPI distinct SKUs") ""

$allPagesSmokeValidation = Get-Text $allPagesSmokeValidationPath
$requiredSmokePages = @(
    "Daily KPI Summary Report",
    "Inventory & Location Table Summary",
    "Productivity by User / Port",
    "Throughput",
    "Open Work History",
    "Historical Dashboard",
    "Consolidation Report"
)
$missingSmokePages = $requiredSmokePages | Where-Object { $allPagesSmokeValidation -notmatch [regex]::Escape($_) }
Add-Check "All-pages smoke SQL validation exists" (Test-Path -LiteralPath $allPagesSmokeValidationPath) $allPagesSmokeValidationPath
Add-Check "All-pages smoke SQL validation has gate" ($allPagesSmokeValidation -match "AllPagesSmokeGate") ""
Add-Check "All-pages smoke SQL validation covers all report pages" ($missingSmokePages.Count -eq 0) (($missingSmokePages -join ", "))

$runnerText = Get-Text $runnerPath
Add-Check "Runner includes all-pages smoke validation" ($runnerText -match "validate-reporting-all-pages-smoke-v4\.5\.0\.sql") ""
Add-Check "Runner supports validation-only mode" ($runnerText -match '\[switch\]\$ValidateOnly' -and $runnerText -match '\$validationScripts') ""
Add-Check "Runner enforces SQL validation gates" (
    $runnerText -match "PowerBIPatchValidationGate" -and
    $runnerText -match "SupervisorPageValidationGate" -and
    $runnerText -match "AllPagesSmokeGate" -and
    $runnerText -match 'Expected \$expectedGate = PASS'
) ""

try {
    [scriptblock]::Create($runnerText) | Out-Null
    Add-Check "Runner script parses" $true $runnerPath
} catch {
    Add-Check "Runner script parses" $false $_.Exception.Message
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -ne "PASS" })
if ($failed.Count -gt 0) {
    Write-Error "Static PBIP validation failed: $($failed.Count) check(s)."
    exit 1
}

Write-Host ""
Write-Host "Static PBIP validation passed."
