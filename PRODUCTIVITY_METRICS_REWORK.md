# Productivity Metrics Rework

This is the working deployment path for reworking the Kardex Power BI Productivity by User / Port metrics around one traceable event grain.

## Goal

Use one event stream with explicit user, port, work type, event time, duration, denominator, and metric flags. Then derive user and port productivity from that stream instead of mixing unrelated helper tables.

## Operator Checklist

Run these in SSMS against `KFX_REPORTING` on `vm-as-dbsql0011`:

1. `create-reporting-productivity-work-events-v4.5.0.sql`
2. `validate-reporting-productivity-v4.5.0.sql`
   - continue only if `DropInPatchPromotionGate = PASS`
3. `patch-reporting-productivity-views-v4.5.0.sql`
4. `validate-reporting-productivity-powerbi-patch-v4.5.0.sql`
   - continue only if `PowerBIPatchValidationGate = PASS`
5. Refresh Power BI Desktop and compare the Productivity by User / Port page with the v2 SQL output.

If either gate returns `REVIEW`, stop and inspect the detail result sets before refreshing Power BI.

## Files

- `04 Assets - Reporting/diagnose-reporting-productivity-sources-v4.5.0.sql`
  - Read-only source coverage. Shows which physical source tables contain reported metric events.
- `04 Assets - Reporting/create-reporting-productivity-source-grain-v4.5.0.sql`
  - Source-aware analysis layer. Unions live/archive reported metrics without assuming `PrimaryKey` is globally unique, de-duplicates by event content, and exposes raw source diagnostics.
- `04 Assets - Reporting/validate-reporting-productivity-source-grain-v4.5.0.sql`
  - Evidence bundle for the source-aware layer. Shows source coverage, de-duplication, raw event coverage, and paired raw sessions.
- `04 Assets - Reporting/create-reporting-productivity-work-events-v4.5.0.sql`
  - Additive setup. Creates `v_ProductivityWorkEvents_v2`, work-type aggregates, `v_ProductivityDailyUserPortWorkType_v2`, readiness, and validation views.
- `04 Assets - Reporting/validate-reporting-productivity-v4.5.0.sql`
  - Evidence bundle. Run this after setup and paste the results into the investigation.
- `04 Assets - Reporting/patch-reporting-productivity-views-v4.5.0.sql`
  - Optional promotion. Repoints the existing PBIX-imported productivity views to the v2 pick grain.
- `04 Assets - Reporting/validate-reporting-productivity-powerbi-patch-v4.5.0.sql`
  - Post-patch evidence bundle. Confirms the PBIX-imported helper views reconcile to the corrected v2 Pick aggregate by total and by visible user/port row.
- `04 Assets - Reporting/trace-reporting-productivity-events-v4.5.0.sql`
  - Read-only drill-through. Filter by work type, user, port, and date to see the aggregate row, event-type reconciliation, and source event rows behind a productivity value.
- `04 Assets - Reporting/run-reporting-productivity-rework.ps1`
  - Optional PowerShell runner. Runs setup and validation, saves logs, and applies the patch only when explicitly called with `-ApplyPatch`.
- `04 Assets - Reporting/switch-powerbi-sql-source.ps1`
  - Optional PBIP helper. After Power BI Desktop is closed, rewrites PBIP TMDL SQL source references from the IP address to the SQL Server host name.
- `04 Assets - Reporting/rollback-reporting-productivity-views-v4.5.0.sql`
  - Restores the original shipped table-backed productivity views.
- `04 Assets - Reporting/Kardex-v4.5.0_out.SemanticModel/definition/tables/ProductivityDailyUserPortWorkType_v2.tmdl`
  - PBIP semantic-model import table for `dbo.v_ProductivityDailyUserPortWorkType_v2`. This exposes the corrected daily user/port/work-type aggregate directly to Power BI.

## Current Design

