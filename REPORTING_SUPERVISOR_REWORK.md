# Kardex Reporting Supervisor Rework

Status: in progress, replacement PBIP prepared.

Replacement project:

- `04 Assets - Reporting/Kardex-v4.5.0_Productivity-v2_try.pbip`
- Report folder: `04 Assets - Reporting/Kardex-v4.5.0_Productivity-v2_try.Report`
- Semantic model folder: `04 Assets - Reporting/Kardex-v4.5.0_Productivity-v2_try.SemanticModel`

## Apply Order

Fast path from PowerShell:

```powershell
.\run-reporting-supervisor-rework.ps1 -Apply
```

To apply/validate and then open the replacement PBIP in Power BI Desktop:

```powershell
.\run-reporting-supervisor-rework.ps1 -Apply -OpenPbip
```

Connectivity/readiness check only:

```powershell
.\run-reporting-supervisor-rework.ps1 -CheckOnly
```

If Windows authentication fails by IP with SSPI errors, use a SQL login without storing the password:

```powershell
.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -CheckOnly
.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -Apply -OpenPbip
```

Manual SSMS path against `KFX_REPORTING`:

1. `04 Assets - Reporting/create-reporting-productivity-work-events-v4.5.0.sql`
2. `04 Assets - Reporting/patch-reporting-productivity-views-v4.5.0.sql`
3. `04 Assets - Reporting/patch-reporting-supervisor-page-views-v4.5.0.sql`
4. `04 Assets - Reporting/validate-reporting-productivity-powerbi-patch-v4.5.0.sql`
5. `04 Assets - Reporting/validate-reporting-supervisor-page-views-v4.5.0.sql`

Expected validation gates:

- `PowerBIPatchValidationGate = PASS`
- `SupervisorPageValidationGate = PASS`

## Page Changes

- Daily KPI Summary Report: removed stale saved date filter; cleaned KPI display labels such as SKUs and Put Away wording; picking orders, lines, units, and distinct SKUs now use the corrected pick-completion logic.
- Inventory & Location Table Summary: left as current-state inventory/location summary.
- Productivity by User / Port: uses the daily productivity event table for counts, rates, machine wait, handle time, and logged time; added a real Date Range slicer; labels now include units and two-decimal formatting.
- Throughput: SQL view now aggregates orders, lines, and bin presentations from the same completed-work event grain as Productivity; removed stale date range; fixed fake `P-1` port handling; removed old visual-interaction overrides so page slicers filter both charts consistently.
- Open Work History: removed stale saved date filter so the page does not silently exclude current data; kept date slicer-to-chart filtering and removed the reverse chart-to-slicer interaction.
- Historical Dashboard: SQL views now roll up from the same productivity daily grain; chart labels now use clearer title case and "Lines Completed."
- Consolidation Report: left as current inventory consolidation/fragmentation view.

## Notes

- The PBIP is source-controlled/editable. To produce a PBIX replacement, open the PBIP in Power BI Desktop, refresh, validate the pages, then save as PBIX over a copy of the original.
- The prepared PBIP uses `vm-as-dbsql0011` as the SQL Server source. This avoids the SSPI issue seen with the IP-address connection under Windows authentication.
- Historical Dashboard remains intentionally fixed as trailing 30 days. If supervisors need arbitrary range analysis there too, add a shared date slicer after the SQL patch is validated.
- `run-reporting-supervisor-rework.ps1` defaults to a dry run. It only changes the reporting database when called with `-Apply`; `-CheckOnly` runs a read-only SQL readiness query.
