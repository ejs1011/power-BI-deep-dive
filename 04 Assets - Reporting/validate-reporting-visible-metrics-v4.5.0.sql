USE [KFX_REPORTING];
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO

SET NOCOUNT ON;

/*
    Visible metric validation for the Kardex supervisor report.

    Purpose:
      Check every report tab at the data-object level. A metric fails when the
      operational source has data in the report window but the report-facing
      view/table has no matching rows or value.

    Expected result:
      VisibleMetricsValidationGate = PASS
      FailedChecks = 0
*/

DECLARE @Today date = CAST(GETDATE() AS date);
DECLARE @RecentStart date = DATEADD(day, -7, @Today);
DECLARE @HistoryStart date = DATEADD(day, -30, @Today);

IF OBJECT_ID('tempdb..#MetricChecks') IS NOT NULL DROP TABLE #MetricChecks;
CREATE TABLE #MetricChecks (
    PageName varchar(100) NOT NULL,
    MetricName varchar(160) NOT NULL,
    SourceRows bigint NULL,
    ReportRows bigint NULL,
    SourceValue decimal(19, 4) NULL,
    ReportValue decimal(19, 4) NULL,
    SourceMinDate date NULL,
    SourceMaxDate date NULL,
    ReportMinDate date NULL,
    ReportMaxDate date NULL,
    Status varchar(10) NOT NULL,
    Details varchar(4000) NULL
);

IF OBJECT_ID('tempdb..#DailyKpi') IS NOT NULL DROP TABLE #DailyKpi;
CREATE TABLE #DailyKpi (
    SourceName varchar(128) NOT NULL,
    [Date] date NULL,
    MetricValue decimal(19, 4) NULL
);

INSERT INTO #DailyKpi (SourceName, [Date], MetricValue)
SELECT 'Total SKUs On Hand', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Total SKUs On Hand]) FROM dbo.Total_SKUs_On_Hand
UNION ALL SELECT 'Total Units On Hand', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Total Units On Hand]) FROM dbo.Total_Units_On_Hand
UNION ALL SELECT 'Total Locations Occupied', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Total Locations Occupied]) FROM dbo.Total_Locations_Occupied
UNION ALL SELECT 'Orders Put Away', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Orders Putaway]) FROM dbo.Orders_Putaway
UNION ALL SELECT 'Units Put Away', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Units Putaway]) FROM dbo.Units_Putaway
UNION ALL SELECT 'SKUs Put Away', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Skus Putaway]) FROM dbo.Skus_Putaway
UNION ALL SELECT 'Bin Presentations Put Away', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Presentations Putaway]) FROM dbo.Presentations_Putaway
UNION ALL SELECT 'Distinct Bins With Inventory', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Distinct bins inventory added]) FROM dbo.Distinct_bins_inventory_added
UNION ALL SELECT 'Distinct Bin Compartments With Inventory', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Distinct bin compartments that had inventory]) FROM dbo.Distinct_bin_compartments_that_had_inventory
UNION ALL SELECT 'Customer Orders Picked', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Customer Orders Picked]) FROM dbo.Customer_Orders_Picked
UNION ALL SELECT 'Customer Order Lines', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Customer Order Lines]) FROM dbo.Customer_Order_Lines
UNION ALL SELECT 'Units Picked', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Units Picked]) FROM dbo.Units_Picked
UNION ALL SELECT 'Distinct SKUs Picked', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Distinct Skus Picked]) FROM dbo.Distinct_Skus_Picked;

IF OBJECT_ID('tempdb..#DailyExpected') IS NOT NULL DROP TABLE #DailyExpected;
CREATE TABLE #DailyExpected (
    MetricName varchar(160) NOT NULL,
    SourceRows bigint NULL,
    SourceValue decimal(19, 4) NULL,
    SourceMinDate date NULL,
    SourceMaxDate date NULL
);

INSERT INTO #DailyExpected (MetricName, SourceRows, SourceValue, SourceMinDate, SourceMaxDate)
SELECT
    'Total SKUs On Hand',
    COUNT_BIG(*),
    COUNT(DISTINCT COALESCE(uom.ProductPrimaryKey, i.UnitOfMeasurePrimaryKey)),
    MIN(CAST(i.LastUpdatedDate AS date)),
    MAX(CAST(i.LastUpdatedDate AS date))
FROM dbo.Inventory i
INNER JOIN dbo.Containers c
    ON c.PrimaryKey = i.ContainerPrimaryKey
   AND c.Snapshot_Id = i.Snapshot_Id
LEFT JOIN dbo.UnitsOfMeasure uom
    ON uom.PrimaryKey = i.UnitOfMeasurePrimaryKey
   AND uom.Snapshot_Id = i.Snapshot_Id
WHERE i.Snapshot_Id = (SELECT MAX(Snapshot_Id) FROM dbo.Inventory)
  AND i.Status <> 'Pending'
  AND c.Status <> 'Outside'
  AND COALESCE(i.Quantity, 0) > 0
UNION ALL
SELECT
    'Total Units On Hand',
    COUNT_BIG(*),
    SUM(COALESCE(i.Quantity, 0)),
    MIN(CAST(i.LastUpdatedDate AS date)),
    MAX(CAST(i.LastUpdatedDate AS date))
FROM dbo.Inventory i
INNER JOIN dbo.Containers c
    ON c.PrimaryKey = i.ContainerPrimaryKey
   AND c.Snapshot_Id = i.Snapshot_Id
WHERE i.Snapshot_Id = (SELECT MAX(Snapshot_Id) FROM dbo.Inventory)
  AND i.Status <> 'Pending'
  AND c.Status <> 'Outside'
  AND COALESCE(i.Quantity, 0) > 0
