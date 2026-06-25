USE [KFX_REPORTING];
GO

SET NOCOUNT ON;

/*
    Smoke validation for the Kardex supervisor report pages.

    Expected result:
      AllPagesSmokeGate = PASS
      FailedChecks = 0

    WARN rows are informational. They call out valid-but-worth-reviewing
    states such as no currently open work or no consolidation candidates.
*/

DECLARE @Today date = CAST(GETDATE() AS date);
DECLARE @RecentStart date = DATEADD(day, -7, @Today);
DECLARE @HistoryStart date = DATEADD(day, -30, @Today);

IF OBJECT_ID('tempdb..#PageSmoke') IS NOT NULL DROP TABLE #PageSmoke;
IF OBJECT_ID('tempdb..#DailyKpiMetrics') IS NOT NULL DROP TABLE #DailyKpiMetrics;
IF OBJECT_ID('tempdb..#HistoricalMetrics') IS NOT NULL DROP TABLE #HistoricalMetrics;
IF OBJECT_ID('tempdb..#OpenWorkSourceRows') IS NOT NULL DROP TABLE #OpenWorkSourceRows;

CREATE TABLE #PageSmoke (
    PageName varchar(100) NOT NULL,
    CheckName varchar(160) NOT NULL,
    [RowCount] bigint NULL,
    MinDate date NULL,
    MaxDate date NULL,
    IssueCount bigint NOT NULL,
    Status varchar(10) NOT NULL,
    Details varchar(4000) NULL
);

CREATE TABLE #DailyKpiMetrics (
    SourceName varchar(128) NOT NULL,
    [Date] date NULL,
    MetricValue decimal(19, 4) NULL
);

INSERT INTO #DailyKpiMetrics (SourceName, [Date], MetricValue)
SELECT 'Total_SKUs_On_Hand', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Totak SKUs On Hand]) FROM dbo.Total_SKUs_On_Hand
UNION ALL SELECT 'Total_Units_On_Hand', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Total Units On Hand]) FROM dbo.Total_Units_On_Hand
UNION ALL SELECT 'Total_Locations_Occupied', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Total Locations Occupied]) FROM dbo.Total_Locations_Occupied
UNION ALL SELECT 'Orders_Putaway', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Orders Putaway]) FROM dbo.Orders_Putaway
UNION ALL SELECT 'Units_Putaway', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Units Putaway]) FROM dbo.Units_Putaway
UNION ALL SELECT 'Skus_Putaway', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Skus Putaway]) FROM dbo.Skus_Putaway
UNION ALL SELECT 'Presentations_Putaway', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Presentations Putaway]) FROM dbo.Presentations_Putaway
UNION ALL SELECT 'Distinct_bin_compartments_that_had_inventory', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Distinct bin compartments that had inventory]) FROM dbo.Distinct_bin_compartments_that_had_inventory
UNION ALL SELECT 'Distinct_bins_inventory_added', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Distinct bins inventory added]) FROM dbo.Distinct_bins_inventory_added
UNION ALL SELECT 'Customer_Orders_Picked', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Customer Orders Picked]) FROM dbo.Customer_Orders_Picked
UNION ALL SELECT 'Customer_Order_Lines', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Customer Order Lines]) FROM dbo.Customer_Order_Lines
UNION ALL SELECT 'Units_Picked', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Units Picked]) FROM dbo.Units_Picked
UNION ALL SELECT 'Distinct_Skus_Picked', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Distinct Skus Picked]) FROM dbo.Distinct_Skus_Picked;

WITH Summary AS (
    SELECT
        COUNT_BIG(*) AS Rows,
        MIN([Date]) AS MinDate,
        MAX([Date]) AS MaxDate,
        COALESCE(SUM(CASE WHEN [Date] IS NULL THEN 1 ELSE 0 END), 0) AS NullDates,
        COALESCE(SUM(CASE WHEN MetricValue IS NULL THEN 1 ELSE 0 END), 0) AS NullValues,
        COUNT(DISTINCT SourceName) AS SourceCount
    FROM #DailyKpiMetrics
)
INSERT INTO #PageSmoke
SELECT
    'Daily KPI Summary Report',
    'KPI source views have recent usable rows',
    Rows,
    MinDate,
    MaxDate,
    NullDates + NullValues + CASE WHEN SourceCount < 13 THEN 1 ELSE 0 END,
    CASE
        WHEN Rows = 0 OR NullDates > 0 OR NullValues > 0 OR MaxDate < @RecentStart THEN 'FAIL'
        WHEN SourceCount < 13 THEN 'WARN'
        ELSE 'PASS'
    END,
    CONCAT('Expected 13 KPI sources; found ', SourceCount, '. Recent window starts ', CONVERT(varchar(10), @RecentStart, 120), '.')
