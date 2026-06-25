# Power BI Reporting Analysis Agent

Use this as the starter brief for an agent that analyzes the Kardex Power BI reporting project, traces incorrect dashboard values back to SQL, and produces evidence-based troubleshooting notes.

## Agent Mission

You are analyzing a Power BI reporting project made from:

- `04 Assets - Reporting/Kardex-v4.5.0.pbix`
- `04 Assets - Reporting/create-reporting-database-4.5.0.sql`
- `04 Assets - Reporting/create-reporting-sync-job-v.4.5.0.sql`
- `04 Assets - Reporting/create-reporting-snapshot-sync-job-v4.5.0.sql`
- `04 Assets - Reporting/create-reporting-cleanup-job-v4.5.0.sql`
- `04 Assets - Reporting/04 Reporting for KFX v4.6.0.docx`
- `04 Assets - Reporting/Kardex-v4.5.0_out.pbip`
- `04 Assets - Reporting/Kardex-v4.5.0_out.Report/`
- `04 Assets - Reporting/Kardex-v4.5.0_out.SemanticModel/`
- `04 Assets - Reporting/create-reporting-productivity-work-events-v4.5.0.sql`
- `04 Assets - Reporting/diagnose-reporting-productivity-sources-v4.5.0.sql`
- `04 Assets - Reporting/create-reporting-productivity-source-grain-v4.5.0.sql`
- `04 Assets - Reporting/validate-reporting-productivity-source-grain-v4.5.0.sql`
- `04 Assets - Reporting/validate-reporting-productivity-v4.5.0.sql`
- `04 Assets - Reporting/patch-reporting-productivity-views-v4.5.0.sql`
- `04 Assets - Reporting/validate-reporting-productivity-powerbi-patch-v4.5.0.sql`
- `04 Assets - Reporting/trace-reporting-productivity-events-v4.5.0.sql`
- `04 Assets - Reporting/run-reporting-productivity-rework.ps1`
- `04 Assets - Reporting/switch-powerbi-sql-source.ps1`
- `04 Assets - Reporting/rollback-reporting-productivity-views-v4.5.0.sql`
- `04 Assets - Reporting/Kardex-v4.5.0_out.SemanticModel/definition/tables/ProductivityDailyUserPortWorkType_v2.tmdl`
- `PRODUCTIVITY_METRICS_REWORK.md`

Your job is to answer, for each incorrect dashboard:

1. Which page, visual, measure, field, SQL view, and stored procedure feeds the value?
2. Is the data stale, missing, duplicated, filtered to the wrong date, or calculated incorrectly?
3. What exact SQL query proves the issue?
4. What is the smallest safe fix or next investigation step?

Do not change SQL, PBIX, or production data until the issue is proven with a read-only diagnostic query.

## Current Project Map

The usage document describes the intended reporting deployment for KFX v4.6.0. The local SQL and PBIX assets currently inspected are v4.5.0, so the agent must explicitly check for version drift before assuming a schedule, script name, PBIX model, or published dataset matches the documentation.

The PBIP export exposes the report definition and semantic model directly:

- report pages and visuals live under `Kardex-v4.5.0_out.Report/definition`
- tables, Power Query M, DAX measures, calculated tables, and relationships live under `Kardex-v4.5.0_out.SemanticModel/definition`
- the model is import mode and points imported SQL tables at `Sql.Database("10.0.26.70", "KFX_REPORTING")`
- the model has Power BI time intelligence enabled and many generated `LocalDateTable_*` tables
- key DAX measure tables are `A Measure.tmdl` and `B Measure.tmdl`

The usage document adds these operational assumptions:

- reporting is deployed to a separate `KFX_REPORTING` database on the same SQL Server as FulfillX source databases
- SQL Server Agent must be running and set to automatic start, or reporting sync will not work
- Power BI uses a SQL Server connection to `KFX_REPORTING`, typically through a custom read-only reporting account
- published Power BI reports may depend on an on-premises data gateway and a separate dataset refresh schedule
- excessive reporting, frequent gateway refreshes, or broad custom SQL can affect FulfillX production performance because the reporting database is on the same SQL Server
- Power BI Desktop imports and scores data locally during refresh, so Desktop values may lag SQL until refreshed

The PBIX report layout contains seven pages:

| Page | Main visual types | Main fields found in PBIX layout |
| --- | --- | --- |
| Daily KPI Summary Report | pivot table, date slicer | `_MeasureGroups`, `B Measure._DynamicMeasure`, `Calendar_1.DateOnly` |
| Inventory & Location Table Summary | pivot table | `InventoryAndLocationSummary.MetricName`, `CompartmentLabel`, `MetricValue` |
| Productivity by User / Port | two tables, user/port slicers | `B Measure.* per User`, `B Measure.* per Port`, `DistinctUsersTable.Users`, `DistinctPortsTable.Ports` |
| Throughput | column charts, slicers | `Throughput.Date`, `Hour`, `Ports`, `OrderCategory`, `A Measure.KPI_Selected` |
| Open Work History | line chart, date/metric slicers | `A Measure.KPI_Selected_OWH`, `Calender.DateOnly`, `KPI_Series.Series`, `MetricsSlicer OWH.Metric` |
| Historical Dashboard | line charts | `BinPresentedHD`, `LinesCompletedHD`, `OrdersCompletedHD`, `UnitsPickedHD` |
| Consolidation Report | table, SKU slicer | `DefragDetailByUomCompartmentSize_Table.Sku`, `A Measure.Fragmentation`, `A Measure.Total Compartments` |

The PBIP semantic model clarifies the dynamic measure paths:

- Daily KPI Summary Report uses `B Measure._DynamicMeasure`, which switches on `_MeasureGroups[MeasureName]` and delegates to measures like `Total SKUs On Hand`, `Customer Orders Picked`, `Units Picked`, and `Distinct SKUs Picked`
- Throughput uses `A Measure.KPI_Selected`, which switches on `MetricsSlicer[Metric]` and returns `Orders`, `Lines`, `Bins`, or `All_Orders+Lines+Bins`
- Open Work History uses `A Measure.KPI_Selected_OWH`, which switches on `MetricsSlicer OWH[Metric]` and `KPI_Series[Series]`
- Productivity tables mostly use simple `SUM(...) + 0` measures over SQL helper views/tables such as `OrdersCompletedPerUser`, `LinesCompletedPerPort`, and `TotalLoggedTimePerUser`
- Consolidation uses `A Measure.Fragmentation` and `A Measure.Total Compartments` over `DefragDetailByUomCompartmentSize_Table`

The Productivity by User / Port page is suspect because the existing helper tables mix grains and denominators. A companion script, `create-reporting-productivity-work-events-v4.5.0.sql`, defines additive candidate views:

- `dbo.v_ProductivityWorkEvents`: one canonical event stream with user, port, start/end time, duration, machine wait, and order/bin/line/unit flags
- `dbo.v_ProductivityByUser_New`: new user-level aggregates from that event stream
- `dbo.v_ProductivityByPort_New`: new port-level aggregates from that event stream
- `dbo.v_ProductivityComparison_User`: old helper-table results beside the new user aggregate
- `dbo.v_ProductivityComparison_Port`: old helper-table results beside the new port aggregate
- `dbo.v_ProductivityWorkEvents_v2`: second-generation event stream with explicit `WorkType`, paired session rows, `RateDenominatorSeconds`, `HandleSeconds`, `MachineWaitSeconds`, and order/bin/line/unit flags. It intentionally uses reported-metric parsed tables only and does not supplement order counts from `FulfillmentOrderStatusHistory`.
- `dbo.v_ProductivityByUserWorkType_v2` and `dbo.v_ProductivityByPortWorkType_v2`: work-type level aggregates for Pick, PutAway, CycleCount, OnDemand, etc.
- `dbo.v_ProductivityByUser_v2` and `dbo.v_ProductivityByPort_v2`: all-work-type rollups from the same v2 event stream
- `dbo.v_ProductivityDailyUserPortWorkType_v2`: report-friendly daily aggregate by date, work type, user, and port from the same v2 event stream
- `dbo.v_ProductivityCurrentFeedReadiness_v2`: one-row readiness check showing whether the current reporting feed has Pick, Order, BinPresented, and paired session rows
- `dbo.v_ProductivityValidation_v2`: raw-vs-event reconciliation checks for bins, pick lines, pick units, order rows, and paired session seconds

Use the v2 views to validate the new grain before replacing PBIX fields or changing shipped KPI tables. The first-pass views remain useful for comparison, but the v2 views are now the preferred candidate because they make the denominator explicit and do not silently drop PutAway/CycleCount/OnDemand bin presentations.

Run `diagnose-reporting-productivity-sources-v4.5.0.sql` when source coverage is unclear. The current environment has telemetry split across live, old archive, and archive-new tables, and primary keys are not comparable across all sources.