UNION ALL
SELECT
    'Total Locations Occupied',
    COUNT_BIG(*),
    COUNT(DISTINCT CONCAT(i.ContainerPrimaryKey, '|', i.ContainerX, '|', i.ContainerY)),
    MIN(CAST(i.LastUpdatedDate AS date)),
    MAX(CAST(i.LastUpdatedDate AS date))
FROM dbo.Inventory i
INNER JOIN dbo.Containers c
    ON c.PrimaryKey = i.ContainerPrimaryKey
   AND c.Snapshot_Id = i.Snapshot_Id
WHERE i.Snapshot_Id = (SELECT MAX(Snapshot_Id) FROM dbo.Inventory)
  AND i.Status <> 'Pending'
  AND c.Status <> 'Outside'
  AND COALESCE(i.Quantity, 0) > 0
UNION ALL
SELECT
    'Orders Put Away',
    COUNT_BIG(*),
    COUNT_BIG(DISTINCT pac.PrimaryKey),
    MIN(CAST(pac.LastUpdatedDateInventory AS date)),
    MAX(CAST(pac.LastUpdatedDateInventory AS date))
FROM dbo.PutAwayContainers pac
WHERE pac.Status = 'Closed'
  AND CAST(pac.LastUpdatedDateInventory AS date) >= @RecentStart
UNION ALL
SELECT
    'Units Put Away',
    COUNT_BIG(*),
    SUM(COALESCE(pacli.ActualQuantity, 0)),
    MIN(CAST(pac.LastUpdatedDateInventory AS date)),
    MAX(CAST(pac.LastUpdatedDateInventory AS date))
FROM dbo.PutAwayContainers pac
INNER JOIN dbo.PutAwayContainerLineItems pacli
    ON pacli.PutAwayContainerPrimaryKey = pac.PrimaryKey
WHERE pac.Status = 'Closed'
  AND COALESCE(pacli.ActualQuantity, 0) > 0
  AND CAST(pac.LastUpdatedDateInventory AS date) >= @RecentStart
UNION ALL
SELECT
    'SKUs Put Away',
    SUM(SourceRows),
    SUM(SourceValue),
    MIN([Date]),
    MAX([Date])
FROM (
    SELECT
        CAST(pac.LastUpdatedDateInventory AS date) AS [Date],
        COUNT_BIG(*) AS SourceRows,
        COUNT(DISTINCT COALESCE(uom.ProductPrimaryKey, pacli.UnitOfMeasurePrimaryKey)) AS SourceValue
    FROM dbo.PutAwayContainers pac
    INNER JOIN dbo.PutAwayContainerLineItems pacli
        ON pacli.PutAwayContainerPrimaryKey = pac.PrimaryKey
    LEFT JOIN dbo.UnitsOfMeasure uom
        ON uom.PrimaryKey = pacli.UnitOfMeasurePrimaryKey
       AND uom.Snapshot_Id = pacli.Snapshot_Id
    WHERE pac.Status = 'Closed'
      AND COALESCE(pacli.ActualQuantity, 0) > 0
      AND CAST(pac.LastUpdatedDateInventory AS date) >= @RecentStart
    GROUP BY CAST(pac.LastUpdatedDateInventory AS date)
) x
UNION ALL
SELECT
    'Bin Presentations Put Away',
    SUM(SourceRows),
    SUM(SourceValue),
    MIN([Date]),
    MAX([Date])
FROM (
    SELECT
        CAST(pac.LastUpdatedDateInventory AS date) AS [Date],
        COUNT_BIG(*) AS SourceRows,
        COUNT(DISTINCT CONCAT(pac.PrimaryKey, '|', COALESCE(itp.LocationPrimaryKey, -1), '|', COALESCE(ita.NewContainerPrimaryKey, -1))) AS SourceValue
    FROM dbo.PutAwayContainers pac
    INNER JOIN dbo.InventoryTasks_PutAway itp
        ON itp.PutAwayContainerPrimaryKey = pac.PrimaryKey
    INNER JOIN dbo.InventoryTasks it
        ON it.PrimaryKey = itp.InventoryTaskPrimaryKey
    INNER JOIN dbo.InventoryTaskActions ita
        ON ita.InventoryTaskPrimaryKey = it.PrimaryKey
    WHERE pac.Status = 'Closed'
      AND CAST(pac.LastUpdatedDateInventory AS date) >= @RecentStart
    GROUP BY CAST(pac.LastUpdatedDateInventory AS date)
) x
UNION ALL
SELECT
    'Distinct Bins With Inventory',
    COUNT_BIG(*),
    COUNT(DISTINCT i.ContainerPrimaryKey),
    MIN(CAST(i.LastUpdatedDate AS date)),
    MAX(CAST(i.LastUpdatedDate AS date))
FROM dbo.Inventory i
INNER JOIN dbo.Containers c
    ON c.PrimaryKey = i.ContainerPrimaryKey
   AND c.Snapshot_Id = i.Snapshot_Id
WHERE i.Snapshot_Id = (SELECT MAX(Snapshot_Id) FROM dbo.Inventory)
  AND i.Status <> 'Pending'
  AND c.Status <> 'Outside'
  AND COALESCE(i.Quantity, 0) > 0
UNION ALL
SELECT
    'Distinct Bin Compartments With Inventory',
    COUNT_BIG(*),
    COUNT(DISTINCT CONCAT(i.ContainerPrimaryKey, '|', i.ContainerX, '|', i.ContainerY)),
    MIN(CAST(i.LastUpdatedDate AS date)),
    MAX(CAST(i.LastUpdatedDate AS date))