FROM Summary;

WITH Summary AS (
    SELECT
        COUNT_BIG(*) AS Rows,
        MIN(CAST(EventDate AS date)) AS MinDate,
        MAX(CAST(EventDate AS date)) AS MaxDate,
        COALESCE(SUM(CASE WHEN EventDate IS NULL OR NULLIF(Users, '') IS NULL OR NULLIF(Ports, '') IS NULL THEN 1 ELSE 0 END), 0) AS BadRows,
        COALESCE(SUM(CASE WHEN Users <> 'Unattributed' THEN 1 ELSE 0 END), 0) AS RowsWithUser,
        COALESCE(SUM(CASE WHEN Ports <> 'Unattributed' THEN 1 ELSE 0 END), 0) AS RowsWithPort
    FROM dbo.v_ProductivityDailyUserPortWorkType_v2
    WHERE WorkType = 'Pick'
)
INSERT INTO #PageSmoke
SELECT
    'Productivity by User / Port',
    'Daily productivity grain has recent pick rows',
    Rows,
    MinDate,
    MaxDate,
    BadRows,
    CASE
        WHEN Rows = 0 OR BadRows > 0 OR MaxDate < @RecentStart THEN 'FAIL'
        ELSE 'PASS'
    END,
    CONCAT('Rows with named user: ', RowsWithUser, '; rows with named port: ', RowsWithPort, '.')
FROM Summary;

WITH Summary AS (
    SELECT
        COUNT_BIG(*) AS Rows,
        MIN([Date]) AS MinDate,
        MAX([Date]) AS MaxDate,
        COALESCE(SUM(CASE WHEN [Date] IS NULL OR NULLIF([Hour], '') IS NULL OR NULLIF(Ports, '') IS NULL OR NULLIF(OrderCategory, '') IS NULL THEN 1 ELSE 0 END), 0) AS BadRows
    FROM dbo.Throughput
)
INSERT INTO #PageSmoke
SELECT
    'Throughput',
    'Throughput view has recent usable rows',
    Rows,
    MinDate,
    MaxDate,
    BadRows,
    CASE
        WHEN Rows = 0 OR BadRows > 0 OR MaxDate < @RecentStart THEN 'FAIL'
        ELSE 'PASS'
    END,
    CONCAT('Recent window starts ', CONVERT(varchar(10), @RecentStart, 120), '.')
FROM Summary;

CREATE TABLE #HistoricalMetrics (
    SourceName varchar(128) NOT NULL,
    [Date] date NULL,
    MetricValue decimal(19, 4) NULL
);

INSERT INTO #HistoricalMetrics (SourceName, [Date], MetricValue)
SELECT 'OrdersCompletedHD', [Date], TRY_CONVERT(decimal(19, 4), OrdersCompleted) FROM dbo.OrdersCompletedHD
UNION ALL SELECT 'LinesCompletedHD', [Date], TRY_CONVERT(decimal(19, 4), LinesCompleted) FROM dbo.LinesCompletedHD
UNION ALL SELECT 'UnitsPickedHD', [Date], TRY_CONVERT(decimal(19, 4), UnitsPicked) FROM dbo.UnitsPickedHD
UNION ALL SELECT 'BinPresentedHD', [Date], TRY_CONVERT(decimal(19, 4), BinPresented) FROM dbo.BinPresentedHD;

