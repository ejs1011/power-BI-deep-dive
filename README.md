# Kardex Power BI Reporting Setup

This repo contains the Kardex reporting database scripts, a repaired Power BI project, and validation scripts for the seven-tab supervisor dashboard.

Use the replacement PBIP, not the original PBIX:

- Power BI project: `04 Assets - Reporting/Kardex PowerBI 2.0 Beta.pbip`
- Final PBIX to save/use: `04 Assets - Reporting/Kardex PowerBI 2.0 Beta.pbix`
- SQL database: `KFX_REPORTING`
- Current tested SQL server source: `10.0.26.70`

## Recommended Setup

Use this path when `KFX_REPORTING` already exists and you are applying the repaired seven-tab dashboard logic.

Run these from the repo root in PowerShell:

```powershell
cd C:\Users\eschneider\projects\power-BI-deep-dive
```

First, check SQL connectivity:

```powershell
.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -CheckOnly
```

Then apply the reporting fixes, run all SQL validation gates, and open the replacement PBIP:

```powershell
.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -Apply -OpenPbip
```

If you already applied the SQL patches and only need to reopen the PBIP, you can use:

```powershell
.\run-reporting-supervisor-rework.ps1 -OpenPbip
```

`-OpenPbip` by itself does not apply SQL patches. If the repo changed since the last SQL apply, use `-Apply -OpenPbip` instead.

In Power BI Desktop:

1. Refresh the report.
2. Inspect all 7 tabs.
3. Save as, or overwrite, `04 Assets - Reporting\Kardex PowerBI 2.0 Beta.pbix`.

After saving the PBIX, prove it is current with the PBIP source:

```powershell
.\validate-reporting-pbip-static.ps1 -RequireCurrentPbix
```

## Fresh Reporting Install Only

Skip this section if `KFX_REPORTING` already exists and the SQL Server Agent jobs are already installed.

For a new reporting database/environment, run the base install scripts in SSMS first:

1. `04 Assets - Reporting/create-reporting-database-4.5.0.sql`
2. `04 Assets - Reporting/create-reporting-sync-job-v.4.5.0.sql`
3. `04 Assets - Reporting/create-reporting-snapshot-sync-job-v4.5.0.sql`
4. `04 Assets - Reporting/create-reporting-cleanup-job-v4.5.0.sql`

Then run the recommended setup above to apply the supervisor dashboard rework and validations.

The job scripts create:

- `reporting-sync-job`: operational reporting sync, every 2 hours.
- `reporting-snapshot-sync-job`: snapshot sync, every 1 hour.
- `reporting-data-cleanup-job`: cleanup, every 12 hours.

Confirm SQL Server Agent is running in SSMS after creating these jobs. Existing environments may have edited schedules; your current server can differ from the script defaults, so check the job schedule in SSMS or with the runner's SQL readiness output.

## One Command With Logging

Use this when you want one run log to paste back for troubleshooting:

```powershell
.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -Apply -OpenPbip -LogPath reporting-supervisor-rework-run.log
```

The script prompts for the SQL password. Do not put the password in the command line.

## If Authentication Fails

If Power BI or SQL Server reports:

```text
The target principal name is incorrect. Cannot generate SSPI context.
```

then Windows authentication is failing against the IP address. For SQL-login based validation, `10.0.26.70` is fine. For Windows integrated authentication, use the server name instead:

```text
vm-as-dbsql0011
```

## If SQL Validation Fails on SET Options

If a validation script reports that `QUOTED_IDENTIFIER` or other SET options are incorrect, rerun with the latest scripts. The runner SQL files explicitly set the options SQL Server requires when querying objects that may use indexed views, computed columns, filtered indexes, XML methods, or spatial indexes.

## Power BI Data Source Settings

The replacement PBIP currently points to `10.0.26.70` and `KFX_REPORTING`.

In Power BI Desktop, use **File > Options and settings > Data source settings** if the refresh prompts for credentials or uses the wrong server. Use one of these approaches:

- SQL login: keep server `10.0.26.70` and enter the SQL username/password.
- Windows integrated authentication: switch the server to `vm-as-dbsql0011` to avoid the IP-address SSPI issue.

Do not open and edit the original `Kardex-v4.5.0.pbix`; use `Kardex PowerBI 2.0 Beta.pbip` and save the final result as `Kardex PowerBI 2.0 Beta.pbix`.

## Validation Commands

Local PBIP/static validation only:

```powershell
.\validate-reporting-pbip-static.ps1
```

SQL validation gates only, without reapplying patches:

```powershell
.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -ValidateOnly
```

Expected SQL gate results:

- `PowerBIPatchValidationGate = PASS`
- `SupervisorPageValidationGate = PASS`
- `AllPagesSmokeGate = PASS`
- `VisibleMetricsValidationGate = PASS`

Warnings can be valid for true zero-state pages, such as no current open work. Failures mean the report-facing data does not match usable source data.