FROM dbo.Inventory i
INNER JOIN dbo.Containers c
    ON c.PrimaryKey = i.ContainerPrimaryKey
   AND c.Snapshot_Id = i.Snapshot_Id
WHERE i.Snapshot_Id = (SELECT MAX(Snapshot_Id) FROM dbo.Inventory)
  AND i.Status <> 'Pending'
  AND c.Status <> 'Outside'
  AND COALESCE(i.Quantity, 0) > 0
UNION ALL
SELECT
    'Customer Orders Picked',
    COUNT_BIG(*),
    SUM(OrdersCompleted),
    MIN(EventDate),
    MAX(EventDate)
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
  AND EventDate >= @RecentStart
UNION ALL
SELECT
    'Customer Order Lines',
    COUNT_BIG(*),
    SUM(LinesCompleted),
    MIN(EventDate),
    MAX(EventDate)
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
  AND EventDate >= @RecentStart
UNION ALL
SELECT
    'Units Picked',
    COUNT_BIG(*),
    SUM(UnitsCompleted),
    MIN(EventDate),
    MAX(EventDate)
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
  AND EventDate >= @RecentStart
UNION ALL
SELECT
    'Distinct SKUs Picked',
    COUNT_BIG(*),
    COUNT(DISTINCT p.Sku),
    MIN(CAST(COALESCE(p.PickCompleteDate, p.[TimeStamp]) AS date)),
    MAX(CAST(COALESCE(p.PickCompleteDate, p.[TimeStamp]) AS date))
FROM dbo.Pick p
WHERE p.Sku IS NOT NULL
  AND p.[User] IS NOT NULL
  AND COALESCE(p.PickCompleteDate, p.[TimeStamp]) IS NOT NULL
  AND COALESCE(p.ActualPickQuantity, 0) >= COALESCE(p.RequiredPickQuantity, 0)
  AND CAST(COALESCE(p.PickCompleteDate, p.[TimeStamp]) AS date) >= @RecentStart;

INSERT INTO #MetricChecks (
    PageName,
    MetricName,
    SourceRows,
    ReportRows,
    SourceValue,
    ReportValue,
    SourceMinDate,
    SourceMaxDate,
    ReportMinDate,
    ReportMaxDate,
    Status,
    Details
)
SELECT
    'Daily KPI Summary Report',
    e.MetricName,
    COALESCE(e.SourceRows, 0),
    COUNT_BIG(k.SourceName),
    COALESCE(e.SourceValue, 0),
    COALESCE(SUM(CASE WHEN k.[Date] >= @RecentStart THEN k.MetricValue ELSE 0 END), 0),
    e.SourceMinDate,
    e.SourceMaxDate,
    MIN(CASE WHEN k.[Date] >= @RecentStart THEN k.[Date] END),
    MAX(CASE WHEN k.[Date] >= @RecentStart THEN k.[Date] END),
    CASE
        WHEN COALESCE(e.SourceRows, 0) = 0 THEN 'WARN'
        WHEN COUNT_BIG(CASE WHEN k.[Date] >= @RecentStart THEN 1 END) = 0 THEN 'FAIL'
        WHEN COALESCE(SUM(CASE WHEN k.[Date] >= @RecentStart THEN k.MetricValue ELSE 0 END), 0) = 0
         AND COALESCE(e.SourceValue, 0) > 0 THEN 'FAIL'
        ELSE 'PASS'
    END,
    CONCAT('Recent window starts ', CONVERT(varchar(10), @RecentStart, 120), '.')
FROM #DailyExpected e
LEFT JOIN #DailyKpi k
    ON k.SourceName = e.MetricName
GROUP BY
    e.MetricName,
    e.SourceRows,
    e.SourceValue,
    e.SourceMinDate,
    e.SourceMaxDate;

IF OBJECT_ID('tempdb..#ExpectedPickDaily') IS NOT NULL DROP TABLE #ExpectedPickDaily;
SELECT
    EventDate AS [Date],
    SUM(OrdersCompleted) AS OrdersCompleted,
    SUM(LinesCompleted) AS LinesCompleted,
    SUM(UnitsCompleted) AS UnitsCompleted,
    SUM(BinPresentationsCompleted) AS BinPresentationsCompleted
INTO #ExpectedPickDaily
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
GROUP BY EventDate;

;WITH ProductivePickRows AS (
    SELECT
        d.*,
        CAST(
            COALESCE(d.OrdersCompleted, 0)
            + COALESCE(d.BinPresentationsCompleted, 0)
            + COALESCE(d.LinesCompleted, 0)
            + COALESCE(d.UnitsCompleted, 0)
            + COALESCE(d.MachineWaitMinutes, 0)
            + COALESCE(d.ActiveHandleMinutes, 0)
            + COALESCE(d.TotalLoggedMinutes, 0)
            + COALESCE(d.RateDenominatorHours, 0)
            AS decimal(19, 4)
        ) AS ProductivityActivityBasis
    FROM dbo.v_ProductivityDailyUserPortWorkType_v2 d
    WHERE d.WorkType = 'Pick'
)
INSERT INTO #MetricChecks
SELECT
    'Productivity by User / Port',
    metric.MetricName,
    COUNT_BIG(*),
    COUNT_BIG(CASE WHEN EventDate >= @RecentStart THEN 1 END),
    SUM(metric.SourceBasis),
    SUM(CASE WHEN EventDate >= @RecentStart THEN metric.MetricValue ELSE 0 END),
    MIN(EventDate),
    MAX(EventDate),
    MIN(CASE WHEN EventDate >= @RecentStart THEN EventDate END),
    MAX(CASE WHEN EventDate >= @RecentStart THEN EventDate END),
    CASE
        WHEN COUNT_BIG(*) = 0 THEN 'WARN'
        WHEN COUNT_BIG(CASE WHEN EventDate >= @RecentStart THEN 1 END) = 0 THEN 'WARN'
        WHEN metric.RequirePositiveWhenSourcePositive = 1
         AND SUM(CASE WHEN EventDate >= @RecentStart THEN COALESCE(metric.SourceBasis, 0) ELSE 0 END) > 0
         AND COALESCE(SUM(CASE WHEN EventDate >= @RecentStart THEN metric.MetricValue ELSE 0 END), 0) = 0 THEN 'FAIL'
        WHEN COALESCE(SUM(CASE WHEN EventDate >= @RecentStart THEN metric.MetricValue ELSE 0 END), 0) = 0 THEN 'WARN'
        ELSE 'PASS'
    END,
    'Visible user/port productivity measures are compared only for positive pick-activity rows; zero-activity rows are hidden by PBIX measures.'