WITH Summary AS (
    SELECT
        COUNT_BIG(*) AS Rows,
        MIN([Date]) AS MinDate,
        MAX([Date]) AS MaxDate,
        COALESCE(SUM(CASE WHEN [Date] IS NULL THEN 1 ELSE 0 END), 0) AS NullDates,
        COALESCE(SUM(CASE WHEN MetricValue IS NULL THEN 1 ELSE 0 END), 0) AS NullValues,
        COUNT(DISTINCT SourceName) AS SourceCount
    FROM #HistoricalMetrics
)
INSERT INTO #PageSmoke
SELECT
    'Historical Dashboard',
    'Trailing 30-day trend views have usable rows',
    Rows,
    MinDate,
    MaxDate,
    NullDates + NullValues + CASE WHEN SourceCount < 4 THEN 1 ELSE 0 END,
    CASE
        WHEN Rows = 0 OR NullDates > 0 OR NullValues > 0 OR MaxDate < @HistoryStart THEN 'FAIL'
        WHEN SourceCount < 4 THEN 'WARN'
        ELSE 'PASS'
    END,
    CONCAT('Expected 4 historical sources; found ', SourceCount, '. History window starts ', CONVERT(varchar(10), @HistoryStart, 120), '.')
FROM Summary;

WITH Summary AS (
    SELECT
        COUNT_BIG(*) AS Rows,
        COUNT(DISTINCT MetricName) AS MetricCount,
        COALESCE(SUM(CASE WHEN NULLIF(CompartmentLabel, '') IS NULL OR NULLIF(MetricName, '') IS NULL OR NULLIF(MetricValue, '') IS NULL THEN 1 ELSE 0 END), 0) AS BadRows
    FROM dbo.InventoryAndLocationSummary
)
INSERT INTO #PageSmoke
SELECT
    'Inventory & Location Table Summary',
    'Inventory/location summary has complete metric rows',
    Rows,
    NULL,
    NULL,
    BadRows + CASE WHEN MetricCount < 5 THEN 1 ELSE 0 END,
    CASE
        WHEN Rows = 0 OR BadRows > 0 OR MetricCount < 5 THEN 'FAIL'
        ELSE 'PASS'
    END,
    CONCAT('Distinct metric names: ', MetricCount, '.')
FROM Summary;

WITH Summary AS (
    SELECT
        COUNT_BIG(*) AS Rows,
        COALESCE(SUM(CASE WHEN NULLIF(Sku, '') IS NULL OR NULLIF(CompartmentSizeName, '') IS NULL OR Quantity IS NULL OR TotalCompartments IS NULL THEN 1 ELSE 0 END), 0) AS BadRows,
        COUNT(DISTINCT Sku) AS DistinctSkus,
        COUNT(DISTINCT CompartmentSizeName) AS DistinctCompartmentSizes
    FROM dbo.DefragDetailByUomCompartmentSize_Table
)
INSERT INTO #PageSmoke
SELECT
    'Consolidation Report',
    'Consolidation detail has complete rows',
    Rows,
    NULL,
    NULL,
    BadRows,
    CASE
        WHEN BadRows > 0 THEN 'FAIL'
        WHEN Rows = 0 THEN 'WARN'
        ELSE 'PASS'
    END,
    CONCAT('Distinct SKUs: ', DistinctSkus, '; compartment sizes: ', DistinctCompartmentSizes, '. Zero rows can mean no current consolidation candidates.')
FROM Summary;

CREATE TABLE #OpenWorkSourceRows (
    SourceName varchar(128) NOT NULL,
    SourceDate date NULL
);

INSERT INTO #OpenWorkSourceRows (SourceName, SourceDate)
SELECT 'FulfillmentOrders', CAST(LastUpdatedDate AS date) FROM dbo.FulfillmentOrders
UNION ALL SELECT 'FulfillmentOrderLines', CAST(LastUpdatedDate AS date) FROM dbo.FulfillmentOrderLines
UNION ALL SELECT 'PutAwayContainers', CAST(LastUpdatedDate AS date) FROM dbo.PutAwayContainers
UNION ALL SELECT 'PutAwayContainerLineItems', CAST(LastUpdatedDate AS date) FROM dbo.PutAwayContainerLineItems
UNION ALL SELECT 'InventoryTasks', CAST(LastUpdatedDate AS date) FROM dbo.InventoryTasks
UNION ALL SELECT 'InventoryTasks_CycleCount', CAST(LastUpdatedDate AS date) FROM dbo.InventoryTasks_CycleCount;