- `WorkType` separates `Pick`, `PutAway`, `CycleCount`, and `OnDemand`.
- Count metrics are event flags: orders, bin presentations, lines, and units.
- Order counts come from reported-metric `Order` events. They are not supplemented from `FulfillmentOrderStatusHistory`, because that would mix source grains.
- `/HR` metrics use paired `SignIn` / `SignOut` session time.
- Bin handle time and machine wait time are separate from rate denominator time.
- The optional PBIX-compatible patch filters to `WorkType = 'Pick'` because the current Productivity page has no work-type field.

## Promotion Gates

Do not run the patch until validation says the source data is ready.

Required for the drop-in patch:

- Source coverage proves the needed test window is present in the reporting feed being validated.
- `v_ProductivityValidation_v2` has zero differences.
- `v_ProductivityCurrentFeedReadiness_v2.HasPickRows = 1`.
- Pick aggregates exist in `v_ProductivityByUserWorkType_v2`.
- Pick rows use `RateDenominatorSource = 'SESSION'`; handle fallback is diagnostic only.

If any gate fails, keep the v2 views as diagnostic views and do not repoint the existing PBIX helper views.

## Latest Validation Evidence

Validation pasted from SSMS at `2026-06-24 16:57:16 -04:00`:

- `DropInPatchPromotionGate = PASS`
- `FailedValidationChecks = 0`
- current reporting feed has Pick, Order, BinPresented, and paired session rows
- raw/event checks all matched:
  - bin presentations: 5 raw vs 5 event
  - completed pick lines: 2 raw vs 2 event
  - completed pick units: 2 raw vs 2 event
  - paired session seconds: 182.699 raw vs 182.699 event
  - reported order rows: 2 raw vs 2 event
- Pick aggregate is `admin` / `P4`: 2 orders, 3 bin presentations, 2 lines, 2 units, session denominator

Post-patch validation pasted from SSMS at `2026-06-24 16:59:16 -04:00`:

- `PowerBIPatchValidationGate = PASS`
- `FailedHelperViewChecks = 0`
- all 22 PBIX-imported productivity helper views reconciled to the corrected v2 Pick aggregate
- daily aggregate has 3 rows for `2026-06-24`, with 3 work types, 2 users, and 2 ports

The post-patch validator was then strengthened to add row-level user/port checks. Re-running it should still show `PowerBIPatchValidationGate = PASS`; that gate now requires both total-level and row-level helper view reconciliation.

This means the SQL side and PBIX helper-view compatibility layer are validated. Power BI Desktop refresh is still unverified.

Power BI Desktop refresh failed with:

- `Microsoft SQL: The target principal name is incorrect. Cannot generate SSPI context.`

That is a Windows authentication/SPN issue, not a productivity-metric validation failure. The PBIP model contains many `Sql.Database("10.0.26.70", "KFX_REPORTING")` imports, while SSMS validation succeeded against `vm-as-dbsql0011`. In Desktop, change the SQL data source from `10.0.26.70` to `vm-as-dbsql0011` and keep Windows authentication. For the PBIP export, close Power BI Desktop and run `switch-powerbi-sql-source.ps1` to rewrite source references.

## Run Order

```sql
-- 1. Read-only source coverage
:r ".\04 Assets - Reporting\diagnose-reporting-productivity-sources-v4.5.0.sql"

-- 2. Optional source-aware history analysis
:r ".\04 Assets - Reporting\create-reporting-productivity-source-grain-v4.5.0.sql"
:r ".\04 Assets - Reporting\validate-reporting-productivity-source-grain-v4.5.0.sql"

-- 3. Additive setup for the reporting database's currently parsed event tables
:r ".\04 Assets - Reporting\create-reporting-productivity-work-events-v4.5.0.sql"

-- 4. Validation evidence
:r ".\04 Assets - Reporting\validate-reporting-productivity-v4.5.0.sql"

-- 5. Optional promotion only after validation passes
:r ".\04 Assets - Reporting\patch-reporting-productivity-views-v4.5.0.sql"

-- 6. Validate the PBIX-imported helper views after the patch
:r ".\04 Assets - Reporting\validate-reporting-productivity-powerbi-patch-v4.5.0.sql"

-- 7. Rollback if needed
:r ".\04 Assets - Reporting\rollback-reporting-productivity-views-v4.5.0.sql"
```