Use `create-reporting-productivity-source-grain-v4.5.0.sql` for source-aware history analysis. It unions the known live/archive reported metric sources while preserving `(SourceDatabase, SourceTable, SourcePrimaryKey)` and de-duplicating by event content. Do not insert a naive live/archive union into `dbo.Report_Data`; that table keys only on `PrimaryKey`, and source primary keys overlap.

After validation, `patch-reporting-productivity-views-v4.5.0.sql` can be used as an optional drop-in SQL promotion path. It redefines the existing report-facing helper views, such as `OrdersCompletedPerUser`, `BinsPerHourPerPort`, and `TotalLoggedTimePerUser`, to select from the v2 event stream. It intentionally filters those compatibility views to `WorkType = 'Pick'` because the current PBIX page has no work-type column; non-pick work should be analyzed through `v_ProductivityByUserWorkType_v2` and `v_ProductivityByPortWorkType_v2` or a revised PBIX page that exposes `WorkType`.

After the patch, run `validate-reporting-productivity-powerbi-patch-v4.5.0.sql`. It should return `PowerBIPatchValidationGate = PASS`; this verifies the PBIX-imported helper views reconcile to the v2 Pick aggregate by total and by visible user/port row before Power BI Desktop refresh is trusted.

The PBIP semantic model also imports `dbo.v_ProductivityDailyUserPortWorkType_v2` as `ProductivityDailyUserPortWorkType_v2`. Use this table as the preferred source for any redesigned Productivity page because it preserves `EventDate`, `WorkType`, `Users`, `Ports`, counts, rates, timing, and diagnostic event counts in one aggregate.

Use `trace-reporting-productivity-events-v4.5.0.sql` when a report row needs proof. It filters the v2 aggregate and then lists the underlying `v_ProductivityWorkEvents_v2` rows, including event type, source table name, source primary key, attribution method, timing, and metric flags.

`run-reporting-productivity-rework.ps1` is an optional local runner for repeatable validation. Without `-ApplyPatch`, it runs only setup and validation; with `-ApplyPatch`, it applies the compatibility view patch after `DropInPatchPromotionGate = PASS` and then checks `PowerBIPatchValidationGate`.

If Power BI Desktop refresh fails with `The target principal name is incorrect. Cannot generate SSPI context`, treat it as a SQL authentication/SPN connection issue first. The extracted PBIP model hard-codes `Sql.Database("10.0.26.70", "KFX_REPORTING")`, while SSMS validation used `vm-as-dbsql0011`. Change the Desktop data source to `vm-as-dbsql0011` or close Desktop and run `switch-powerbi-sql-source.ps1` for the PBIP export.

If the promoted views do not validate in Power BI, `rollback-reporting-productivity-views-v4.5.0.sql` restores the original table-backed view definitions.

Current live diagnostics from June 23, 2026 changed the priority for the Productivity by User / Port investigation:

- Confirmed at 2026-06-23 16:44 ET: `KFX_AUTOSTORE.dbo.ReportedMetrics` has `SourceRows = 0`, with null primary-key and timestamp bounds.
- Updated at 2026-06-24 11:44 ET: `KFX_AUTOSTORE.dbo.ReportedMetrics` now has at least 15 rows. The sample rows have primary keys 132880-132894 and timestamps around 2026-06-24 07:28-07:29. The sample includes `PutAway`, `PutAway-SignIn`, `PutAway-SignOut`, `BinPresented`, `OpenBin`, `CloseBin`, `CloseBin-InventoryRecord`, `CycleCountService`, `CycleCount-SignIn`, and `CycleCount-SignOut`.
- Confirmed at 2026-06-24 11:47 ET: the 10:00 reporting sync loaded the 15 live rows into `dbo.Report_Data` with `DataSyncDetail.StartPrimaryKey = 132880`, `EndPrimaryKey = 132894`, `TotalRecordSource = 15`, and `TotalRecordSynced = 15`.
- Confirmed at 2026-06-24 11:47 ET: parsed reporting tables contain the expected current rows: `BinPresented` 2, `CloseBin` 2, `OpenBin` 3, `PutAway` 2, `CycleCountService` 1, and `Pick` 0.
- Confirmed at 2026-06-24 16:29 ET: `KFX_AUTOSTORE_ARCHIVE_NEW.dbo.ArchiveReportedMetrics` contains historical event telemetry through 2026-06-18 14:17:49.753. It includes `Pick` 178 rows through 2026-06-18 13:16:27.670, `Order` 196 rows through 2026-06-18 13:16:27.683, `Pick-SignIn` 128 rows through 2026-06-17 11:08:44.953, and `Pick-SignOut` 79 rows through 2026-06-17 11:11:14.720.
- Validation at 2026-06-24 16:30 ET showed `v_ProductivityValidation_v2` raw/event checks matched, but `v_ProductivityByUserWorkType_v2` over-counted Pick orders because the v2 event stream was supplementing reported `Order` events with `FulfillmentOrderStatusHistory` fallback rows. That fallback violated the single reported-metric grain and was removed from `v_ProductivityWorkEvents_v2`.
- Validation at 2026-06-24 16:37 ET passed the drop-in promotion gate after the fallback removal: `FailedValidationChecks = 0`, `HasPickRows = 1`, `HasOrderRows = 1`, `HasBinPresentedRows = 1`, `HasPairedWorkSessions = 1`, `PickAggregateRows = 1`, `PickRowsWithSessionDenominator = 1`, and `PickRowsWithoutSessionDenominator = 0`. Pick user/port metrics now show 2 orders, 3 bin presentations, 2 lines, 2 units, and session-based rates for admin/P4. The validation script failed only when querying `v_ProductivityDailyUserPortWorkType_v2`, which means the latest setup script containing that new report-friendly aggregate had not been run on SQL Server yet.
- Confirmed at 2026-06-23 16:46 ET: `KFX_AUTOSTORE_ARCHIVE.dbo.ReportedMetrics` has 132,402 rows, primary keys 1-132402, and timestamps from 2025-12-22 13:34:42.967 through 2026-06-15 14:42:34.007.
- Confirmed at 2026-06-23 16:49 ET: `KFX_AUTOSTORE_ARCHIVE_NEW` contains `dbo.ArchiveReportedMetrics`, not `dbo.ReportedMetrics`. The local v4.5.0 reporting scripts do not reference `ArchiveReportedMetrics`.
- Confirmed at 2026-06-23 16:49 ET: `KFX_OLD_ARCHIVE.dbo.ReportedMetrics` exists but has 0 rows.
- `dbo.Report_Data` returned 0 rows by `DataDescription`, so the reporting database currently has no raw reported-metric events.
- `dbo.Pick`, `dbo.BinPresented`, `dbo.CloseBin`, `dbo.[Pick-SignIn]`, and `dbo.[Pick-SignOut]` were previously observed empty.
- `dbo.DataSyncDetail` shows `ReportedMetrics` syncs completing successfully, but with `TotalRecordSource = 0` and `TotalRecordSynced = 0`.
- Other source tables, such as `TaskCategories`, `ContainerCompartmentBarcodes`, `ContainerTemplateCompartments`, and `InventoryTaskActions`, are syncing rows, so this is not a blanket SQL Agent failure.
- The shipped `reporting-sync-job` runs `EXEC ProcessData;`, and local `ProcessData` calls `ProcessData_ReportedMetrics_LIVE`, even though the script also defines `ProcessData_ReportedMetrics_ARCHIVE`.
- `ResetReportedMatricsData` truncates event tables and deletes `DataSyncDetail` rows for `ReportedMetrics` and related event tables before each `ProcessData` run. This means each reporting sync rebuilds event tables from whatever is currently in the live `ReportedMetrics` source, not from durable history.
- The current event-grain rewrite can only produce completed-order rows from fulfillment status history; it cannot produce bins, lines, units, durations, machine wait, or port attribution until `ReportedMetrics` data is present.

Treat this as a time-varying live/archive source mismatch and possible version drift first, not a Power BI visual issue. The current evidence says historical productivity telemetry exists in archive, a newer archive database uses a renamed table, and the scheduled reporting path reads the live table, which was empty on 2026-06-23 but had a small number of new rows on 2026-06-24. Because the current live batch has no `Pick` rows, the Productivity by User / Port page still cannot produce reliable pick/order/line/unit metrics from live event telemetry. If Power BI Desktop shows productivity values that do not line up with SQL event rows, assume the PBIX contains imported stale data, stale helper tables, or a different source connection until proven otherwise.

The SQL build creates:

- snapshot tables and latest-by-day views, for example `Inventory_Snapshot` to `Inventory`
- event tables from reported metrics JSON, for example `Pick`, `BinPresented`, `CloseBin`
- KPI helper tables rebuilt by `CreateKPITables`
- report-facing views including `Throughput`, `InventoryAndLocationSummary`, `BinPresentedHD`, `LinesCompletedHD`, `OrdersCompletedHD`, and `UnitsPickedHD`

The SQL Agent jobs are:

| Job | Schedule from local v4.5.0 SQL | Schedule expected by v4.6.0 usage doc | Main procedure |
| --- | --- | --- | --- |
| `reporting-sync-job` | every 2 minutes | every 1 hour | `ProcessData`, then `ProcessDataCompletion` |
| `reporting-snapshot-sync-job` | every 1 hour | every 1 hour | `ProcessDynamicData`, then `ProcessDataDynamicCompletion` |
| `reporting-data-cleanup-job` | every 12 hours | every 12 hours | `DeleteDynamicData`, then `DeleteDynamicDataCompletion` |

Always verify the installed job schedule in `msdb`; do not rely only on either the script or the usage document.

## First Red Flags To Verify

These are not final conclusions. They are high-value starting hypotheses.

1. `ProcessDataDynamicCompletion` checks `JobName = 'DyanamicTableInsert'`, but `ProcessDynamicData` writes `JobName = 'DynamicTableInsert'`. The misspelling can make stuck dynamic sync recovery fail.
2. `DeleteDynamicData` deletes `PutAwayContainers_Snapshot` twice. The second delete appears intended for `PutAwayContainerLineItems_Snapshot`.
3. `ProcessData` and `ProcessDynamicData` catch errors, print error info, and still mark the outer sync complete. A SQL Agent job may look successful while one or more child table loads failed.
4. `CreateKPITables` rebuilds KPI tables with `DROP TABLE` and `SELECT INTO`. That can create refresh timing issues and dependency breaks, especially while Power BI is reading.
5. Several productivity KPI tables are filtered to `CAST(GETDATE() AS DATE)`, so they may only represent today's data even when the report user expects a broader period.
6. The PBIX layout references both `Calendar_1.DateOnly` and `Calender.DateOnly`. If relationships or slicers point to the wrong calendar table, visuals may not filter consistently.
7. `OrdersCompletedHD` is shown on the Historical Dashboard but filters `fosh.LastUpdatedDate` to `GETDATE()`, which may make a historical chart appear incomplete.
8. The v4.6.0 usage document and v4.5.0 local SQL disagree on the `reporting-sync-job` schedule. If a customer expects hourly sync but the installed job runs every 2 minutes, performance and refresh behavior may differ; if they expect near-real-time data but the installed job runs hourly, dashboards may look stale.
9. Published reports add another refresh layer. A healthy SQL sync does not guarantee a healthy Power BI Service dataset refresh, gateway configuration, or Desktop refresh.
10. The PBIP semantic model points to `10.0.26.70` and `KFX_REPORTING`. If Power BI Desktop or Service is using that source while SQL diagnostics are run against another server, results will not line up.
11. `Calendar_1` and `Calender` are separate calculated calendar tables with similar definitions. Daily KPI uses `Calendar_1`; Open Work History and Throughput use `Calender`. Date slicer issues should be traced through the exact calendar table used by the page.
12. There are many bidirectional relationships. Duplicate or unexpected filtering can come from the model relationship layer, not only from SQL joins.

## Read-Only Diagnostic Query Pack

Run these against `KFX_REPORTING` first.

### Sync Health

```sql
SELECT TOP (100)
    Id,
    JobName,
    DatabaseName,
    TableName,
    BatchId,
    SyncStartTime,
    SyncEndTime,
    IsStarted,
    IsCompleted,
    IsDeleted,
    TotalRecordSource,
    TotalRecordSynced
FROM dbo.DataSyncDetail
ORDER BY Id DESC;
```

### Stuck Or Misnamed Dynamic Jobs

```sql
SELECT
    JobName,
    IsStarted,
    IsCompleted,
    COUNT(*) AS RowCount,
    MAX(SyncStartTime) AS LastStart,
    MAX(SyncEndTime) AS LastEnd
FROM dbo.DataSyncDetail
WHERE JobName LIKE '%Dynamic%' OR JobName LIKE '%Dyanamic%'
GROUP BY JobName, IsStarted, IsCompleted
ORDER BY LastStart DESC;
```

### SQL Agent Job Schedule Verification

Run this in `msdb`.