FROM ProductivePickRows d
CROSS APPLY (VALUES
    ('Orders Completed', CAST(d.OrdersCompleted AS decimal(19, 4)), CAST(d.OrdersCompleted AS decimal(19, 4)), 1),
    ('Bin Presentations Completed', CAST(d.BinPresentationsCompleted AS decimal(19, 4)), CAST(d.BinPresentationsCompleted AS decimal(19, 4)), 1),
    ('Lines Completed', CAST(d.LinesCompleted AS decimal(19, 4)), CAST(d.LinesCompleted AS decimal(19, 4)), 1),
    ('Units Completed', CAST(d.UnitsCompleted AS decimal(19, 4)), CAST(d.UnitsCompleted AS decimal(19, 4)), 1),
    ('Orders/hr', CASE WHEN d.RateDenominatorHours > 0 THEN CAST(d.OrdersCompleted / d.RateDenominatorHours AS decimal(19, 4)) ELSE NULL END, CAST(d.OrdersCompleted AS decimal(19, 4)), 1),
    ('Bins/hr', CASE WHEN d.RateDenominatorHours > 0 THEN CAST(d.BinPresentationsCompleted / d.RateDenominatorHours AS decimal(19, 4)) ELSE NULL END, CAST(d.BinPresentationsCompleted AS decimal(19, 4)), 1),
    ('Units/hr', CASE WHEN d.RateDenominatorHours > 0 THEN CAST(d.UnitsCompleted / d.RateDenominatorHours AS decimal(19, 4)) ELSE NULL END, CAST(d.UnitsCompleted AS decimal(19, 4)), 1),
    ('Lines/hr', CASE WHEN d.RateDenominatorHours > 0 THEN CAST(d.LinesCompleted / d.RateDenominatorHours AS decimal(19, 4)) ELSE NULL END, CAST(d.LinesCompleted AS decimal(19, 4)), 1),
    ('Machine Wait Minutes', CAST(d.MachineWaitMinutes AS decimal(19, 4)), CAST(d.EventRows AS decimal(19, 4)), 0),
    ('Average Handle Minutes/Presentation', CASE WHEN d.BinPresentationsCompleted > 0 THEN CAST(d.ActiveHandleMinutes / d.BinPresentationsCompleted AS decimal(19, 4)) ELSE NULL END, CAST(d.BinPresentationsCompleted AS decimal(19, 4)), 0),
    ('Total Logged Minutes', CAST(d.TotalLoggedMinutes AS decimal(19, 4)), CAST(d.EventRows AS decimal(19, 4)), 0),
    ('Rate Denominator Hours', CAST(d.RateDenominatorHours AS decimal(19, 4)), CAST(COALESCE(d.OrdersCompleted, 0) + COALESCE(d.BinPresentationsCompleted, 0) + COALESCE(d.LinesCompleted, 0) + COALESCE(d.UnitsCompleted, 0) AS decimal(19, 4)), 1)
) metric(MetricName, MetricValue, SourceBasis, RequirePositiveWhenSourcePositive)
WHERE d.ProductivityActivityBasis > 0
GROUP BY metric.MetricName, metric.RequirePositiveWhenSourcePositive;

INSERT INTO #MetricChecks
SELECT
    'Throughput',
    metric.MetricName,
    COUNT_BIG(CASE WHEN e.[Date] >= @RecentStart THEN 1 END),
    COUNT_BIG(CASE WHEN t.[Date] >= @RecentStart THEN 1 END),
    SUM(CASE WHEN e.[Date] >= @RecentStart THEN metric.ExpectedValue ELSE 0 END),
    SUM(CASE WHEN t.[Date] >= @RecentStart THEN metric.ReportValue ELSE 0 END),
    MIN(CASE WHEN e.[Date] >= @RecentStart THEN e.[Date] END),
    MAX(CASE WHEN e.[Date] >= @RecentStart THEN e.[Date] END),
    MIN(CASE WHEN t.[Date] >= @RecentStart THEN t.[Date] END),
    MAX(CASE WHEN t.[Date] >= @RecentStart THEN t.[Date] END),
    CASE
        WHEN SUM(CASE WHEN e.[Date] >= @RecentStart THEN metric.ExpectedValue ELSE 0 END) > 0
         AND SUM(CASE WHEN t.[Date] >= @RecentStart THEN metric.ReportValue ELSE 0 END) = 0 THEN 'FAIL'
        WHEN ABS(SUM(CASE WHEN e.[Date] >= @RecentStart THEN metric.ExpectedValue ELSE 0 END)
               - SUM(CASE WHEN t.[Date] >= @RecentStart THEN metric.ReportValue ELSE 0 END)) > 0 THEN 'FAIL'
        ELSE 'PASS'
    END,
    'Throughput metrics should match the same daily productivity grain as Productivity.'