If SSMS SQLCMD mode is not enabled, open and run each script manually in the order above.

## Optional PowerShell Runner

Use this only after you are comfortable with the manual SSMS flow. The first command runs setup and validation only; it does not patch the Power BI-facing helper views.

```powershell
.\04 Assets - Reporting\run-reporting-productivity-rework.ps1
```

If that prints `DropInPatchPromotionGate: PASS`, the patch can be applied with:

```powershell
.\04 Assets - Reporting\run-reporting-productivity-rework.ps1 -ApplyPatch
```

The runner saves timestamped logs under `04 Assets - Reporting/validation-output`.

## Power BI Validation

After the optional patch:

1. Run `validate-reporting-productivity-powerbi-patch-v4.5.0.sql`.
2. Confirm `PowerBIPatchValidationGate = PASS`.
3. Refresh Power BI Desktop.
4. Compare the Productivity by User / Port page to:
   - `dbo.v_ProductivityByUserWorkType_v2`
   - `dbo.v_ProductivityByPortWorkType_v2`
5. Confirm that the PBIX source is the same `KFX_REPORTING` database used for SQL validation.
6. If values do not match or refresh fails, run the rollback script and refresh again.

When a specific user/port/date value looks wrong, run `trace-reporting-productivity-events-v4.5.0.sql` with matching filters. The first result set shows the aggregate row, the second reconciles by event type, and the third lists the source events and primary keys.

The PBIP semantic model also includes `ProductivityDailyUserPortWorkType_v2`, imported from `dbo.v_ProductivityDailyUserPortWorkType_v2`. After running the latest setup script, refresh the PBIP/PBIX and confirm this table loads. It is the preferred source for a redesigned Productivity page because every displayed metric comes from one event grain.

## Recommended PBIX Redesign

For a real revised Productivity page, import `dbo.v_ProductivityDailyUserPortWorkType_v2` directly instead of using the old multi-helper-table pattern.

The PBIP export already has this table added to the semantic model as `ProductivityDailyUserPortWorkType_v2`. Once the SQL view exists in `KFX_REPORTING`, use that table for new visuals instead of adding more per-metric helper imports.

Use columns from that one table:

- rows/grouping: `Users` or `Ports`
- slicers: `EventDate`, `WorkType`, `Users`, `Ports`
- values: `OrdersCompleted`, `BinPresentationsCompleted`, `LinesCompleted`, `UnitsCompleted`, `OrdersPerHour`, `BinsPerHour`, `UnitsPerHour`, `LinesPerHour`, `MachineWaitMinutes`, `AverageHandleTimePerPresentationMinutes`, `TotalLoggedMinutes`
- diagnostic fields during validation: `RateDenominatorSource`, `EventRows`, `SessionEventRows`, `PickEventRows`, `OrderEventRows`, `UnattributedEventRows`

This avoids the current model's pattern of importing separate tables for every metric and then stitching users/ports together with calculated slicer tables.

## Remaining Decisions

Before this can be considered complete, choose whether Power BI should:

- keep the existing pick-focused Productivity page using the compatibility patch, or
- add a revised page that imports the v2 work-type views directly and exposes `WorkType`.

The second option is better if users need PutAway, CycleCount, or OnDemand productivity in the report.

The current evidence shows reported metric telemetry is split across multiple physical stores:

- live `KFX_AUTOSTORE.dbo.ReportedMetrics` has current June 24 rows but no Pick rows in the sample tested
- `KFX_AUTOSTORE_ARCHIVE.dbo.ReportedMetrics` has history through June 15
- `KFX_AUTOSTORE_ARCHIVE_NEW.dbo.ArchiveReportedMetrics` has Pick/Order history through June 18

Do not assume one table contains the full productivity timeline until the source coverage script proves it.

Also do not insert a naive union of those sources into `dbo.Report_Data`: that table keys only on `PrimaryKey`, and source primary keys overlap. Use the source-aware views first, then decide whether a new durable staging table with `(SourceDatabase, SourceTable, SourcePrimaryKey)` identity is needed.
