param(
    [string]$ProjectRoot = $PSScriptRoot,
    [switch]$RequireCurrentPbix
)

$ErrorActionPreference = "Stop"

$assetsRoot = Join-Path $ProjectRoot "04 Assets - Reporting"
$pbipPath = Join-Path $assetsRoot "Kardex PowerBI 2.0 Beta.pbip"
$savedPbixPath = Join-Path $assetsRoot "Kardex PowerBI 2.0 Beta.pbix"
$reportRoot = Join-Path $assetsRoot "Kardex PowerBI 2.0 Beta.Report"
$modelRoot = Join-Path $assetsRoot "Kardex PowerBI 2.0 Beta.SemanticModel"
$tablesRoot = Join-Path $modelRoot "definition\tables"
$relationshipsPath = Join-Path $modelRoot "definition\relationships.tmdl"
$aMeasurePath = Join-Path $tablesRoot "A Measure.tmdl"
$bMeasurePath = Join-Path $tablesRoot "B Measure.tmdl"
$measureGroupsPath = Join-Path $tablesRoot "_MeasureGroups.tmdl"
$metricsSlicerPath = Join-Path $tablesRoot "MetricsSlicer.tmdl"
$metricsSlicerOwhPath = Join-Path $tablesRoot "MetricsSlicer OWH.tmdl"
$kpiSeriesPath = Join-Path $tablesRoot "KPI_Series.tmdl"
$distinctUsersPath = Join-Path $tablesRoot "DistinctUsersTable.tmdl"
$distinctPortsPath = Join-Path $tablesRoot "%2F%2F DistinctPortsTable.tmdl"
$totalSkusOnHandPath = Join-Path $tablesRoot "Total_SKUs_On_Hand.tmdl"
$throughputPath = Join-Path $tablesRoot "Throughput.tmdl"
$orderPath = Join-Path $tablesRoot "Order.tmdl"
$supervisorPatchPath = Join-Path $assetsRoot "patch-reporting-supervisor-page-views-v4.5.0.sql"
$supervisorValidationPath = Join-Path $assetsRoot "validate-reporting-supervisor-page-views-v4.5.0.sql"
$allPagesSmokeValidationPath = Join-Path $assetsRoot "validate-reporting-all-pages-smoke-v4.5.0.sql"
$visibleMetricsValidationPath = Join-Path $assetsRoot "validate-reporting-visible-metrics-v4.5.0.sql"
$runnerPath = Join-Path $ProjectRoot "run-reporting-supervisor-rework.ps1"
$readmePath = Join-Path $ProjectRoot "README.md"
$culturePath = Join-Path $modelRoot "definition\cultures\en-US.tmdl"

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

