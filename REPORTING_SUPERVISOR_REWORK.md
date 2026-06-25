# Kardex Reporting Supervisor Rework

Status: in progress. Replacement PBIP prepared; local static validation and live SQL validation gates have passed. Final PBIX refresh/save is still pending.

Replacement project:

- `04 Assets - Reporting/Kardex-v4.5.0_Productivity-v2_try.pbip`
- Report folder: `04 Assets - Reporting/Kardex-v4.5.0_Productivity-v2_try.Report`
- Semantic model folder: `04 Assets - Reporting/Kardex-v4.5.0_Productivity-v2_try.SemanticModel`

## Apply Order

Local static PBIP validation:

```powershell
.\validate-reporting-pbip-static.ps1
```

Fast path from PowerShell:

```powershell
.\run-reporting-supervisor-rework.ps1 -Apply
```

To apply/validate and then open the replacement PBIP in Power BI Desktop:

```powershell
.\run-reporting-supervisor-rework.ps1 -Apply -OpenPbip
```

To open the already-applied replacement PBIP for final refresh/save, with local PBIP validation first:

```powershell
.\run-reporting-supervisor-rework.ps1 -OpenPbip
```

Connectivity/readiness check only:

```powershell
.\run-reporting-supervisor-rework.ps1 -CheckOnly
```

Validation gates only, without reapplying SQL patches:

```powershell
.\run-reporting-supervisor-rework.ps1 -ValidateOnly
```

If Windows authentication fails by IP with SSPI errors, use a SQL login without storing the password:

```powershell
.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -CheckOnly
.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -ValidateOnly
.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -Apply -OpenPbip
```

Manual SSMS path against `KFX_REPORTING`:

1. `04 Assets - Reporting/create-reporting-productivity-work-events-v4.5.0.sql`
2. `04 Assets - Reporting/patch-reporting-productivity-views-v4.5.0.sql`
3. `04 Assets - Reporting/patch-reporting-supervisor-page-views-v4.5.0.sql`
4. `04 Assets - Reporting/validate-reporting-productivity-powerbi-patch-v4.5.0.sql`
5. `04 Assets - Reporting/validate-reporting-supervisor-page-views-v4.5.0.sql`
6. `04 Assets - Reporting/validate-reporting-all-pages-smoke-v4.5.0.sql`

Expected validation gates:

- `Static PBIP validation passed.`
- `PowerBIPatchValidationGate = PASS`
- `SupervisorPageValidationGate = PASS`
- `AllPagesSmokeGate = PASS`

Latest verified state:

- `.\validate-reporting-pbip-static.ps1` passes locally.
- `.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -Apply` completed with all expected SQL validation gates showing `PASS`.
- Existing `.pbix` files are older than the current PBIP edits. Open the replacement PBIP, refresh it, inspect the seven pages, then save a new PBIX from Power BI Desktop.

## Page Changes

- Daily KPI Summary Report: defaults to the last 7 days; removed stale saved date state; cleaned KPI display labels such as SKUs and Put Away wording; picking orders, lines, units, and distinct SKUs now use the corrected pick-completion logic.
- Inventory & Location Table Summary: current-state inventory/location summary; SQL patch now rebuilds `InventoryAndLocationSummary` from the latest available snapshots instead of only rows updated today, preventing a blank page when metadata did not change today.
- Productivity by User / Port: defaults to the last 7 days; uses the daily productivity event table for counts, rates, machine wait, handle time, and logged time; added a real Date Range slicer; labels now include units and two-decimal formatting.
- Throughput: defaults to the last 7 days; SQL view now aggregates orders, lines, and bin presentations from the same completed-work event grain as Productivity; removed stale date range; fixed fake `P-1` port handling; removed old visual-interaction overrides so page slicers filter both charts consistently; renamed the category filter label to "Order Category."
- Open Work History: defaults to the last 7 days; removed stale saved date filter so the page does not silently exclude current data; kept date slicer-to-chart filtering and removed the reverse chart-to-slicer interaction.
- Historical Dashboard: SQL views now roll up from the same productivity daily grain; chart labels now use clearer title case and "Lines Completed."
- Consolidation Report: current inventory consolidation/fragmentation view; SKU filter label normalized.
- All pages: added `validate-reporting-all-pages-smoke-v4.5.0.sql` to verify each report page has usable backing data. The smoke gate fails on missing/stale/null core data and reports warnings for valid zero-state pages such as no open work or no consolidation candidates.

## Notes

- The PBIP is source-controlled/editable. To produce a PBIX replacement, open the PBIP in Power BI Desktop, refresh, validate the pages, then save as PBIX over a copy of the original.
- The prepared PBIP uses `vm-as-dbsql0011` as the SQL Server source. This avoids the SSPI issue seen with the IP-address connection under Windows authentication.
- Operational date-driven pages now open to a dynamic last-7-days window. Supervisors can widen the visible date slicers when they need older troubleshooting history.
- Historical Dashboard remains intentionally fixed as trailing 30 days. If supervisors need arbitrary range analysis there too, add a shared date slicer after the SQL patch is validated.
- `run-reporting-supervisor-rework.ps1` defaults to a dry run. It only changes the reporting database when called with `-Apply`; `-CheckOnly` runs a read-only SQL readiness query; `-ValidateOnly` runs the SQL validation gates without reapplying patches. When called with `-Apply`, `-ValidateOnly`, or `-OpenPbip`, it runs `validate-reporting-pbip-static.ps1` first.
