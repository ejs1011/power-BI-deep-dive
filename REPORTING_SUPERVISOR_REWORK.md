# Kardex Reporting Supervisor Rework

Status: renamed to Kardex PowerBI 2.0 Beta and validated. Replacement PBIP passes local static validation, the live SQL runner was previously rerun successfully, and the beta PBIX content is current with the PBIP report/model source.

Replacement project:

- `04 Assets - Reporting/Kardex PowerBI 2.0 Beta.pbip`
- Report folder: `04 Assets - Reporting/Kardex PowerBI 2.0 Beta.Report`
- Semantic model folder: `04 Assets - Reporting/Kardex PowerBI 2.0 Beta.SemanticModel`
- Saved PBIX candidate: `04 Assets - Reporting/Kardex PowerBI 2.0 Beta.pbix`

## Apply Order

Local static PBIP validation:

```powershell
.\validate-reporting-pbip-static.ps1
```

After opening the PBIP, refreshing, and saving over the final PBIX, run the strict final-artifact check:

```powershell
.\validate-reporting-pbip-static.ps1 -RequireCurrentPbix
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

`-OpenPbip` by itself does not apply SQL patches. If the repo changed since the last SQL apply, use `-Apply -OpenPbip` so the database objects match the PBIP model before refresh.

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

To also capture a full run log for review:

```powershell
.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -Apply -OpenPbip -LogPath reporting-supervisor-rework-run.log
```

Manual SSMS path against `KFX_REPORTING`:

1. `04 Assets - Reporting/create-reporting-productivity-work-events-v4.5.0.sql`
2. `04 Assets - Reporting/patch-reporting-productivity-views-v4.5.0.sql`
3. `04 Assets - Reporting/patch-reporting-supervisor-page-views-v4.5.0.sql`
4. `04 Assets - Reporting/validate-reporting-productivity-powerbi-patch-v4.5.0.sql`
5. `04 Assets - Reporting/validate-reporting-supervisor-page-views-v4.5.0.sql`
6. `04 Assets - Reporting/validate-reporting-all-pages-smoke-v4.5.0.sql`
7. `04 Assets - Reporting/validate-reporting-visible-metrics-v4.5.0.sql`

Expected validation gates:

- `Static PBIP validation passed.`
- `PowerBIPatchValidationGate = PASS`
- `SupervisorPageValidationGate = PASS`
- `AllPagesSmokeGate = PASS`
- `VisibleMetricsValidationGate = PASS`

Latest verified state:

- `.\run-reporting-supervisor-rework.ps1 -Server 10.0.26.70 -SqlUser admin -Apply -OpenPbip` was rerun successfully by the user after the SQL SET-option fix. The expected live gates now pass, including `AllPagesSmokeGate` and `VisibleMetricsValidationGate`.
- `.\validate-reporting-pbip-static.ps1` passes locally.
- `.\validate-reporting-pbip-static.ps1 -RequireCurrentPbix` passes locally. The freshness check compares the PBIX against PBIX-relevant report/model content and treats newer PBIP package metadata from the rename as non-blocking.
- The beta PBIX was copied from the validated `Kardex-v4.5.0_Supervisor-Rework.pbix` because the original PBIX file was locked by Power BI Desktop during the rename.

## Page Changes

- Daily KPI Summary Report: defaults to the last 7 days; removed stale saved date state; cleaned KPI display labels such as SKUs and Put Away wording; picking orders, lines, units, and distinct SKUs now use the corrected pick-completion logic. Current inventory snapshot metrics now use a consistent positive-on-hand grain, SKU counts use product/SKU identity instead of unit-of-measure identity, and the old "Distinct Bins With Inventory Added" label is now "Distinct Bins With Inventory" because it is a current inventory-state metric, not a true add-event count.
- Inventory & Location Table Summary: current-state inventory/location summary; SQL patch now rebuilds `InventoryAndLocationSummary` from the latest available snapshots instead of only rows updated today, preventing a blank page when metadata did not change today. Metrics are grouped by the displayed compartment coordinate/type, using inventory container side/X/Y against template compartment side/X/Y, so the matrix does not repeat broad template totals under each compartment label. `% of Total Bin(s)` now uses each compartment label's share of all displayed bin groups instead of an always-100 formula.
- Productivity by User / Port: defaults to the last 7 days; uses the daily productivity event table for counts, rates, machine wait, handle time, and logged time; added a real Date Range slicer; labels now include units and two-decimal formatting. Measures no longer coerce no-activity blanks to zero, and they now require positive selected-period pick activity before returning visible values. The user/port tables also explicitly filter blank, `Unattributed`, and placeholder labels, so users/ports with no pick activity in the selected date range do not show as blank or all-zero rows.
- Throughput: defaults to the last 7 days; SQL view now aggregates orders, lines, and bin presentations from the same completed-work event grain as Productivity; removed stale date range; fixed fake `P-1` port handling; removed old visual-interaction overrides so page slicers filter both charts consistently; renamed the category filter label to "Order Category"; missing ports/categories now display as `Unattributed`/`Uncategorized` instead of raw placeholders; chart titles now say "Hourly Throughput" so the page is not confused with `/hr` rate calculations.
- Open Work History: defaults to the last 7 days; removed stale saved date filter so the page does not silently exclude current data; kept date slicer-to-chart filtering and removed the reverse chart-to-slicer interaction. Open-pick status handling now recognizes `failed allocation`, the legacy typo `falied allocation`, and `shorted`; putaway line counts exclude closed containers; cycle-count open work uses the task relationship instead of a brittle date crossjoin; the trend chart uses a linear axis so small open-work counts remain readable.
- Historical Dashboard: SQL views now roll up from the same productivity daily grain; chart labels now use clearer title case and consistent metric names such as "Lines Completed" and "Bin Presentations Completed."
- Consolidation Report: current inventory consolidation/fragmentation view; SKU filter label normalized; table now shows SKU plus compartment size, labels include units/counts, and fragmentation displays as a percentage. The SQL patch refreshes `dbo.DefragDetailByUomCompartmentSize_Table` from `KFX_AUTOSTORE.dbo.DefragDetailByUomCompartmentSizeView`. Optional metric inputs such as `TotalCompartments` and `TotalUnrealizedCapacity` remain blank when the source is blank instead of being coerced to zero.
- All pages: added `validate-reporting-all-pages-smoke-v4.5.0.sql` to verify each report page has usable backing data. Added `validate-reporting-visible-metrics-v4.5.0.sql` to compare visible page metrics against their source rows, so a page fails when source data exists but the report-facing metric is blank or zero. The visible-metrics gate covers every Daily KPI row plus the visible Productivity counts, `/hr` rates, machine-wait, handle-time, and logged-time metrics. The all-pages smoke gate now names any missing Daily KPI source view when it warns that fewer than 13 KPI sources have rows. Inventory & Location validation now checks the full 18-metric matrix for every compartment label, including missing, duplicate, or unexpected metric rows that a matrix visual could otherwise mask. Consolidation validation checks required SKU/compartment/quantity display fields, source/report row presence, nonnegative values, and fragmentation denominators; missing optional Consolidation metric fields are warnings because the table can still display useful SKU/size/quantity rows. The gates reject raw Throughput placeholders and report warnings for valid zero-state pages such as no open work or no consolidation candidates.

## Notes

- The PBIP is source-controlled/editable. The saved PBIX candidate is `Kardex PowerBI 2.0 Beta.pbix`; re-save it from the PBIP after refreshing so it includes the latest semantic-model and SQL-backed data changes.
- The prepared PBIP currently uses `10.0.26.70` consistently as the SQL Server source, matching the SQL-login validation path. If switching the PBIX to Windows integrated authentication, use `vm-as-dbsql0011` instead of the IP to avoid the SSPI target-principal issue.
- Operational date-driven pages now open to a dynamic last-7-days window. Supervisors can widen the visible date slicers when they need older troubleshooting history.
- Historical Dashboard remains intentionally fixed as trailing 30 days. If supervisors need arbitrary range analysis there too, add a shared date slicer after the SQL patch is validated.
- `run-reporting-supervisor-rework.ps1` defaults to a dry run. It only changes the reporting database when called with `-Apply`; `-CheckOnly` runs a read-only SQL readiness query; `-ValidateOnly` runs the SQL validation gates without reapplying patches. When called with `-Apply`, `-ValidateOnly`, or `-OpenPbip`, it runs `validate-reporting-pbip-static.ps1` first.