function Add-Warning {
    param(
        [string]$Name,
        [string]$Details = ""
    )

    $checks.Add([pscustomobject]@{
        Check = $Name
        Status = "WARN"
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

function Test-SqlFileHasRequiredSetOptions {
    param([string]$Path)

    $text = Get-Text $Path
    if ($text -eq "") {
        return $false
    }

    $requiredSetOptions = @(
        "SET ANSI_NULLS ON",
        "SET QUOTED_IDENTIFIER ON",
        "SET ANSI_PADDING ON",
        "SET ANSI_WARNINGS ON",
        "SET ARITHABORT ON",
        "SET CONCAT_NULL_YIELDS_NULL ON",
        "SET NUMERIC_ROUNDABORT OFF"
    )

    foreach ($option in $requiredSetOptions) {
        if ($text -notmatch [regex]::Escape($option)) {
            return $false
        }
    }

    return $true
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

function Test-VisualRelativeDateDefault {
    param(
        [string]$VisualPath,
        [string]$Entity,
        [string]$Property,
        [int]$Days
    )

    if (-not (Test-Path -LiteralPath $VisualPath)) {
        return $false
    }

    try {
        $visual = Get-Content -LiteralPath $VisualPath -Raw | ConvertFrom-Json
    } catch {
        return $false
    }

    foreach ($filter in @($visual.filterConfig.filters)) {
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

function Get-VisualQueryRefs {
    param([string]$ReportRoot)

    $pageRoot = Join-Path $ReportRoot "definition\pages"
    if (-not (Test-Path -LiteralPath $pageRoot)) {
        return @()
    }

    $bindings = @()
    foreach ($pageDir in (Get-ChildItem -LiteralPath $pageRoot -Directory)) {
        $pageName = $pageDir.Name
        $pageJsonPath = Join-Path $pageDir.FullName "page.json"
        if (Test-Path -LiteralPath $pageJsonPath) {
            try {
                $pageName = ((Get-Content -LiteralPath $pageJsonPath -Raw) | ConvertFrom-Json).displayName
            } catch {
                $pageName = $pageDir.Name
            }
        }

        foreach ($visualFile in (Get-ChildItem -LiteralPath $pageDir.FullName -Recurse -Filter visual.json)) {
            $visualText = Get-Text $visualFile.FullName
            foreach ($match in [regex]::Matches($visualText, '"queryRef"\s*:\s*"([^"]+)"')) {
                $bindings += [pscustomobject]@{
                    Page = $pageName
                    Visual = Split-Path -Leaf (Split-Path -Parent $visualFile.FullName)
                    QueryRef = $match.Groups[1].Value
                }
            }
        }
    }

    return $bindings
}

function Test-PageTreeHasNoDateFilters {
    param([string]$PageRoot)

    if (-not (Test-Path -LiteralPath $PageRoot)) {
        return $false
    }

    foreach ($file in (Get-ChildItem -LiteralPath $PageRoot -Recurse -Filter *.json)) {
        $text = Get-Text $file.FullName
        $hasDateFilter = (
            $text -match '"type"\s*:\s*"RelativeDate"' -or
            $text -match "datetime'" -or
            $text -match '"Property"\s*:\s*"DateOnly"' -or
            $text -match '"Property"\s*:\s*"Date"'
        )
        if ($hasDateFilter) {
            return $false
        }
    }

    return $true
}

Add-Check "Replacement PBIP exists" (Test-Path -LiteralPath $pbipPath) $pbipPath
Add-Check "Replacement report folder exists" (Test-Path -LiteralPath $reportRoot) $reportRoot
Add-Check "Replacement semantic model folder exists" (Test-Path -LiteralPath $modelRoot) $modelRoot
Add-Check "Saved Beta PBIX candidate exists" (Test-Path -LiteralPath $savedPbixPath) $savedPbixPath

if ((Test-Path -LiteralPath $savedPbixPath) -and (Test-Path -LiteralPath $reportRoot) -and (Test-Path -LiteralPath $modelRoot)) {
    $allSourceFiles = @(
        Get-Item -LiteralPath $pbipPath -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $reportRoot -Recurse -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $modelRoot -Recurse -File -ErrorAction SilentlyContinue
    ) | Where-Object { $_ }

    $sourceFiles = @(
        $allSourceFiles | Where-Object {
            $fullName = $_.FullName
            $leafName = $_.Name
            $isPbipPackageFile = (
                $fullName -ieq $pbipPath -or
                $leafName -ieq ".platform" -or
                $leafName -ieq "definition.pbir" -or
                $fullName -match "\\\.pbi\\"
            )
            -not $isPbipPackageFile
        }
    )

    $newestSource = $sourceFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $savedPbix = Get-Item -LiteralPath $savedPbixPath
    if ($newestSource -and $savedPbix.LastWriteTime -lt $newestSource.LastWriteTime) {
        $freshnessDetails = "PBIX: $($savedPbix.LastWriteTime); newest source: $($newestSource.LastWriteTime) $($newestSource.FullName)"
        if ($RequireCurrentPbix) {
            Add-Check "Saved Beta PBIX is current with PBIP source" $false $freshnessDetails
        } else {
            Add-Warning "Saved Beta PBIX is older than PBIP source" $freshnessDetails
        }
    } else {
        $newerPackageMetadata = @(
            $allSourceFiles | Where-Object {
                $_.LastWriteTime -gt $savedPbix.LastWriteTime -and $_.FullName -notin @($sourceFiles | ForEach-Object { $_.FullName })
            } | Sort-Object LastWriteTime -Descending | Select-Object -First 3
        )
        $packageDetails = if ($newerPackageMetadata.Count -gt 0) {
            "PBIX content is current. Newer PBIP package metadata: $($newerPackageMetadata.FullName -join '; ')"
        } else {
            $savedPbixPath
        }
        Add-Check "Saved Beta PBIX is current with PBIP source" $true $packageDetails
    }
}

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

$visualBindings = @(Get-VisualQueryRefs -ReportRoot $reportRoot)
$pagesWithDataBindings = @($visualBindings | Select-Object -ExpandProperty Page -Unique)
$pagesMissingBindings = $expectedPages | Where-Object { $_ -notin $pagesWithDataBindings }
Add-Check "Every report page has data-bound visuals" ($pagesMissingBindings.Count -eq 0) (($pagesMissingBindings -join ", "))

$allowedVisualBindingsByPage = @{
    "Daily KPI Summary Report" = @(
        '^Calendar_1\.DateOnly$',
        '^_MeasureGroups\.(GroupName|MeasureName)$',
        '^B Measure\._DynamicMeasure$'
    )
    "Inventory & Location Table Summary" = @(
        '^InventoryAndLocationSummary\.(CompartmentLabel|MetricName)$',
        '^Min\(InventoryAndLocationSummary\.MetricValue\)$'
    )
    "Productivity by User / Port" = @(
        '^Calender\.DateOnly$',
        '^DistinctUsersTable\.Users$',
        '^DistinctPortsTable\.Ports$',
        '^B Measure\.(Orders Completed|Bin Presentations Completed|Lines Completed|Units Completed|Orders/HR|Bins/HR|Units/HR|Lines/HR|Machine wait time|Average Handle Time/Presentation|Total Logged Time) per (User|Port)$'
    )
    "Throughput" = @(
        '^Throughput\.(Date|Hour|Ports|OrderCategory)$',
        '^MetricsSlicer\.Metric$',
        '^A Measure\.KPI_Selected$'
    )
    "Open Work History" = @(
        '^Calender\.DateOnly$',
        '^MetricsSlicer OWH\.Metric$',
        '^KPI_Series\.Series$',
        '^A Measure\.KPI_Selected_OWH$'
    )
    "Historical Dashboard" = @(
        '^OrdersCompletedHD\.Date$',
        '^LinesCompletedHD\.Date$',
        '^UnitsPickedHD\.Date$',
        '^BinPresentedHD\.Date$',
        '^Sum\(OrdersCompletedHD\.OrdersCompleted\)$',
        '^Sum\(LinesCompletedHD\.LinesCompleted\)$',
        '^Sum\(UnitsPickedHD\.UnitsPicked\)$',
        '^Sum\(BinPresentedHD\.BinPresented\)$'
    )
    "Consolidation Report" = @(
        '^DefragDetailByUomCompartmentSize_Table\.(Sku|CompartmentSizeName)$',
        '^Sum\(DefragDetailByUomCompartmentSize_Table\.Quantity\)$',
        '^A Measure\.(Total Compartments|Fragmentation)$'
    )
}
$unexpectedBindings = @()
foreach ($binding in $visualBindings) {
    $patterns = $allowedVisualBindingsByPage[$binding.Page]
    if (-not $patterns) {
        $unexpectedBindings += "$($binding.Page)/$($binding.Visual): $($binding.QueryRef)"
        continue
    }

    $isAllowed = $false
    foreach ($pattern in $patterns) {
        if ($binding.QueryRef -match $pattern) {
            $isAllowed = $true
            break
        }
    }

    if (-not $isAllowed) {
        $unexpectedBindings += "$($binding.Page)/$($binding.Visual): $($binding.QueryRef)"
    }
}
Add-Check "Visible visuals use approved report-facing bindings" ($unexpectedBindings.Count -eq 0) (($unexpectedBindings | Select-Object -First 8) -join "; ")

$badPatterns = @{
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

$sqlSourceServers = @()
foreach ($file in @($scanFiles | Where-Object { $_.FullName -like "$modelRoot*" })) {
    $text = Get-Text $file.FullName
    foreach ($match in [regex]::Matches($text, 'Sql\.Database\("([^"]+)",\s*"KFX_REPORTING"\)')) {
        $sqlSourceServers += $match.Groups[1].Value
    }
}
$distinctSqlSourceServers = @($sqlSourceServers | Sort-Object -Unique)
Add-Check "PBIP SQL sources use one KFX_REPORTING server" (
    ($sqlSourceServers.Count -gt 0) -and ($distinctSqlSourceServers.Count -eq 1)
) ("Servers: $($distinctSqlSourceServers -join ', '); references: $($sqlSourceServers.Count)")

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

$aMeasure = Get-Text $aMeasurePath
$bMeasure = Get-Text $bMeasurePath
$productivityDailyTablePath = Join-Path $tablesRoot "ProductivityDailyUserPortWorkType_v2.tmdl"
$productivityDailyTable = Get-Text $productivityDailyTablePath
$supervisorPatch = Get-Text $supervisorPatchPath
$allPagesSmokeValidation = Get-Text $allPagesSmokeValidationPath
$visibleMetricsValidation = Get-Text $visibleMetricsValidationPath
$culture = Get-Text $culturePath
$measureGroups = Get-Text $measureGroupsPath
$metricsSlicer = Get-Text $metricsSlicerPath
$metricsSlicerOwh = Get-Text $metricsSlicerOwhPath
$kpiSeries = Get-Text $kpiSeriesPath
$containerTemplateCompartmentsPath = Join-Path $tablesRoot "ContainerTemplateCompartments.tmdl"
$containerTemplateCompartments = Get-Text $containerTemplateCompartmentsPath
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
$productivityMeasureBlockMatch = [regex]::Match($bMeasure, "(?s)measure 'Total Logged Time per User'.*?partition 'B Measure'")
$productivityMeasureBlock = if ($productivityMeasureBlockMatch.Success) { $productivityMeasureBlockMatch.Value } else { "" }
$productivityActivityMeasureMatch = [regex]::Match($bMeasure, "(?s)measure 'Productivity Pick Activity'.*?measure 'Total Logged Time per User'")
$productivityActivityMeasure = if ($productivityActivityMeasureMatch.Success) { $productivityActivityMeasureMatch.Value } else { "" }
$activityBasisColumns = @(
    "OrdersCompleted",
    "BinPresentationsCompleted",
    "LinesCompleted",
    "UnitsCompleted",
    "MachineWaitMinutes",
    "ActiveHandleMinutes",
    "TotalLoggedMinutes",
    "RateDenominatorHours"
)
$missingActivityBasisColumns = $activityBasisColumns | Where-Object {
    $productivityDailyTable -notmatch [regex]::Escape("column $_") -or
    $productivityActivityMeasure -notmatch [regex]::Escape("ProductivityDailyUserPortWorkType_v2[$_]")
}
Add-Check "Productivity measures leave no-activity rows blank" (
    $productivityMeasureBlock -ne "" -and
    $bMeasure -match "measure 'Productivity Pick Activity'" -and
    $productivityActivityMeasure -notmatch "ProductivityDailyUserPortWorkType_v2\[ProductivityActivityBasis\]" -and
    $missingActivityBasisColumns.Count -eq 0 -and
    ([regex]::Matches($productivityMeasureBlock, "\[Productivity Pick Activity\]").Count) -ge 22 -and
    $productivityMeasureBlock -notmatch "\)\s*\+\s*0" -and
    $productivityMeasureBlock -notmatch ',\s*0\s*\)\s*```'
) (($missingActivityBasisColumns -join ", "))

$helperMeasurePattern = "SUM\((TotalLoggedTimePerUser|AverageHandlingTimePerUser|OrdersCompletedPerUser|BinPresentationsCompletedPerUser|LinesCompletedPerUser|UnitsCompletedPerUser|OrdersPerHourPerUser|BinsPerHourPerUser|UnitsPerHourPerUser|LinesperHourPerUser|MachineWaitTimePerUser|TotalLoggedTimePerPort|AverageHandlingTimePerPort|OrdersCompletedPerPort|BinPresentationsCompletedPerPort|LinesCompletedPerPort|UnitsCompletedPerPort|OrdersPerHourPerPort|BinsPerHourPerPort|UnitsPerHourPerPort|LinesperHourPerPort|MachineWaitTimePerPort)"
Add-Check "Visible productivity measures no longer sum old helper views" (-not ($bMeasure -match $helperMeasurePattern)) ""
Add-Check "Throughput slicer options map to visible DAX metrics" (
    ($metricsSlicer -match '\{"Orders"\}') -and
    ($metricsSlicer -match '\{"Lines"\}') -and
    ($metricsSlicer -match '\{"Bins"\}') -and
    ($metricsSlicer -match '\{"All"\}') -and
    ($aMeasure -match 'measure KPI_Selected[\s\S]*SELECTEDVALUE\(MetricsSlicer\[Metric\]\)\s*=\s*"Orders", \[Orders\]') -and
    ($aMeasure -match 'measure KPI_Selected[\s\S]*SELECTEDVALUE\(MetricsSlicer\[Metric\]\)\s*=\s*"Lines", \[Lines\]') -and
    ($aMeasure -match 'measure KPI_Selected[\s\S]*SELECTEDVALUE\(MetricsSlicer\[Metric\]\)\s*=\s*"Bins", \[Bins\]') -and
    ($aMeasure -match 'measure KPI_Selected[\s\S]*SELECTEDVALUE\(MetricsSlicer\[Metric\]\)\s*=\s*"All", \[All_Orders\+Lines\+Bins\]')
) ""
Add-Check "Open Work pick statuses include exception work" (($aMeasure -match "FulfillmentOrders\[Status\]\s+IN") -and ($aMeasure -match '"failed allocation"') -and ($aMeasure -match '"falied allocation"') -and ($aMeasure -match '"shorted"')) ""
Add-Check "Open Work putaway lines exclude closed containers" ($aMeasure -match "measure 'PutAwayLineItemsCount \(Lines\)'[\s\S]*PutAwayContainers\[IsClosed\]\s*=\s*FALSE\(\)") ""
Add-Check "Open Work cycle count uses task relationship not date crossjoin" (
    ($aMeasure -match "DISTINCTCOUNT\('InventoryTasks \(2\)'\[TaskGroupPrimaryKey\]\)") -and
    ($aMeasure -match "COUNTROWS\(InventoryTasks_CycleCount\)") -and
    ($aMeasure -notmatch "CROSSJOIN\(\s*InventoryTasks_CycleCount") -and
    ($aMeasure -notmatch "DATEVALUE\(\s*InventoryTasks_CycleCount\[LastUpdatedDate\]")
) ""
Add-Check "Open Work slicer options map to visible DAX series" (
    ($metricsSlicerOwh -match '\{"Orders"\}') -and
    ($metricsSlicerOwh -match '\{"Lines"\}') -and
    ($metricsSlicerOwh -match '\{"All"\}') -and
    ($metricsSlicerOwh -notmatch '\{"Bins"\}') -and
    ($kpiSeries -match '\{"Orders Pick"\}') -and
    ($kpiSeries -match '\{"Orders Put"\}') -and
    ($kpiSeries -match '\{"Orders Cycle Count"\}') -and
    ($kpiSeries -match '\{"Lines Pick"\}') -and
    ($kpiSeries -match '\{"Lines Put"\}') -and
    ($kpiSeries -match '\{"Lines Cycle Count"\}') -and
    ($aMeasure -match 'SelectedMetric,\s*"Orders"[\s\S]*"Orders Pick", \[FulfillmentOrdersCount \(Orders\)\][\s\S]*"Lines"[\s\S]*"Lines Pick", \[FulfillmentOrderLinesCount \(Lines\)\][\s\S]*"All"')
) ""
Add-Check "Stray test measures are hidden" (
    ($aMeasure -match "measure 'test Orders Putaway'[\s\S]*?\n\t\tisHidden") -and
    ($aMeasure -match "measure 'test Customer Orders Picked'[\s\S]*?\n\t\tisHidden") -and
    ($aMeasure -match "measure 'test Customer Order Lines'[\s\S]*?\n\t\tisHidden") -and
    ($aMeasure -match "measure 'test OpenCycleCountTasks \(Lines\)'[\s\S]*?\n\t\tisHidden") -and
    ($containerTemplateCompartments -match "measure 'test container'[\s\S]*?\n\t\tisHidden") -and
    ($containerTemplateCompartments -match "measure 'test CountRows'[\s\S]*?\n\t\tisHidden")
) ""
Add-Check "Daily KPI inventory labels match current-state calculations" (
    ($measureGroups -match '"Distinct Bins With Inventory"') -and
    ($measureGroups -notmatch '"Distinct Bins With Inventory Added"') -and
    ($bMeasure -match 'SELECTEDVALUE\(_MeasureGroups\[MeasureName\]\) = "Distinct Bins With Inventory"')
) ""
$totalSkusOnHand = Get-Text $totalSkusOnHandPath
Add-Check "Daily KPI Total SKUs field name is spelled correctly" (
    $supervisorPatch -match "\[Total SKUs On Hand\]" -and
    $totalSkusOnHand -match "column 'Total SKUs On Hand'" -and
    $totalSkusOnHand -match "sourceColumn: Total SKUs On Hand" -and
    $bMeasure -match "Total_SKUs_On_Hand\[Total SKUs On Hand\]" -and
    $allPagesSmokeValidation -match "\[Total SKUs On Hand\]" -and
    $visibleMetricsValidation -match "\[Total SKUs On Hand\]" -and
    $supervisorPatch -notmatch "Totak SKUs On Hand" -and
    $totalSkusOnHand -notmatch "Totak SKUs On Hand" -and
    $bMeasure -notmatch "Totak SKUs On Hand" -and
    $allPagesSmokeValidation -notmatch "Totak SKUs On Hand" -and
    $visibleMetricsValidation -notmatch "Totak SKUs On Hand"
) ""
Add-Check "Daily KPI Total SKUs metadata has no stale typo" (
    $culture -match "ConceptualProperty`": `"Total SKUs On Hand" -and
    $culture -match "total_SK_us_on_hand\.total_SKUs_on_hand" -and
    $culture -notmatch "Totak SKUs On Hand" -and
    $culture -notmatch "totak_SKU_on_hand" -and
    $culture -notmatch "totak SKU on hand"
) ""
$dailyKpiMetricLabels = @(
    "Total SKUs On Hand",
    "Total Units On Hand",
    "Total Locations Occupied",
    "Orders Put Away",
    "Units Put Away",
    "SKUs Put Away",
    "Bin Presentations Put Away",
    "Distinct Bins With Inventory",
    "Distinct Bin Compartments With Inventory",
    "Customer Orders Picked",
    "Customer Order Lines",
    "Units Picked",
    "Distinct SKUs Picked"
)
$missingDailyKpiGroups = $dailyKpiMetricLabels | Where-Object { $measureGroups -notmatch [regex]::Escape("`"$_`"") }
$missingDailyKpiMappings = $dailyKpiMetricLabels | Where-Object { $bMeasure -notmatch [regex]::Escape("SELECTEDVALUE(_MeasureGroups[MeasureName]) = `"$_`"") }
Add-Check "Daily KPI dynamic measure maps every displayed metric row" (
    $missingDailyKpiGroups.Count -eq 0 -and
    $missingDailyKpiMappings.Count -eq 0
) ("Missing groups: $($missingDailyKpiGroups -join ', '); missing mappings: $($missingDailyKpiMappings -join ', ')")

$distinctUsers = Get-Text $distinctUsersPath
$distinctPorts = Get-Text $distinctPortsPath
Add-Check "User slicer dimension uses daily productivity table" ($distinctUsers -match "ProductivityDailyUserPortWorkType_v2") ""
Add-Check "Port slicer dimension uses daily productivity table" ($distinctPorts -match "ProductivityDailyUserPortWorkType_v2") ""

$throughput = Get-Text $throughputPath
$order = Get-Text $orderPath
Add-Check "Throughput port sort preserves labels" (($throughput -match "Added PortSortOrder") -and ($throughput -match "parsedPort") -and ($throughput -notmatch "Table\.ReplaceValue\(.*P-1")) ""
Add-Check "Order port sort preserves labels" (($order -match "Added PortSortOrder") -and ($order -match "parsedPort") -and ($order -notmatch "Table\.ReplaceValue\(.*P-1")) ""

$productivityPageRoot = Join-Path $reportRoot "definition\pages\9dedfc2d00346dac59c6"
$historicalPageRoot = Join-Path $reportRoot "definition\pages\2064d84d8522a437eb8d"
$throughputPageRoot = Join-Path $reportRoot "definition\pages\16bd7bc02aabba06407d"
$inventoryPageRoot = Join-Path $reportRoot "definition\pages\7a1652c454fa8d28a870"
$consolidationPageRoot = Join-Path $reportRoot "definition\pages\5f0e248099a51cbce489"
$consolidationVisualPath = Join-Path $reportRoot "definition\pages\5f0e248099a51cbce489\visuals\f371db997750ae3f16db\visual.json"
$openWorkChartPath = Join-Path $reportRoot "definition\pages\e390a00747581a892dea\visuals\0c3f0a90645a1d0b94d3\visual.json"
$throughputPortChartPath = Join-Path $throughputPageRoot "visuals\c918ad00079e75c6e550\visual.json"
$throughputCategoryChartPath = Join-Path $throughputPageRoot "visuals\d0581972d192308e904a\visual.json"
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
Add-Check "Current-state pages are not date-filtered" (
    (Test-PageTreeHasNoDateFilters -PageRoot $inventoryPageRoot) -and
    (Test-PageTreeHasNoDateFilters -PageRoot $consolidationPageRoot)
) "Inventory and Consolidation should show current source state without stale report date filters."

$historicalVisualDefaults = @(
    @{ Path = (Join-Path $historicalPageRoot "visuals\54bf7f01bc900a42ea63\visual.json"); Entity = "OrdersCompletedHD" },
    @{ Path = (Join-Path $historicalPageRoot "visuals\29dc9004b47532ab5d5a\visual.json"); Entity = "LinesCompletedHD" },
    @{ Path = (Join-Path $historicalPageRoot "visuals\e285ef599e332e8a0526\visual.json"); Entity = "UnitsPickedHD" },
    @{ Path = (Join-Path $historicalPageRoot "visuals\55bd987c0a5470063450\visual.json"); Entity = "BinPresentedHD" }
)
$missingHistoricalDefaults = @(
    $historicalVisualDefaults | Where-Object {
        -not (Test-VisualRelativeDateDefault -VisualPath $_.Path -Entity $_.Entity -Property "Date" -Days 30)
    } | ForEach-Object { $_.Entity }
)
Add-Check "Historical visuals default to trailing 30 days" ($missingHistoricalDefaults.Count -eq 0) (($missingHistoricalDefaults -join ", "))
Add-Check "Historical chart titles use consistent metric names" (
    (Test-FileContains -Path (Join-Path $historicalPageRoot "visuals\54bf7f01bc900a42ea63\visual.json") -Pattern "Orders Completed - Trailing 30 Days") -and
    (Test-FileContains -Path (Join-Path $historicalPageRoot "visuals\29dc9004b47532ab5d5a\visual.json") -Pattern "Lines Completed - Trailing 30 Days") -and
    (Test-FileContains -Path (Join-Path $historicalPageRoot "visuals\e285ef599e332e8a0526\visual.json") -Pattern "Units Picked - Trailing 30 Days") -and
    (Test-FileContains -Path (Join-Path $historicalPageRoot "visuals\55bd987c0a5470063450\visual.json") -Pattern "Bin Presentations Completed - Trailing 30 Days")
) $historicalPageRoot
Add-Check "Consolidation visual labels include units" (
    (Test-FileContains -Path $consolidationVisualPath -Pattern "Compartment Size") -and
    (Test-FileContains -Path $consolidationVisualPath -Pattern "Quantity \(units\)") -and
    (Test-FileContains -Path $consolidationVisualPath -Pattern "Total Compartments \(count\)") -and
    (Test-FileContains -Path $consolidationVisualPath -Pattern "Fragmentation \(%\)") -and
    ($aMeasure -match "measure Fragmentation[\s\S]*formatString:\s+0\.00%;-0\.00%;0\.00%")
) $consolidationVisualPath
Add-Check "Consolidation table includes storage context" (
    (Test-FileContains -Path $consolidationVisualPath -Pattern "DefragDetailByUomCompartmentSize_Table\.CompartmentSizeName") -and
    -not (Test-FileContains -Path $consolidationVisualPath -Pattern "Consolidation Report\\t")
) $consolidationVisualPath
Add-Check "Consolidation optional measures do not coerce missing values to zero" (
    $aMeasure -match "measure Fragmentation[\s\S]*ISBLANK\(UnrealizedCapacity\)[\s\S]*BLANK\(\)[\s\S]*DIVIDE\(UnrealizedCapacity, UnrealizedCapacity \+ Quantity\)" -and
    $aMeasure -match "measure 'Total Compartments' = SUM\(DefragDetailByUomCompartmentSize_Table\[TotalCompartments\]\)" -and
    $aMeasure -notmatch "measure 'Total Compartments' = SUM\(DefragDetailByUomCompartmentSize_Table\[TotalCompartments\]\)\+0"
) ""
Add-Check "Open Work chart title matches metric scope" (
    (Test-FileContains -Path $openWorkChartPath -Pattern "Open Work Over Time") -and
    -not (Test-FileContains -Path $openWorkChartPath -Pattern "Outstanding Lines Over Time")
) $openWorkChartPath
Add-Check "Open Work chart uses linear value axis" (
    ((Get-Text $openWorkChartPath) -match '(?s)"logAxisScale".{0,200}"Value": "false"')
) $openWorkChartPath
Add-Check "Throughput chart titles describe hourly totals not rates" (
    (Test-FileContains -Path $throughputPortChartPath -Pattern "Hourly Throughput by Port") -and
    (Test-FileContains -Path $throughputCategoryChartPath -Pattern "Hourly Throughput by Order Category") -and
    -not (Test-FileContains -Path $throughputPortChartPath -Pattern "Metrics Per Hour") -and
    -not (Test-FileContains -Path $throughputCategoryChartPath -Pattern "Metrics Per Hour")
) $throughputPageRoot

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
Add-Check "Productivity visuals filter blank and unattributed dimension rows" (
    (Test-FileContains -Path (Join-Path $productivityPageRoot "visuals\60144cc4ee55004dc503\visual.json") -Pattern "productivityUserNoBlankRows") -and
    (Test-FileContains -Path (Join-Path $productivityPageRoot "visuals\60144cc4ee55004dc503\visual.json") -Pattern "'Unattributed'") -and
    (Test-FileContains -Path (Join-Path $productivityPageRoot "visuals\60144cc4ee55004dc503\visual.json") -Pattern '"Value": "null"') -and
    (Test-FileContains -Path (Join-Path $productivityPageRoot "visuals\eaf9b8194b56ba1f624c\visual.json") -Pattern "'Unattributed'") -and
    (Test-FileContains -Path (Join-Path $productivityPageRoot "visuals\eaf9b8194b56ba1f624c\visual.json") -Pattern '"Value": "null"')
) $productivityPageRoot

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
    "Total_SKUs_On_Hand",
    "Total_Units_On_Hand",
    "Total_Locations_Occupied",
    "Distinct_bins_inventory_added",
    "Distinct_bin_compartments_that_had_inventory",
    "Orders_Putaway",
    "Units_Putaway",
    "Skus_Putaway",
    "Presentations_Putaway",
    "Throughput"
)
$missingViews = $expectedViews | Where-Object { $supervisorPatch -notmatch "CREATE OR ALTER VIEW \[dbo\]\.\[$_\]" }
Add-Check "Supervisor SQL patch defines all expected page views" ($missingViews.Count -eq 0) (($missingViews -join ", "))
Add-Check "Supervisor SQL patch dates putaway by source business date" (
    $supervisorPatch -match "CREATE OR ALTER VIEW \[dbo\]\.\[Orders_Putaway\]" -and
    $supervisorPatch -match "CREATE OR ALTER VIEW \[dbo\]\.\[Units_Putaway\]" -and
    $supervisorPatch -match "CREATE OR ALTER VIEW \[dbo\]\.\[Skus_Putaway\]" -and
    $supervisorPatch -match "CREATE OR ALTER VIEW \[dbo\]\.\[Presentations_Putaway\]" -and
    ([regex]::Matches($supervisorPatch, "LastUpdatedDateInventory").Count -ge 8)
) ""
Add-Check "Supervisor SQL patch standardizes positive on-hand inventory" (
    $supervisorPatch -match "CREATE OR ALTER VIEW \[dbo\]\.\[Total_SKUs_On_Hand\]" -and
    $supervisorPatch -match "CREATE OR ALTER VIEW \[dbo\]\.\[Distinct_bins_inventory_added\]" -and
    ([regex]::Matches($supervisorPatch, "c\.Snapshot_Id = i\.Snapshot_Id").Count -ge 5) -and
    ([regex]::Matches($supervisorPatch, "COALESCE\(i\.Quantity, 0\) > 0").Count -ge 5) -and
    ([regex]::Matches($supervisorPatch, "CAST\(GETDATE\(\) AS date\) AS \[Date\]").Count -ge 5) -and
    ([regex]::Matches($supervisorPatch, "i\.Snapshot_Id = \(SELECT MAX\(Snapshot_Id\) FROM dbo\.Inventory\)").Count -ge 5) -and
    ($supervisorPatch -notmatch "GROUP BY CAST\(i\.LastUpdatedDate AS date\)")
) ""
Add-Check "Supervisor SQL patch counts SKU metrics by product" (
    $supervisorPatch -match "COUNT\(DISTINCT COALESCE\(uom\.ProductPrimaryKey, i\.UnitOfMeasurePrimaryKey\)\)" -and
    $supervisorPatch -match "COUNT\(DISTINCT COALESCE\(uom\.ProductPrimaryKey, pacli\.UnitOfMeasurePrimaryKey\)\)" -and
    ([regex]::Matches($supervisorPatch, "LEFT JOIN dbo\.UnitsOfMeasure uom").Count -ge 2)
) ""
Add-Check "Supervisor SQL patch rebuilds inventory summary from latest snapshots" (
    $supervisorPatch -match "CREATE OR ALTER PROCEDURE \[dbo\]\.\[InventoryAndLocationSummaryData\]" -and
    $supervisorPatch -match "MAX\(Snapshot_Id\)" -and
    $supervisorPatch -match "EXEC dbo\.InventoryAndLocationSummaryData"
) ""
Add-Check "Supervisor SQL patch summarizes inventory by compartment coordinates" (
    $supervisorPatch -match "ContainerCompartments AS" -and
    $supervisorPatch -match "i\.ContainerX = cc\.XPosition" -and
    $supervisorPatch -match "i\.ContainerY = cc\.YPosition" -and
    $supervisorPatch -match "i\.ContainerSide = cc\.ContainerSide" -and
    $supervisorPatch -match "GROUP BY CompartmentLabel"
) ""
Add-Check "Supervisor SQL patch gives percent of total bins a distribution denominator" (
    $supervisorPatch -match "TotalCapacity AS" -and
    $supervisorPatch -match "AllDisplayedBins" -and
    $supervisorPatch -match "% of Total Bin\(s\).*mb\.TotalBins \* 100\.0 / mb\.AllDisplayedBins"
) ""
Add-Check "Supervisor SQL patch uses readable throughput fallback labels" (
    $supervisorPatch -match "LTRIM\(RTRIM\(e\.Port\)\)" -and
    $supervisorPatch -match "THEN 'Unattributed'" -and
    $supervisorPatch -match "UPPER\(LTRIM\(RTRIM\(category_match\.OrderCategory\)\)\) IN \('NO VALUE', 'UNKNOWN'\)" -and
    $supervisorPatch -match "THEN 'Uncategorized'"
) ""

$supervisorValidation = Get-Text $supervisorValidationPath
Add-Check "Supervisor SQL validation has gate" ($supervisorValidation -match "SupervisorPageValidationGate") ""
Add-Check "Supervisor SQL validation checks Daily KPI picking" ($supervisorValidation -match "Daily KPI picked orders" -and $supervisorValidation -match "Daily KPI distinct SKUs") ""
Add-Check "Supervisor SQL validation rejects raw throughput placeholders" (
    $supervisorValidation -match "Throughput has no blank or raw placeholder report fields" -and
    $supervisorValidation -match "Ports = 'No Data'" -and
    $supervisorValidation -match "OrderCategory IN \('NO VALUE', 'Unknown'\)" -and
    $supervisorValidation -match "Throughput placeholder rows"
) ""

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
Add-Check "All-pages smoke rejects raw throughput placeholders" (
    $allPagesSmokeValidation -match "Ports = 'No Data'" -and
    $allPagesSmokeValidation -match "OrderCategory IN \('NO VALUE', 'Unknown'\)"
) ""
Add-Check "All-pages smoke checks complete Inventory matrix metric set" (
    $allPagesSmokeValidation -match "ExpectedInventoryMetrics" -and
    $allPagesSmokeValidation -match "MetricCount <> 18" -and
    $allPagesSmokeValidation -match "MissingMetricInstances" -and
    $allPagesSmokeValidation -match "DuplicateMetricRows" -and
    $allPagesSmokeValidation -match "UnexpectedMetricRows"
) ""
Add-Check "All-pages smoke names missing Daily KPI sources" (
    $allPagesSmokeValidation -match "ExpectedDailyKpiSources" -and
    $allPagesSmokeValidation -match "MissingSources" -and
    $allPagesSmokeValidation -match "missing sources:"
) ""
Add-Check "All-pages smoke explains zero-activity Productivity rows" (
    $allPagesSmokeValidation -match "ProductivityActivityBasis" -and
    $allPagesSmokeValidation -match "RecentActivityRows" -and
    $allPagesSmokeValidation -match "ZeroActivityRows" -and
    $allPagesSmokeValidation -match "zero-activity rows hidden by PBIX measures"
) ""
Add-Check "All-pages smoke brackets RowCount alias for SQL Server" (
    $allPagesSmokeValidation -match "COUNT_BIG\(\*\) AS \[RowCount\]" -and
    $allPagesSmokeValidation -match "counts\.\[RowCount\]"
) ""

$visibleMetricsValidation = Get-Text $visibleMetricsValidationPath
Add-Check "Visible-metrics SQL validation exists" (Test-Path -LiteralPath $visibleMetricsValidationPath) $visibleMetricsValidationPath
Add-Check "Visible-metrics SQL validation has gate" ($visibleMetricsValidation -match "VisibleMetricsValidationGate") ""
Add-Check "Visible-metrics SQL validation covers all report pages" (($requiredSmokePages | Where-Object { $visibleMetricsValidation -notmatch [regex]::Escape($_) }).Count -eq 0) ""
$missingVisibleDailyKpiMetrics = $dailyKpiMetricLabels | Where-Object { $visibleMetricsValidation -notmatch [regex]::Escape("'$_'") }
Add-Check "Visible-metrics SQL validation covers every Daily KPI row" ($missingVisibleDailyKpiMetrics.Count -eq 0) (($missingVisibleDailyKpiMetrics -join ", "))
$visibleProductivityMetrics = @(
    "Orders Completed",
    "Bin Presentations Completed",
    "Lines Completed",
    "Units Completed",
    "Orders/hr",
    "Bins/hr",
    "Units/hr",
    "Lines/hr",
    "Machine Wait Minutes",
    "Average Handle Minutes/Presentation",
    "Total Logged Minutes",
    "Rate Denominator Hours"
)
$missingVisibleProductivityMetrics = $visibleProductivityMetrics | Where-Object { $visibleMetricsValidation -notmatch [regex]::Escape("'$_'") }
Add-Check "Visible-metrics SQL validation covers every Productivity metric" (
    $missingVisibleProductivityMetrics.Count -eq 0 -and
    $visibleMetricsValidation -match "RequirePositiveWhenSourcePositive" -and
    $visibleMetricsValidation -match "RateDenominatorHours"
) (($missingVisibleProductivityMetrics -join ", "))
Add-Check "Visible-metrics SQL validation compares only displayable Productivity rows" (
    $visibleMetricsValidation -match "ProductivePickRows" -and
    $visibleMetricsValidation -match "ProductivityActivityBasis" -and
    $visibleMetricsValidation -match "WHERE d\.ProductivityActivityBasis > 0" -and
    $visibleMetricsValidation -match "zero-activity rows are hidden by PBIX measures"
) ""
Add-Check "Visible-metrics SQL validation returns actionable diagnostics" (
    $visibleMetricsValidation -match "SourceRows" -and
    $visibleMetricsValidation -match "ReportRows" -and
    $visibleMetricsValidation -match "SourceValue" -and
    $visibleMetricsValidation -match "ReportValue" -and
    $visibleMetricsValidation -match "SourceMinDate" -and
    $visibleMetricsValidation -match "SourceMaxDate" -and
    $visibleMetricsValidation -match "ReportMinDate" -and
    $visibleMetricsValidation -match "ReportMaxDate" -and
    $visibleMetricsValidation -match "Details"
) ""
Add-Check "Visible-metrics SQL validation checks complete Inventory matrix metric set" (
    $visibleMetricsValidation -match "ExpectedInventoryMetrics" -and
    $visibleMetricsValidation -match "MissingMetricInstances" -and
    $visibleMetricsValidation -match "DuplicateMetricRows" -and
    $visibleMetricsValidation -match "UnexpectedRows"
) ""
Add-Check "Visible-metrics Inventory validation uses displayed template label grain" (
    $visibleMetricsValidation -match "COUNT\(DISTINCT CompartmentLabel\) FROM TemplateCompartments" -and
    $visibleMetricsValidation -match "FROM \(SELECT DISTINCT CompartmentLabel FROM TemplateCompartments\) labels"
) ""
Add-Check "Visible-metrics SQL brackets RowCount alias for SQL Server" (
    $visibleMetricsValidation -match "COUNT_BIG\(\*\) AS \[RowCount\]" -and
    $visibleMetricsValidation -match "agg\.\[RowCount\]"
) ""
Add-Check "All-pages smoke SQL validation returns actionable diagnostics" (
    $allPagesSmokeValidation -match "\[RowCount\]" -and
    $allPagesSmokeValidation -match "MinDate" -and
    $allPagesSmokeValidation -match "MaxDate" -and
    $allPagesSmokeValidation -match "IssueCount" -and
    $allPagesSmokeValidation -match "Details"
) ""
Add-Check "SQL validation checks Consolidation fragmentation quality" (
    $visibleMetricsValidation -match "BadFragmentationDenominatorRows" -and
    $visibleMetricsValidation -match "BadFragmentationRows" -and
    $visibleMetricsValidation -match "NegativeValueRows" -and
    $visibleMetricsValidation -match "MissingDisplayRows" -and
    $visibleMetricsValidation -match "MissingOptionalMetricRows" -and
    $allPagesSmokeValidation -match "BadFragmentationDenominatorRows" -and
    $allPagesSmokeValidation -match "BadFragmentationRows" -and
    $allPagesSmokeValidation -match "NegativeValueRows" -and
    $allPagesSmokeValidation -match "MissingDisplayRows" -and
    $allPagesSmokeValidation -match "MissingOptionalMetricRows"
) ""
Add-Check "Supervisor SQL patch refreshes Consolidation from AutoStore source" (
    $supervisorPatch -match "DefragDetailByUomCompartmentSizeView" -and
    $supervisorPatch -match "TRUNCATE TABLE dbo\.DefragDetailByUomCompartmentSize_Table" -and
    $supervisorPatch -match "INSERT INTO dbo\.DefragDetailByUomCompartmentSize_Table"
) ""
Add-Check "SQL validation compares Consolidation source and report rows" (
    $visibleMetricsValidation -match "KFX_AUTOSTORE\.dbo\.DefragDetailByUomCompartmentSizeView" -and
    $visibleMetricsValidation -match "@ConsolidationSourceRows > 0 AND ReportRows = 0" -and
    $visibleMetricsValidation -notmatch "@ConsolidationSourceRows > 0 AND ReportRows <> @ConsolidationSourceRows.*THEN 'FAIL'" -and
    $allPagesSmokeValidation -match "KFX_AUTOSTORE\.dbo\.DefragDetailByUomCompartmentSizeView" -and
    $allPagesSmokeValidation -match "@ConsolidationSourceRows > 0 AND ReportRows = 0" -and
    $allPagesSmokeValidation -notmatch "@ConsolidationSourceRows > 0 AND ReportRows <> @ConsolidationSourceRows.*THEN 'FAIL'"
) ""

$runnerSqlScriptNames = @(
    "create-reporting-productivity-work-events-v4.5.0.sql",
    "patch-reporting-productivity-views-v4.5.0.sql",
    "patch-reporting-supervisor-page-views-v4.5.0.sql",
    "validate-reporting-productivity-powerbi-patch-v4.5.0.sql",
    "validate-reporting-supervisor-page-views-v4.5.0.sql",
    "validate-reporting-all-pages-smoke-v4.5.0.sql",
    "validate-reporting-visible-metrics-v4.5.0.sql"
)
$missingRequiredSetOptions = @(
    $runnerSqlScriptNames | Where-Object {
        -not (Test-SqlFileHasRequiredSetOptions -Path (Join-Path $assetsRoot $_))
    }
)
Add-Check "Runner SQL scripts set required indexed-view options" (
    $missingRequiredSetOptions.Count -eq 0
) (($missingRequiredSetOptions -join ", "))

$runnerText = Get-Text $runnerPath
Add-Check "Runner includes all-pages smoke validation" ($runnerText -match "validate-reporting-all-pages-smoke-v4\.5\.0\.sql") ""
Add-Check "Runner includes visible-metrics validation" ($runnerText -match "validate-reporting-visible-metrics-v4\.5\.0\.sql") ""
Add-Check "Runner supports validation-only mode" ($runnerText -match '\[switch\]\$ValidateOnly' -and $runnerText -match '\$validationScripts') ""
Add-Check "Runner enforces SQL validation gates" (
    $runnerText -match "PowerBIPatchValidationGate" -and
    $runnerText -match "SupervisorPageValidationGate" -and
    $runnerText -match "AllPagesSmokeGate" -and
    $runnerText -match "VisibleMetricsValidationGate" -and
    $runnerText -match 'Expected \$expectedGate = PASS'
) ""
Add-Check "Runner reports failed SQL gate diagnostics" (
    $runnerText -match "Get-SqlGateFailureMessage" -and
    $runnerText -match "Gate summary:" -and
    $runnerText -match "First FAIL row" -and
    $runnerText -match "\\bFAIL\\b"
) ""
Add-Check "Runner tells user which PBIX to save after opening PBIP" (
    $runnerText -match "Kardex PowerBI 2\.0 Beta\.pbix" -and
    $runnerText -match "refresh the report and save as/over"
) ""
Add-Check "Runner warns OpenPbip alone does not apply SQL patches" (
    $runnerText -match "Opening PBIP without applying SQL patches" -and
    $runnerText -match "Use -Apply -OpenPbip" -and
    $runnerText -match "Confirm SQL patch/validation has run"
) ""
Add-Check "Runner supports optional run logging" (
    $runnerText -match '\[string\]\$LogPath' -and
    $runnerText -match "Initialize-RunLog" -and
    $runnerText -match "Write-RunLine" -and
    $runnerText -match "Logging run output to:"
) ""

try {
    [scriptblock]::Create($runnerText) | Out-Null
    Add-Check "Runner script parses" $true $runnerPath
} catch {
    Add-Check "Runner script parses" $false $_.Exception.Message
}

$readmeText = Get-Text $readmePath
Add-Check "README exists" (Test-Path -LiteralPath $readmePath) $readmePath
Add-Check "README points to replacement PBIP and final PBIX" (
    $readmeText -match "Kardex PowerBI 2\.0 Beta\.pbip" -and
    $readmeText -match "Kardex PowerBI 2\.0 Beta\.pbix"
) ""
Add-Check "README documents runner setup and validation gates" (
    $readmeText -match "run-reporting-supervisor-rework\.ps1" -and
    $readmeText -match "-Apply" -and
    $readmeText -match "-OpenPbip" -and
    $readmeText -match "-ValidateOnly" -and
    $readmeText -match "PowerBIPatchValidationGate" -and
    $readmeText -match "SupervisorPageValidationGate" -and
    $readmeText -match "AllPagesSmokeGate" -and
    $readmeText -match "VisibleMetricsValidationGate"
) ""
Add-Check "README documents final PBIX freshness check" (
    $readmeText -match "validate-reporting-pbip-static\.ps1 -RequireCurrentPbix"
) ""
Add-Check "README warns OpenPbip alone does not apply SQL patches" (
    $readmeText -match '`-OpenPbip` by itself does not apply SQL patches' -and
    $readmeText -match '`-Apply -OpenPbip`'
) ""
Add-Check "README separates rework path from fresh install path" (
    $readmeText -match "Recommended Setup" -and
    $readmeText -match "Fresh Reporting Install Only" -and
    $readmeText -match "create-reporting-database-4\.5\.0\.sql" -and
    $readmeText -match "SQL Server Agent"
) ""

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -eq "FAIL" })
if ($failed.Count -gt 0) {
    Write-Error "Static PBIP validation failed: $($failed.Count) check(s)."
    exit 1
}

Write-Host ""
$warnings = @($checks | Where-Object { $_.Status -eq "WARN" })
if ($warnings.Count -gt 0) {
    Write-Host "Static PBIP validation passed with $($warnings.Count) warning(s)."
} else {
    Write-Host "Static PBIP validation passed."
}