```sql
SELECT
    j.name AS JobName,
    j.enabled AS JobEnabled,
    s.name AS ScheduleName,
    s.enabled AS ScheduleEnabled,
    s.freq_type,
    s.freq_subday_type,
    s.freq_subday_interval,
    s.active_start_time,
    s.active_end_time,
    js.next_run_date,
    js.next_run_time
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules js
    ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules s
    ON s.schedule_id = js.schedule_id
WHERE j.name IN (
    N'reporting-sync-job',
    N'reporting-snapshot-sync-job',
    N'reporting-data-cleanup-job'
)
ORDER BY j.name;
```

### Snapshot Freshness

```sql
SELECT 'Inventory_Snapshot' AS TableName, COUNT(*) AS Rows, MAX(Snapshot_Timestamp) AS LatestSnapshot FROM dbo.Inventory_Snapshot
UNION ALL SELECT 'Containers_Snapshot', COUNT(*), MAX(Snapshot_Timestamp) FROM dbo.Containers_Snapshot
UNION ALL SELECT 'FulfillmentOrders_Snapshot', COUNT(*), MAX(Snapshot_Timestamp) FROM dbo.FulfillmentOrders_Snapshot
UNION ALL SELECT 'FulfillmentOrderLines_Snapshot', COUNT(*), MAX(Snapshot_Timestamp) FROM dbo.FulfillmentOrderLines_Snapshot
UNION ALL SELECT 'FulfillmentOrderStatusHistory_Snapshot', COUNT(*), MAX(Snapshot_Timestamp) FROM dbo.FulfillmentOrderStatusHistory_Snapshot
UNION ALL SELECT 'Products_Snapshot', COUNT(*), MAX(Snapshot_Timestamp) FROM dbo.Products_Snapshot;
```

### Report Event Table Freshness

```sql
SELECT 'Report_Data' AS TableName, COUNT(*) AS Rows, MAX([TimeStamp]) AS LatestEvent FROM dbo.Report_Data
UNION ALL SELECT 'Pick', COUNT(*), MAX([TimeStamp]) FROM dbo.Pick
UNION ALL SELECT 'BinPresented', COUNT(*), MAX([TimeStamp]) FROM dbo.BinPresented
UNION ALL SELECT 'CloseBin', COUNT(*), MAX([TimeStamp]) FROM dbo.CloseBin
UNION ALL SELECT 'Pick-SignIn', COUNT(*), MAX([TimeStamp]) FROM dbo.[Pick-SignIn]
UNION ALL SELECT 'Pick-SignOut', COUNT(*), MAX([TimeStamp]) FROM dbo.[Pick-SignOut];
```

### ReportedMetrics Source Check

Run this only where `KFX_AUTOSTORE` is reachable from the same SQL Server.

```sql
SELECT
    COUNT(*) AS SourceRows,
    MIN(PrimaryKey) AS MinPrimaryKey,
    MAX(PrimaryKey) AS MaxPrimaryKey,
    MIN([TimeStamp]) AS MinTimestamp,
    MAX([TimeStamp]) AS MaxTimestamp
FROM KFX_AUTOSTORE.dbo.ReportedMetrics;

SELECT TOP (50)
    DataDescription,
    COUNT(*) AS Rows,
    MIN(PrimaryKey) AS MinPrimaryKey,
    MAX(PrimaryKey) AS MaxPrimaryKey,
    MIN([TimeStamp]) AS MinTimestamp,
    MAX([TimeStamp]) AS MaxTimestamp
FROM KFX_AUTOSTORE.dbo.ReportedMetrics
GROUP BY DataDescription
ORDER BY Rows DESC;

SELECT TOP (20)
    Id,
    JobName,
    DatabaseName,
    TableName,
    BatchId,
    StartPrimaryKey,
    EndPrimaryKey,
    SyncStartTime,
    SyncEndTime,
    IsStarted,
    IsCompleted,
    TotalRecordSource,
    TotalRecordSynced
FROM dbo.DataSyncDetail
WHERE TableName = 'ReportedMetrics'
ORDER BY Id DESC;
```

### Historical Dashboard Sanity