FROM #ExpectedPickDaily e
FULL OUTER JOIN (
    SELECT
        [Date],
        SUM(OrdersCompleted) AS OrdersCompleted,
        SUM(LinesCompleted) AS LinesCompleted,
        SUM(BinPresentationsCompleted) AS BinPresentationsCompleted
    FROM dbo.Throughput
    GROUP BY [Date]
) t
    ON t.[Date] = e.[Date]
CROSS APPLY (VALUES
    ('Orders', CAST(COALESCE(e.OrdersCompleted, 0) AS decimal(19, 4)), CAST(COALESCE(t.OrdersCompleted, 0) AS decimal(19, 4))),
    ('Lines', CAST(COALESCE(e.LinesCompleted, 0) AS decimal(19, 4)), CAST(COALESCE(t.LinesCompleted, 0) AS decimal(19, 4))),
    ('Bins', CAST(COALESCE(e.BinPresentationsCompleted, 0) AS decimal(19, 4)), CAST(COALESCE(t.BinPresentationsCompleted, 0) AS decimal(19, 4)))
) metric(MetricName, ExpectedValue, ReportValue)
GROUP BY metric.MetricName;

INSERT INTO #MetricChecks
SELECT
    'Historical Dashboard',
    metric.MetricName,
    COUNT_BIG(CASE WHEN e.[Date] >= @HistoryStart THEN 1 END),
    COUNT_BIG(CASE WHEN h.[Date] >= @HistoryStart THEN 1 END),
    SUM(CASE WHEN e.[Date] >= @HistoryStart THEN metric.ExpectedValue ELSE 0 END),
    SUM(CASE WHEN h.[Date] >= @HistoryStart THEN metric.ReportValue ELSE 0 END),
    MIN(CASE WHEN e.[Date] >= @HistoryStart THEN e.[Date] END),
    MAX(CASE WHEN e.[Date] >= @HistoryStart THEN e.[Date] END),
    MIN(CASE WHEN h.[Date] >= @HistoryStart THEN h.[Date] END),
    MAX(CASE WHEN h.[Date] >= @HistoryStart THEN h.[Date] END),
    CASE
        WHEN SUM(CASE WHEN e.[Date] >= @HistoryStart THEN metric.ExpectedValue ELSE 0 END) > 0
         AND SUM(CASE WHEN h.[Date] >= @HistoryStart THEN metric.ReportValue ELSE 0 END) = 0 THEN 'FAIL'
        WHEN ABS(SUM(CASE WHEN e.[Date] >= @HistoryStart THEN metric.ExpectedValue ELSE 0 END)
               - SUM(CASE WHEN h.[Date] >= @HistoryStart THEN metric.ReportValue ELSE 0 END)) > 0 THEN 'FAIL'
        ELSE 'PASS'
    END,
    'Historical views should match the same productivity daily grain over 30 days.'
FROM #ExpectedPickDaily e
FULL OUTER JOIN (
    SELECT
        COALESCE(o.[Date], l.[Date], u.[Date], b.[Date]) AS [Date],
        COALESCE(o.OrdersCompleted, 0) AS OrdersCompleted,
        COALESCE(l.LinesCompleted, 0) AS LinesCompleted,
        COALESCE(u.UnitsPicked, 0) AS UnitsCompleted,
        COALESCE(b.BinPresented, 0) AS BinPresentationsCompleted
    FROM dbo.OrdersCompletedHD o
    FULL OUTER JOIN dbo.LinesCompletedHD l ON l.[Date] = o.[Date]
    FULL OUTER JOIN dbo.UnitsPickedHD u ON u.[Date] = COALESCE(o.[Date], l.[Date])
    FULL OUTER JOIN dbo.BinPresentedHD b ON b.[Date] = COALESCE(o.[Date], l.[Date], u.[Date])
) h
    ON h.[Date] = e.[Date]
CROSS APPLY (VALUES
    ('Orders Completed', CAST(COALESCE(e.OrdersCompleted, 0) AS decimal(19, 4)), CAST(COALESCE(h.OrdersCompleted, 0) AS decimal(19, 4))),
    ('Lines Completed', CAST(COALESCE(e.LinesCompleted, 0) AS decimal(19, 4)), CAST(COALESCE(h.LinesCompleted, 0) AS decimal(19, 4))),
    ('Units Picked', CAST(COALESCE(e.UnitsCompleted, 0) AS decimal(19, 4)), CAST(COALESCE(h.UnitsCompleted, 0) AS decimal(19, 4))),
    ('Bin Presentations', CAST(COALESCE(e.BinPresentationsCompleted, 0) AS decimal(19, 4)), CAST(COALESCE(h.BinPresentationsCompleted, 0) AS decimal(19, 4)))
) metric(MetricName, ExpectedValue, ReportValue)
GROUP BY metric.MetricName;

