USE [KFX_REPORTING];
GO

SET NOCOUNT ON;

/*
    Validation for patch-reporting-supervisor-page-views-v4.5.0.sql.

    Expected result:
      SupervisorPageValidationGate = PASS
      FailedChecks = 0
*/

IF OBJECT_ID('tempdb..#ExpectedDaily') IS NOT NULL DROP TABLE #ExpectedDaily;
IF OBJECT_ID('tempdb..#HistoricalActual') IS NOT NULL DROP TABLE #HistoricalActual;
IF OBJECT_ID('tempdb..#ThroughputActual') IS NOT NULL DROP TABLE #ThroughputActual;
IF OBJECT_ID('tempdb..#DailyKpiPickingActual') IS NOT NULL DROP TABLE #DailyKpiPickingActual;
IF OBJECT_ID('tempdb..#ScoredChecks') IS NOT NULL DROP TABLE #ScoredChecks;

WITH ExpectedCounts AS (
    SELECT
        EventDate AS [Date],
        CAST(SUM(OrdersCompleted) AS bigint) AS OrdersCompleted,
        CAST(SUM(LinesCompleted) AS bigint) AS LinesCompleted,
        CAST(SUM(UnitsCompleted) AS bigint) AS UnitsPicked,
        CAST(SUM(BinPresentationsCompleted) AS bigint) AS BinPresented
    FROM dbo.v_ProductivityDailyUserPortWorkType_v2
    WHERE WorkType = 'Pick'
    GROUP BY EventDate
),
ExpectedSkus AS (
    SELECT
        CAST(COALESCE(p.PickCompleteDate, p.[TimeStamp]) AS date) AS [Date],
        CAST(COUNT(DISTINCT p.Sku) AS bigint) AS DistinctSkusPicked
FROM dbo.Pick p
WHERE p.Sku IS NOT NULL
  AND p.[User] IS NOT NULL
  AND COALESCE(p.PickCompleteDate, p.[TimeStamp]) IS NOT NULL
  AND COALESCE(p.ActualPickQuantity, 0) >= COALESCE(p.RequiredPickQuantity, 0)
GROUP BY CAST(COALESCE(p.PickCompleteDate, p.[TimeStamp]) AS date)
)
SELECT
    COALESCE(c.[Date], s.[Date]) AS [Date],
    COALESCE(c.OrdersCompleted, 0) AS OrdersCompleted,
    COALESCE(c.LinesCompleted, 0) AS LinesCompleted,
    COALESCE(c.UnitsPicked, 0) AS UnitsPicked,
    COALESCE(c.BinPresented, 0) AS BinPresented,
    COALESCE(s.DistinctSkusPicked, 0) AS DistinctSkusPicked
INTO #ExpectedDaily
FROM ExpectedCounts c
FULL OUTER JOIN ExpectedSkus s
    ON s.[Date] = c.[Date];

SELECT
    [Date],
    CAST(SUM(OrdersCompleted) AS bigint) AS OrdersCompleted,
    CAST(SUM(LinesCompleted) AS bigint) AS LinesCompleted,
    CAST(SUM(UnitsPicked) AS bigint) AS UnitsPicked,
    CAST(SUM(BinPresented) AS bigint) AS BinPresented
INTO #HistoricalActual
FROM (
    SELECT [Date], OrdersCompleted, CAST(0 AS bigint) AS LinesCompleted, CAST(0 AS bigint) AS UnitsPicked, CAST(0 AS bigint) AS BinPresented
    FROM dbo.OrdersCompletedHD
    UNION ALL
    SELECT [Date], 0, LinesCompleted, 0, 0
    FROM dbo.LinesCompletedHD
    UNION ALL
    SELECT [Date], 0, 0, UnitsPicked, 0
    FROM dbo.UnitsPickedHD
    UNION ALL
    SELECT [Date], 0, 0, 0, BinPresented
    FROM dbo.BinPresentedHD
) x
GROUP BY [Date];

SELECT
    [Date],
    CAST(SUM(OrdersCompleted) AS bigint) AS OrdersCompleted,
    CAST(SUM(LinesCompleted) AS bigint) AS LinesCompleted,
    CAST(SUM(BinPresentationsCompleted) AS bigint) AS BinPresented
INTO #ThroughputActual
FROM dbo.Throughput
GROUP BY [Date];

SELECT
    [Date],
    CAST(SUM(OrdersCompleted) AS bigint) AS OrdersCompleted,
    CAST(SUM(LinesCompleted) AS bigint) AS LinesCompleted,
    CAST(SUM(UnitsPicked) AS bigint) AS UnitsPicked,
    CAST(SUM(DistinctSkusPicked) AS bigint) AS DistinctSkusPicked