```sql
SELECT 'BinPresentedHD' AS ViewName, MIN([Date]) AS MinDate, MAX([Date]) AS MaxDate, SUM(BinPresented) AS TotalValue FROM dbo.BinPresentedHD
UNION ALL SELECT 'LinesCompletedHD', MIN([Date]), MAX([Date]), SUM(LinesCompleted) FROM dbo.LinesCompletedHD
UNION ALL SELECT 'OrdersCompletedHD', MIN([Date]), MAX([Date]), SUM(OrdersCompleted) FROM dbo.OrdersCompletedHD
UNION ALL SELECT 'UnitsPickedHD', MIN([Date]), MAX([Date]), SUM(UnitsPicked) FROM dbo.UnitsPickedHD;
```

### Throughput Sanity

```sql
SELECT
    [Date],
    [Hour],
    Ports,
    OrderCategory,
    SUM(OrdersCompleted) AS OrdersCompleted,
    SUM(LinesCompleted) AS LinesCompleted,
    SUM(BinPresentationsCompleted) AS BinPresentationsCompleted
FROM dbo.Throughput
GROUP BY [Date], [Hour], Ports, OrderCategory
ORDER BY [Date] DESC, [Hour], Ports, OrderCategory;
```

### Productivity Table Freshness And Blank Checks

```sql
SELECT 'UnitsCompletedPerUser' AS ViewName, COUNT(*) AS Rows FROM dbo.UnitsCompletedPerUser
UNION ALL SELECT 'UnitsCompletedPerPort', COUNT(*) FROM dbo.UnitsCompletedPerPort
UNION ALL SELECT 'OrdersCompletedPerUser', COUNT(*) FROM dbo.OrdersCompletedPerUser
UNION ALL SELECT 'OrdersCompletedPerPort', COUNT(*) FROM dbo.OrdersCompletedPerPort
UNION ALL SELECT 'LinesCompletedPerUser', COUNT(*) FROM dbo.LinesCompletedPerUser
UNION ALL SELECT 'LinesCompletedPerPort', COUNT(*) FROM dbo.LinesCompletedPerPort
UNION ALL SELECT 'TotalLoggedTimePerUser', COUNT(*) FROM dbo.TotalLoggedTimePerUser
UNION ALL SELECT 'TotalLoggedTimePerPort', COUNT(*) FROM dbo.TotalLoggedTimePerPort;
```

### Productivity V2 Candidate Validation

Run after applying `create-reporting-productivity-work-events-v4.5.0.sql`.

```sql
SELECT *
FROM dbo.v_ProductivityCurrentFeedReadiness_v2;

SELECT *
FROM dbo.v_ProductivityValidation_v2
ORDER BY CheckName;

SELECT
    WorkType,
    EventType,
    SourceName,
    AttributionMethod,
    COUNT(*) AS EventRows,
    SUM(OrderCompletedCount) AS OrdersCompleted,
    SUM(BinPresentationCount) AS BinPresentationsCompleted,
    SUM(LineCompletedCount) AS LinesCompleted,
    SUM(UnitCompletedCount) AS UnitsCompleted,
    SUM(RateDenominatorSeconds) AS RateDenominatorSeconds,
    SUM(HandleSeconds) AS HandleSeconds,
    SUM(MachineWaitSeconds) AS MachineWaitSeconds,
    MIN(StartTime) AS MinStartTime,
    MAX(StartTime) AS MaxStartTime
FROM dbo.v_ProductivityWorkEvents_v2
GROUP BY WorkType, EventType, SourceName, AttributionMethod
ORDER BY WorkType, EventType, SourceName, AttributionMethod;

SELECT *
FROM dbo.v_ProductivityByUserWorkType_v2
ORDER BY Users, WorkType;

SELECT *
FROM dbo.v_ProductivityByPortWorkType_v2
ORDER BY Ports, WorkType;
```

For Power BI replacement testing, start with the work-type views. Do not hide `WorkType`, `RateDenominatorSource`, `SessionEventRows`, `PickEventRows`, or `UnattributedEventRows` during validation; those columns explain why a metric is zero or rate-denominated differently.

### Productivity Promotion Path

Use this sequence; do not skip validation.