WITH LatestIds AS (
    SELECT
        (SELECT MAX(Snapshot_Id) FROM dbo.Inventory) AS InventorySnapshotId,
        (SELECT MAX(Snapshot_Id) FROM dbo.Containers) AS ContainerSnapshotId,
        (SELECT MAX(Snapshot_Id) FROM dbo.ContainerTemplates) AS TemplateSnapshotId,
        (SELECT MAX(Snapshot_Id) FROM dbo.CompartmentSizes) AS CompartmentSizeSnapshotId
),
TemplateCompartments AS (
    SELECT DISTINCT
        ct.PrimaryKey AS TemplatePrimaryKey,
        CONCAT(
            cs.Name,
            ' (',
            NULLIF(LTRIM(RTRIM(REPLACE(ct.TemplateName, 'Autostore ', ''))), ''),
            ')'
        ) AS CompartmentLabel,
        ctc.ContainerSide,
        ctc.XPosition,
        ctc.YPosition
    FROM LatestIds ids
    INNER JOIN dbo.ContainerTemplates ct
        ON ct.Snapshot_Id = ids.TemplateSnapshotId
    INNER JOIN dbo.ContainerTemplateCompartments ctc
        ON ctc.TemplatePrimaryKey = ct.PrimaryKey
    INNER JOIN dbo.CompartmentSizes cs
        ON cs.PrimaryKey = ctc.CompartmentSizePrimaryKey
       AND cs.Snapshot_Id = ids.CompartmentSizeSnapshotId
    WHERE ct.IsGoodsToPerson = 1
      AND NULLIF(ct.TemplateName, '') IS NOT NULL
      AND NULLIF(cs.Name, '') IS NOT NULL
),
ContainerCompartments AS (
    SELECT
        tc.CompartmentLabel,
        c.PrimaryKey AS ContainerPrimaryKey,
        tc.ContainerSide,
        tc.XPosition,
        tc.YPosition
    FROM LatestIds ids
    INNER JOIN TemplateCompartments tc
        ON 1 = 1
    INNER JOIN dbo.Containers c
        ON c.TemplatePrimaryKey = tc.TemplatePrimaryKey
       AND c.Snapshot_Id = ids.ContainerSnapshotId
    WHERE COALESCE(c.Status, '') <> 'Outside'
),
ExpectedInventoryMetrics AS (
    SELECT MetricName
    FROM (VALUES
        ('Total Bin(s) w/ Inventory'),
        ('Total Bin(s) w/ No Inventory'),
        ('Total Bin(s)'),
        ('% of Bin(s) w/ Inventory'),
        ('% of Bin(s) w/ No Inventory'),
        ('% of Total Bin(s)'),
        ('Total Locations Occupied'),
        ('Total Locations Empty'),
        ('Total Locations'),
        ('% Locations Occupied'),
        ('% Locations Empty'),
        ('Distinct SKUs Stocked'),
        ('Units Stocked'),
        ('% Units Stocked'),
        ('Avg Units Stocked Per Location'),
        ('Avg Units Stocked per Bin(s)'),
        ('Avg Units Stocked per SKU'),
        ('Avg Locations Stocked per SKU')
    ) v(MetricName)
),
SourceSummary AS (
    SELECT
        (SELECT COUNT_BIG(*) FROM dbo.Inventory i CROSS JOIN LatestIds ids WHERE i.Snapshot_Id = ids.InventorySnapshotId) AS InventoryRows,
        (SELECT COUNT(DISTINCT CompartmentLabel) FROM TemplateCompartments) AS ExpectedCompartmentLabels,
        (SELECT COUNT_BIG(*) FROM ContainerCompartments) AS ExpectedTotalLocations,
        (SELECT COUNT(DISTINCT CompartmentLabel) FROM TemplateCompartments) * 18 AS ExpectedMetricRows
),
ReportSummary AS (
    SELECT
        COUNT_BIG(*) AS ReportRows,
        COUNT(DISTINCT CompartmentLabel) AS ReportCompartmentLabels,
        COUNT(DISTINCT MetricName) AS ReportMetricNames,
        SUM(CASE
            WHEN MetricName = 'Total Locations'
                THEN COALESCE(TRY_CONVERT(decimal(19, 4), REPLACE(MetricValue, ',', '')), 0)
            ELSE 0
        END) AS ReportTotalLocations
    FROM dbo.InventoryAndLocationSummary
),
ReportCompletenessSummary AS (
    SELECT
        COALESCE(SUM(CASE WHEN agg.[RowCount] IS NULL THEN 1 ELSE 0 END), 0) AS MissingMetricInstances,
        COALESCE(SUM(CASE WHEN agg.[RowCount] > 1 THEN agg.[RowCount] - 1 ELSE 0 END), 0) AS DuplicateMetricRows
    FROM (SELECT DISTINCT CompartmentLabel FROM TemplateCompartments) labels
    CROSS JOIN ExpectedInventoryMetrics expected
    LEFT JOIN (
        SELECT
            CompartmentLabel,
            MetricName,
            COUNT_BIG(*) AS [RowCount]
        FROM dbo.InventoryAndLocationSummary
        GROUP BY
            CompartmentLabel,
            MetricName
    ) agg
        ON agg.CompartmentLabel = labels.CompartmentLabel
       AND agg.MetricName = expected.MetricName
),
ReportUnexpectedSummary AS (
    SELECT
        COUNT_BIG(*) AS UnexpectedRows
    FROM dbo.InventoryAndLocationSummary report
    LEFT JOIN (SELECT DISTINCT CompartmentLabel FROM TemplateCompartments) labels
        ON labels.CompartmentLabel = report.CompartmentLabel
    LEFT JOIN ExpectedInventoryMetrics expected
        ON expected.MetricName = report.MetricName
    WHERE labels.CompartmentLabel IS NULL
       OR expected.MetricName IS NULL
),
ReportPercentSummary AS (
    SELECT
        SUM(COALESCE(TRY_CONVERT(decimal(19, 4), REPLACE(REPLACE(MetricValue, '%', ''), ',', '')), 0)) AS PercentOfTotalBinsSum
    FROM dbo.InventoryAndLocationSummary
    WHERE MetricName = '% of Total Bin(s)'
)
INSERT INTO #MetricChecks
SELECT
    'Inventory & Location Table Summary',
    'Inventory/location matrix metrics',
    s.ExpectedMetricRows,
    r.ReportRows,
    CAST(s.ExpectedTotalLocations AS decimal(19, 4)),
    CAST(COALESCE(r.ReportTotalLocations, 0) AS decimal(19, 4)),
    NULL,
    NULL,
    NULL,
    NULL,
    CASE
        WHEN s.InventoryRows > 0 AND s.ExpectedCompartmentLabels = 0 THEN 'FAIL'
        WHEN s.ExpectedMetricRows > 0 AND r.ReportRows <> s.ExpectedMetricRows THEN 'FAIL'
        WHEN s.ExpectedCompartmentLabels > 0 AND r.ReportCompartmentLabels <> s.ExpectedCompartmentLabels THEN 'FAIL'
        WHEN s.ExpectedMetricRows > 0 AND r.ReportMetricNames < 18 THEN 'FAIL'
        WHEN COALESCE(c.MissingMetricInstances, 0) > 0 THEN 'FAIL'
        WHEN COALESCE(c.DuplicateMetricRows, 0) > 0 THEN 'FAIL'
        WHEN COALESCE(u.UnexpectedRows, 0) > 0 THEN 'FAIL'
        WHEN s.ExpectedTotalLocations <> COALESCE(r.ReportTotalLocations, 0) THEN 'FAIL'
        WHEN s.ExpectedCompartmentLabels > 1 AND ABS(COALESCE(p.PercentOfTotalBinsSum, 0) - 100.0) > 0.5 THEN 'FAIL'
        ELSE 'PASS'
    END,
    CONCAT(
        'Expected labels: ', s.ExpectedCompartmentLabels,
        '; report labels: ', r.ReportCompartmentLabels,
        '; expected metric rows: ', s.ExpectedMetricRows,
        '; report rows: ', r.ReportRows,
        '; expected total locations: ', s.ExpectedTotalLocations,
        '; report total locations: ', COALESCE(r.ReportTotalLocations, 0),
        '; missing metric instances: ', COALESCE(c.MissingMetricInstances, 0),
        '; duplicate metric rows: ', COALESCE(c.DuplicateMetricRows, 0),
        '; unexpected rows: ', COALESCE(u.UnexpectedRows, 0),
        '; % total bins sum: ', COALESCE(p.PercentOfTotalBinsSum, 0),
        '.'
    )