WITH Summary AS (
    SELECT
        COUNT_BIG(*) AS Rows,
        MIN(SourceDate) AS MinDate,
        MAX(SourceDate) AS MaxDate,
        COALESCE(SUM(CASE WHEN SourceDate IS NULL THEN 1 ELSE 0 END), 0) AS NullDates,
        COUNT(DISTINCT SourceName) AS SourceCount
    FROM #OpenWorkSourceRows
)
INSERT INTO #PageSmoke
SELECT
    'Open Work History',
    'Open-work source tables have dateable rows',
    Rows,
    MinDate,
    MaxDate,
    NullDates + CASE WHEN SourceCount < 6 THEN 1 ELSE 0 END,
    CASE
        WHEN Rows = 0 OR NullDates > 0 THEN 'FAIL'
        WHEN SourceCount < 6 THEN 'WARN'
        WHEN MaxDate < @RecentStart THEN 'WARN'
        ELSE 'PASS'
    END,
    CONCAT('Expected 6 source tables; found ', SourceCount, '. Recent window starts ', CONVERT(varchar(10), @RecentStart, 120), '.')
FROM Summary;

WITH Counts AS (
    SELECT
        (SELECT COUNT_BIG(*) FROM dbo.FulfillmentOrders WHERE LOWER(Status) IN ('allocated', 'allocating', 'active', 'batched', 'new', 'released', 'shorted')) AS OpenPickOrders,
        (SELECT COUNT_BIG(*) FROM dbo.FulfillmentOrderLines WHERE LOWER(Status) IN ('active', 'allocated', 'allocating', 'new', 'pending')) AS OpenPickLines,
        (SELECT COUNT_BIG(*) FROM dbo.PutAwayContainers WHERE IsClosed = 0) AS OpenPutOrders,
        (SELECT COUNT_BIG(*)
         FROM dbo.PutAwayContainerLineItems li
         INNER JOIN dbo.PutAwayContainers c
             ON c.PrimaryKey = li.PutAwayContainerPrimaryKey
         WHERE c.IsClosed = 0) AS OpenPutLines,
        (SELECT COUNT_BIG(DISTINCT t.TaskGroupPrimaryKey)
         FROM dbo.InventoryTasks_CycleCount cc
         INNER JOIN dbo.InventoryTasks t
             ON t.PrimaryKey = cc.InventoryTaskPrimaryKey
         WHERE t.IsClosed = 0) AS OpenCycleCountOrders,
        (SELECT COUNT_BIG(*)
         FROM dbo.InventoryTasks_CycleCount cc
         INNER JOIN dbo.InventoryTasks t
             ON t.PrimaryKey = cc.InventoryTaskPrimaryKey
         WHERE t.IsClosed = 0) AS OpenCycleCountLines
),
Totals AS (
    SELECT
        OpenPickOrders,
        OpenPickLines,
        OpenPutOrders,
        OpenPutLines,
        OpenCycleCountOrders,
        OpenCycleCountLines,
        OpenPickOrders + OpenPickLines + OpenPutOrders + OpenPutLines + OpenCycleCountOrders + OpenCycleCountLines AS TotalOpenRows
    FROM Counts
)
INSERT INTO #PageSmoke
SELECT
    'Open Work History',
    'Current open-work measures are queryable',
    TotalOpenRows,
    NULL,
    NULL,
    0,
    CASE WHEN TotalOpenRows = 0 THEN 'WARN' ELSE 'PASS' END,
    CONCAT(
        'Pick orders/lines: ', OpenPickOrders, '/', OpenPickLines,
        '; Put orders/lines: ', OpenPutOrders, '/', OpenPutLines,
        '; Cycle count orders/lines: ', OpenCycleCountOrders, '/', OpenCycleCountLines,
        '. Zero can be a valid current state.'
    )
FROM Totals;

SELECT
    @RecentStart AS RecentDefaultStart,
    @HistoryStart AS HistoricalDefaultStart,
    @Today AS RunDate;

SELECT
    CASE WHEN SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) = 0 THEN 'PASS' ELSE 'FAIL' END AS AllPagesSmokeGate,
    SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) AS FailedChecks,
    SUM(CASE WHEN Status = 'WARN' THEN 1 ELSE 0 END) AS WarningChecks,
    COUNT(*) AS TotalChecks
FROM #PageSmoke;

SELECT
    PageName,
    CheckName,
    [RowCount],
    MinDate,
    MaxDate,
    IssueCount,
    Status,
    Details
FROM #PageSmoke
ORDER BY
    CASE Status WHEN 'FAIL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END,
    PageName,
    CheckName;