INTO #DailyKpiPickingActual
FROM (
    SELECT [Date], [Customer Orders Picked] AS OrdersCompleted, CAST(0 AS bigint) AS LinesCompleted, CAST(0 AS bigint) AS UnitsPicked, CAST(0 AS bigint) AS DistinctSkusPicked
    FROM dbo.Customer_Orders_Picked
    UNION ALL
    SELECT [Date], 0, [Customer Order Lines], 0, 0
    FROM dbo.Customer_Order_Lines
    UNION ALL
    SELECT [Date], 0, 0, [Units Picked], 0
    FROM dbo.Units_Picked
    UNION ALL
    SELECT [Date], 0, 0, 0, [Distinct Skus Picked]
    FROM dbo.Distinct_Skus_Picked
) x
GROUP BY [Date];

SELECT
    CheckName,
    COALESCE(Difference, 0) AS Difference,
    COALESCE(MismatchDates, 0) AS MismatchDates,
    CASE
        WHEN COALESCE(Difference, 0) = 0
         AND COALESCE(MismatchDates, 0) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS Status
INTO #ScoredChecks
FROM (
    SELECT
        CAST('Historical orders match productivity daily grain' AS varchar(120)) AS CheckName,
        CAST(SUM(ABS(COALESCE(e.OrdersCompleted, 0) - COALESCE(a.OrdersCompleted, 0))) AS decimal(19, 3)) AS Difference,
        COUNT_BIG(CASE WHEN COALESCE(e.OrdersCompleted, 0) <> COALESCE(a.OrdersCompleted, 0) THEN 1 END) AS MismatchDates
    FROM #ExpectedDaily e
    FULL OUTER JOIN #HistoricalActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Historical lines match productivity daily grain',
        CAST(SUM(ABS(COALESCE(e.LinesCompleted, 0) - COALESCE(a.LinesCompleted, 0))) AS decimal(19, 3)),
        COUNT_BIG(CASE WHEN COALESCE(e.LinesCompleted, 0) <> COALESCE(a.LinesCompleted, 0) THEN 1 END)
    FROM #ExpectedDaily e
    FULL OUTER JOIN #HistoricalActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Historical units match productivity daily grain',
        CAST(SUM(ABS(COALESCE(e.UnitsPicked, 0) - COALESCE(a.UnitsPicked, 0))) AS decimal(19, 3)),
        COUNT_BIG(CASE WHEN COALESCE(e.UnitsPicked, 0) <> COALESCE(a.UnitsPicked, 0) THEN 1 END)
    FROM #ExpectedDaily e
    FULL OUTER JOIN #HistoricalActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Historical bins match productivity daily grain',
        CAST(SUM(ABS(COALESCE(e.BinPresented, 0) - COALESCE(a.BinPresented, 0))) AS decimal(19, 3)),
        COUNT_BIG(CASE WHEN COALESCE(e.BinPresented, 0) <> COALESCE(a.BinPresented, 0) THEN 1 END)
    FROM #ExpectedDaily e
    FULL OUTER JOIN #HistoricalActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Daily KPI picked orders match productivity daily grain',
        CAST(SUM(ABS(COALESCE(e.OrdersCompleted, 0) - COALESCE(a.OrdersCompleted, 0))) AS decimal(19, 3)),
        COUNT_BIG(CASE WHEN COALESCE(e.OrdersCompleted, 0) <> COALESCE(a.OrdersCompleted, 0) THEN 1 END)
    FROM #ExpectedDaily e
    FULL OUTER JOIN #DailyKpiPickingActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Daily KPI picked lines match productivity daily grain',
        CAST(SUM(ABS(COALESCE(e.LinesCompleted, 0) - COALESCE(a.LinesCompleted, 0))) AS decimal(19, 3)),
        COUNT_BIG(CASE WHEN COALESCE(e.LinesCompleted, 0) <> COALESCE(a.LinesCompleted, 0) THEN 1 END)
    FROM #ExpectedDaily e
    FULL OUTER JOIN #DailyKpiPickingActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Daily KPI picked units match productivity daily grain',
        CAST(SUM(ABS(COALESCE(e.UnitsPicked, 0) - COALESCE(a.UnitsPicked, 0))) AS decimal(19, 3)),
        COUNT_BIG(CASE WHEN COALESCE(e.UnitsPicked, 0) <> COALESCE(a.UnitsPicked, 0) THEN 1 END)
    FROM #ExpectedDaily e
    FULL OUTER JOIN #DailyKpiPickingActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Daily KPI distinct SKUs match completed pick rows',
        CAST(SUM(ABS(COALESCE(e.DistinctSkusPicked, 0) - COALESCE(a.DistinctSkusPicked, 0))) AS decimal(19, 3)),
        COUNT_BIG(CASE WHEN COALESCE(e.DistinctSkusPicked, 0) <> COALESCE(a.DistinctSkusPicked, 0) THEN 1 END)
    FROM #ExpectedDaily e
    FULL OUTER JOIN #DailyKpiPickingActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Throughput orders match productivity daily grain',
        CAST(SUM(ABS(COALESCE(e.OrdersCompleted, 0) - COALESCE(a.OrdersCompleted, 0))) AS decimal(19, 3)),
        COUNT_BIG(CASE WHEN COALESCE(e.OrdersCompleted, 0) <> COALESCE(a.OrdersCompleted, 0) THEN 1 END)
    FROM #ExpectedDaily e
    FULL OUTER JOIN #ThroughputActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Throughput lines match productivity daily grain',
        CAST(SUM(ABS(COALESCE(e.LinesCompleted, 0) - COALESCE(a.LinesCompleted, 0))) AS decimal(19, 3)),
        COUNT_BIG(CASE WHEN COALESCE(e.LinesCompleted, 0) <> COALESCE(a.LinesCompleted, 0) THEN 1 END)
    FROM #ExpectedDaily e
    FULL OUTER JOIN #ThroughputActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Throughput bins match productivity daily grain',
        CAST(SUM(ABS(COALESCE(e.BinPresented, 0) - COALESCE(a.BinPresented, 0))) AS decimal(19, 3)),
        COUNT_BIG(CASE WHEN COALESCE(e.BinPresented, 0) <> COALESCE(a.BinPresented, 0) THEN 1 END)
    FROM #ExpectedDaily e
    FULL OUTER JOIN #ThroughputActual a ON a.[Date] = e.[Date]
    UNION ALL
    SELECT
        'Throughput has no null report fields',
        CAST(COUNT_BIG(*) AS decimal(19, 3)),
        COUNT_BIG(*)
    FROM dbo.Throughput
    WHERE [Date] IS NULL
       OR NULLIF([Hour], '') IS NULL
       OR NULLIF(Ports, '') IS NULL
       OR NULLIF(OrderCategory, '') IS NULL
) Checks;