FROM SourceSummary s
CROSS JOIN ReportSummary r
CROSS JOIN ReportCompletenessSummary c
CROSS JOIN ReportUnexpectedSummary u
CROSS JOIN ReportPercentSummary p;

WITH OpenWork AS (
    SELECT 'Orders Pick' AS MetricName, COUNT_BIG(*) AS SourceRows, MIN(CAST(LastUpdatedDate AS date)) AS MinDate, MAX(CAST(LastUpdatedDate AS date)) AS MaxDate
    FROM dbo.FulfillmentOrders
    WHERE LOWER(Status) IN ('allocated', 'allocating', 'active', 'batched', 'new', 'released', 'importing', 'falied allocation', 'failed allocation', 'shorted')
    UNION ALL
    SELECT 'Lines Pick', COUNT_BIG(*), MIN(CAST(LastUpdatedDate AS date)), MAX(CAST(LastUpdatedDate AS date))
    FROM dbo.FulfillmentOrderLines
    WHERE LOWER(Status) IN ('active', 'allocated', 'allocating', 'new', 'pending')
    UNION ALL
    SELECT 'Orders Put', COUNT_BIG(*), MIN(CAST(LastUpdatedDate AS date)), MAX(CAST(LastUpdatedDate AS date))
    FROM dbo.PutAwayContainers
    WHERE IsClosed = 0
    UNION ALL
    SELECT 'Lines Put', COUNT_BIG(*), MIN(CAST(li.LastUpdatedDate AS date)), MAX(CAST(li.LastUpdatedDate AS date))
    FROM dbo.PutAwayContainerLineItems li
    INNER JOIN dbo.PutAwayContainers c
        ON c.PrimaryKey = li.PutAwayContainerPrimaryKey
    WHERE c.IsClosed = 0
      AND COALESCE(li.ActualQuantity, 0) + COALESCE(li.MissingQuantity, 0) < COALESCE(li.Quantity, 0)
    UNION ALL
    SELECT 'Orders Cycle Count', COUNT_BIG(DISTINCT t.TaskGroupPrimaryKey), MIN(CAST(t.LastUpdatedDate AS date)), MAX(CAST(t.LastUpdatedDate AS date))
    FROM dbo.InventoryTasks_CycleCount cc
    INNER JOIN dbo.InventoryTasks t
        ON t.PrimaryKey = cc.InventoryTaskPrimaryKey
    WHERE t.IsClosed = 0
    UNION ALL
    SELECT 'Lines Cycle Count', COUNT_BIG(*), MIN(CAST(t.LastUpdatedDate AS date)), MAX(CAST(t.LastUpdatedDate AS date))
    FROM dbo.InventoryTasks_CycleCount cc
    INNER JOIN dbo.InventoryTasks t
        ON t.PrimaryKey = cc.InventoryTaskPrimaryKey
    WHERE t.IsClosed = 0
)
INSERT INTO #MetricChecks
SELECT
    'Open Work History',
    MetricName,
    SourceRows,
    SourceRows,
    CAST(SourceRows AS decimal(19, 4)),
    CAST(SourceRows AS decimal(19, 4)),
    MinDate,
    MaxDate,
    MinDate,
    MaxDate,
    CASE WHEN SourceRows = 0 THEN 'WARN' ELSE 'PASS' END,
    'Zero can be valid if no work is currently open.'
FROM OpenWork;