1. Run `diagnose-reporting-productivity-sources-v4.5.0.sql` to confirm which physical source tables contain the event history needed for the test window.
2. Run `create-reporting-productivity-source-grain-v4.5.0.sql` if historical/live/archive reconciliation is needed.
3. Run `create-reporting-productivity-work-events-v4.5.0.sql` in `KFX_REPORTING`.
4. Run `validate-reporting-productivity-v4.5.0.sql`, or run the v2 validation queries above manually.
5. Confirm `v_ProductivityValidation_v2.RawValue = EventValue` for every check.
6. Confirm `v_ProductivityCurrentFeedReadiness_v2` has the expected feed rows for the scenario being tested. For the current PBIX Productivity page, `HasPickRows = 1` is required for meaningful orders, lines, units, and pick-rate metrics.
7. Compare `v_ProductivityByUserWorkType_v2` and `v_ProductivityByPortWorkType_v2` to one or two known operational examples.
8. Only after those checks pass, run `patch-reporting-productivity-views-v4.5.0.sql` to repoint the existing PBIX-imported helper views to the v2 pick grain.
9. Refresh Power BI Desktop and compare the Productivity by User / Port page to the v2 SQL views.
10. If the Power BI refresh or values are unacceptable, run `rollback-reporting-productivity-views-v4.5.0.sql` and refresh again.

If users need PutAway, CycleCount, or OnDemand productivity in Power BI, create a revised page or table visual that imports `v_ProductivityByUserWorkType_v2` and `v_ProductivityByPortWorkType_v2` directly. Do not hide those work types inside the existing pick-focused page.

## Agent Workflow

For each incorrect dashboard, follow this loop:

1. Identify the page and visual.
2. Extract the fields from the PBIX layout.
3. Confirm the deployment context: asset version, installed SQL job schedules, SQL Server Agent status, Desktop vs published report, gateway status, and dataset refresh time.
4. Confirm the Power BI source server and database in the PBIP/TMDL, Desktop data source settings, or published dataset settings.
5. Classify each field as SQL column, DAX measure, calculated table, slicer, or dynamic measure.
6. If a DAX measure is involved, inspect the relevant TMDL file before writing SQL diagnostics.
7. Trace SQL-backed fields to the view or helper table in `create-reporting-database-4.5.0.sql`.
8. Trace the view or helper table to the stored procedure that populates it.
9. Run read-only SQL to compare source rows, transformed rows, and report-facing rows.
10. Check date filters first, because many views and KPI tables use `GETDATE()`, `LastUpdatedDate`, `StatusDate`, or `TimeStamp` differently.
11. Check model relationships second, especially calendar tables, bidirectional relationships, and dynamic slicer tables.
12. Check duplicate SQL joins third, especially joins from `Pick` to orders, lines, status history, and bin events.
13. Check sync freshness fourth, using `DataSyncDetail`, SQL Agent schedules, and max timestamps.
14. If the report is published, compare SQL freshness to Power BI dataset refresh and gateway status.
15. Produce a short finding with evidence, suspected root cause, and the smallest proposed fix.

## Starter Prompt

Paste this into a fresh agent when starting a dashboard investigation:

```text
You are my Power BI reporting troubleshooting agent. Use the local files in this repo, especially POWERBI_ANALYSIS_AGENT.md, the PBIP export, TMDL semantic model, report definition JSON, create-reporting-database-4.5.0.sql, and the KFX v4.6.0 reporting usage document.

Dashboard/problem:
[describe the incorrect page, visual, expected value, actual value, date range, user/port/SKU filters, and whether the issue is blank, stale, too high, too low, duplicated, or not filtering]

Please:
1. Map the visual to PBIX fields and SQL/DAX dependencies.
2. Identify the most likely SQL view, helper table, stored procedure, and job involved.
3. Inspect the relevant TMDL DAX measures and relationships before assuming SQL is wrong.
4. Give me read-only SQL diagnostics to prove or disprove the issue.
5. Check whether this is a source connection, version/deployment, SQL sync, SQL calculation, DAX/model, relationship, gateway, or Power BI dataset refresh issue.
6. Call out likely date filter, sync freshness, duplicate join, dynamic measure, relationship, gateway refresh, or version mismatch risks.
7. Do not modify source files or data unless I explicitly ask for a patch.
```

## What To Capture From The User

Ask for these details before deep troubleshooting:

- Dashboard page name
- Visual title or screenshot
- Actual value shown in Power BI
- Expected value and how it was calculated
- Date range and timezone assumption
- Active slicers or filters
- Whether this is Desktop, Service, or published dataset
- PBIX version and SQL script version in use
- Server name and database name configured in Power BI data source settings
- Whether the expected Power BI SQL source is `10.0.26.70` / `KFX_REPORTING` or another server/database
- Whether the report uses the intended read-only reporting account
- Gateway name/status if published to Power BI Service
- Dataset refresh cadence if published to Power BI Service
- Last dataset refresh time
- Last successful SQL Agent job run
- Installed SQL Agent job schedules