SELECT
    CASE WHEN SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) = 0 THEN 'PASS' ELSE 'FAIL' END AS SupervisorPageValidationGate,
    SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) AS FailedChecks,
    COUNT(*) AS TotalChecks
FROM #ScoredChecks;

SELECT
    CheckName,
    Difference,
    MismatchDates,
    Status
FROM #ScoredChecks
ORDER BY
    CASE WHEN Status = 'FAIL' THEN 0 ELSE 1 END,
    CheckName;

SELECT
    'Expected productivity daily grain' AS SourceName,
    COUNT_BIG(*) AS Rows,
    MIN([Date]) AS MinDate,
    MAX([Date]) AS MaxDate,
    SUM(OrdersCompleted) AS OrdersCompleted,
    SUM(LinesCompleted) AS LinesCompleted,
    SUM(UnitsPicked) AS UnitsPicked,
    SUM(BinPresented) AS BinPresented,
    SUM(DistinctSkusPicked) AS DistinctSkusPicked
FROM #ExpectedDaily
UNION ALL
SELECT
    'Historical dashboard views',
    COUNT_BIG(*),
    MIN([Date]),
    MAX([Date]),
    SUM(OrdersCompleted),
    SUM(LinesCompleted),
    SUM(UnitsPicked),
    SUM(BinPresented),
    CAST(NULL AS bigint)
FROM #HistoricalActual
UNION ALL
SELECT
    'Daily KPI picking views',
    COUNT_BIG(*),
    MIN([Date]),
    MAX([Date]),
    SUM(OrdersCompleted),
    SUM(LinesCompleted),
    SUM(UnitsPicked),
    CAST(NULL AS bigint),
    SUM(DistinctSkusPicked)
FROM #DailyKpiPickingActual
UNION ALL
SELECT
    'Throughput page view',
    COUNT_BIG(*),
    MIN([Date]),
    MAX([Date]),
    SUM(OrdersCompleted),
    SUM(LinesCompleted),
    CAST(NULL AS bigint),
    SUM(BinPresented),
    CAST(NULL AS bigint)
FROM #ThroughputActual;