DECLARE @ConsolidationSourceRows bigint = NULL;
DECLARE @ConsolidationSourceQuantity decimal(19, 4) = NULL;
DECLARE @ConsolidationSourceSummary TABLE (
    [Rows] bigint NULL,
    QuantityValue decimal(19, 4) NULL
);

IF OBJECT_ID(N'KFX_AUTOSTORE.dbo.DefragDetailByUomCompartmentSizeView', N'V') IS NOT NULL
BEGIN
    INSERT INTO @ConsolidationSourceSummary ([Rows], QuantityValue)
    EXEC sys.sp_executesql N'
        SELECT
            COUNT_BIG(*) AS [Rows],
            SUM(COALESCE(TRY_CONVERT(decimal(19, 4), Quantity), 0)) AS QuantityValue
        FROM KFX_AUTOSTORE.dbo.DefragDetailByUomCompartmentSizeView;';

    SELECT
        @ConsolidationSourceRows = [Rows],
        @ConsolidationSourceQuantity = QuantityValue
    FROM @ConsolidationSourceSummary;
END;

;WITH ConsolidationSummary AS (
    SELECT
        COUNT_BIG(*) AS ReportRows,
        SUM(COALESCE(TRY_CONVERT(decimal(19, 4), Quantity), 0)) AS QuantityValue,
        COALESCE(SUM(CASE
            WHEN NULLIF(Sku, '') IS NULL
              OR NULLIF(CompartmentSizeName, '') IS NULL
              OR Quantity IS NULL THEN 1 ELSE 0
        END), 0) AS MissingDisplayRows,
        COALESCE(SUM(CASE
            WHEN TotalCompartments IS NULL
              OR TotalUnrealizedCapacity IS NULL THEN 1 ELSE 0
        END), 0) AS MissingOptionalMetricRows,
        COALESCE(SUM(CASE
            WHEN TRY_CONVERT(decimal(19, 4), Quantity) < 0
              OR TRY_CONVERT(decimal(19, 4), TotalCompartments) < 0
              OR TRY_CONVERT(decimal(19, 4), TotalUnrealizedCapacity) < 0 THEN 1 ELSE 0
        END), 0) AS NegativeValueRows,
        COALESCE(SUM(CASE
            WHEN Quantity IS NOT NULL
              AND TotalUnrealizedCapacity IS NOT NULL
              AND TRY_CONVERT(decimal(19, 4), TotalUnrealizedCapacity) + TRY_CONVERT(decimal(19, 4), Quantity) <= 0 THEN 1 ELSE 0
        END), 0) AS BadFragmentationDenominatorRows,
        COALESCE(SUM(CASE
            WHEN Quantity IS NOT NULL
              AND TotalUnrealizedCapacity IS NOT NULL
              AND NULLIF(TRY_CONVERT(decimal(19, 4), TotalUnrealizedCapacity) + TRY_CONVERT(decimal(19, 4), Quantity), 0) IS NOT NULL
              AND TRY_CONVERT(decimal(19, 4), TotalUnrealizedCapacity)
                    / NULLIF(TRY_CONVERT(decimal(19, 4), TotalUnrealizedCapacity) + TRY_CONVERT(decimal(19, 4), Quantity), 0) NOT BETWEEN 0 AND 1 THEN 1 ELSE 0
        END), 0) AS BadFragmentationRows
    FROM dbo.DefragDetailByUomCompartmentSize_Table
)
INSERT INTO #MetricChecks
SELECT
    'Consolidation Report',
    'Consolidation rows',
    @ConsolidationSourceRows,
    ReportRows,
    @ConsolidationSourceQuantity,
    QuantityValue,
    NULL,
    NULL,
    NULL,
    NULL,
    CASE
        WHEN MissingDisplayRows > 0
          OR NegativeValueRows > 0
          OR BadFragmentationDenominatorRows > 0
          OR BadFragmentationRows > 0 THEN 'FAIL'
        WHEN @ConsolidationSourceRows > 0 AND ReportRows = 0 THEN 'FAIL'
        WHEN @ConsolidationSourceRows IS NULL THEN 'WARN'
        WHEN ReportRows = 0 THEN 'WARN'
        WHEN MissingOptionalMetricRows > 0 THEN 'WARN'
        ELSE 'PASS'
    END,
    CONCAT(
        'Zero rows can mean no current consolidation candidates only when source rows are also zero. Source rows: ',
        COALESCE(CONVERT(varchar(30), @ConsolidationSourceRows), 'unavailable'),
        '; report rows: ', ReportRows,
        '; missing display rows: ', MissingDisplayRows,
        '; missing optional metric rows: ', MissingOptionalMetricRows,
        '; negative value rows: ', NegativeValueRows,
        '; bad fragmentation denominators: ', BadFragmentationDenominatorRows,
        '; bad fragmentation rows: ', BadFragmentationRows,
        '.'
    )
FROM ConsolidationSummary;

SELECT
    @RecentStart AS RecentDefaultStart,
    @HistoryStart AS HistoricalDefaultStart,
    @Today AS RunDate;

SELECT
    CASE WHEN SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) = 0 THEN 'PASS' ELSE 'FAIL' END AS VisibleMetricsValidationGate,
    SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) AS FailedChecks,
    SUM(CASE WHEN Status = 'WARN' THEN 1 ELSE 0 END) AS WarningChecks,
    COUNT(*) AS TotalChecks
FROM #MetricChecks;

SELECT
    PageName,
    MetricName,
    SourceRows,
    ReportRows,
    SourceValue,
    ReportValue,
    SourceMinDate,
    SourceMaxDate,
    ReportMinDate,
    ReportMaxDate,
    Status,
    Details
FROM #MetricChecks
ORDER BY
    CASE Status WHEN 'FAIL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END,
    PageName,
    MetricName;