## Manual SSMS Script Order

Only use this path if you are not using `run-reporting-supervisor-rework.ps1`.

Run against `KFX_REPORTING` in this order:

1. `04 Assets - Reporting/create-reporting-productivity-work-events-v4.5.0.sql`
2. `04 Assets - Reporting/patch-reporting-productivity-views-v4.5.0.sql`
3. `04 Assets - Reporting/patch-reporting-supervisor-page-views-v4.5.0.sql`
4. `04 Assets - Reporting/validate-reporting-productivity-powerbi-patch-v4.5.0.sql`
5. `04 Assets - Reporting/validate-reporting-supervisor-page-views-v4.5.0.sql`
6. `04 Assets - Reporting/validate-reporting-all-pages-smoke-v4.5.0.sql`
7. `04 Assets - Reporting/validate-reporting-visible-metrics-v4.5.0.sql`

## Script Inventory

Primary runner:

- `run-reporting-supervisor-rework.ps1`  
  Main orchestration script. Runs static PBIP checks, applies SQL patches, runs SQL validation gates, opens the PBIP, and can write a run log.

- `validate-reporting-pbip-static.ps1`  
  Local validation of PBIP/report/model files. Use `-RequireCurrentPbix` after saving the final PBIX.

Main SQL patch scripts:

- `create-reporting-productivity-work-events-v4.5.0.sql`  
  Creates the consistent productivity event/daily grain used by Productivity, Throughput, and Historical pages.

- `patch-reporting-productivity-views-v4.5.0.sql`  
  Replaces old productivity comparison views with the corrected event-grain views.

- `patch-reporting-supervisor-page-views-v4.5.0.sql`  
  Rebuilds supervisor-facing page views for Daily KPI, Inventory, Throughput, Open Work, Historical, and Consolidation.

Validation SQL scripts:

- `validate-reporting-productivity-powerbi-patch-v4.5.0.sql`  
  Verifies the Power BI model-facing productivity objects and measures are present.

- `validate-reporting-supervisor-page-views-v4.5.0.sql`  
  Verifies the SQL page views calculate against the intended source grain.

- `validate-reporting-all-pages-smoke-v4.5.0.sql`  
  Confirms each report page has usable backing rows and names missing or stale source areas.

- `validate-reporting-visible-metrics-v4.5.0.sql`  
  Compares visible report metrics against source data so a page fails when source data exists but report-facing metrics are blank or wrong.

Diagnostics and repair:

- `diagnose-reporting-daily-kpi-v4.5.0.sql`  
  Troubleshoots Daily KPI source rows and current reporting values.

- `diagnose-reporting-daily-kpi-sync-v4.5.0.sql`  
  Checks whether the reporting sync is stuck, stale, or missing recent snapshot rows.

- `repair-reporting-daily-kpi-sync-v4.5.0.sql`  
  Repairs a stuck Daily KPI sync row and starts a fresh snapshot load.

- `diagnose-reporting-productivity-sources-v4.5.0.sql`  
  Inspects source rows available for productivity event construction.

- `trace-reporting-productivity-events-v4.5.0.sql`  
  Traces productivity event logic for debugging questionable user/port metrics.

Older or supporting scripts:

- `create-reporting-database-4.5.0.sql`  
  Original/base reporting database creation script. Do not run during normal rework unless rebuilding `KFX_REPORTING` from scratch.

- `create-reporting-sync-job-v.4.5.0.sql`  
  Creates the SQL Server Agent job that syncs operational data into reporting.

- `create-reporting-snapshot-sync-job-v4.5.0.sql`  
  Creates the SQL Server Agent snapshot sync job.

- `create-reporting-cleanup-job-v4.5.0.sql`  
  Creates the SQL Server Agent cleanup job.

- `run-reporting-productivity-rework.ps1`  
  Older productivity-only runner. Prefer `run-reporting-supervisor-rework.ps1` for the full seven-page dashboard.

- `switch-powerbi-sql-source.ps1`  
  Helper to switch Power BI source settings between server names/IPs.

- `rollback-reporting-productivity-views-v4.5.0.sql`  
  Rollback helper for the earlier productivity-only view patch.

## Final Checklist

Before treating the dashboard as ready:

1. SQL apply/validation gates pass.
2. `.\validate-reporting-pbip-static.ps1` passes locally.
3. Open `Kardex PowerBI 2.0 Beta.pbip`.
4. Refresh in Power BI Desktop.
5. Save over `Kardex PowerBI 2.0 Beta.pbix`.
6. Run `.\validate-reporting-pbip-static.ps1 -RequireCurrentPbix`.
7. Review all 7 tabs as a warehouse supervisor:
   - Daily KPI Summary Report
   - Inventory & Location Table Summary
   - Productivity by User / Port
   - Throughput
   - Open Work History
   - Historical Dashboard
   - Consolidation Report
