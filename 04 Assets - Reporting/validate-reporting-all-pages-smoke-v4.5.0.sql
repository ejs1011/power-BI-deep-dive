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
IF OBJECT_ID('tempdb..#ExpectedDailyKpiSources') IS NOT NULL DROP TABLE #ExpectedDailyKpiSources;
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

CREATE TABLE #ExpectedDailyKpiSources (
    SourceName varchar(128) NOT NULL PRIMARY KEY
);

INSERT INTO #ExpectedDailyKpiSources (SourceName)
VALUES
    ('Total_SKUs_On_Hand'),
    ('Total_Units_On_Hand'),
    ('Total_Locations_Occupied'),
    ('Orders_Putaway'),
    ('Units_Putaway'),
    ('Skus_Putaway'),
    ('Presentations_Putaway'),
    ('Distinct_bin_compartments_that_had_inventory'),
    ('Distinct_bins_inventory_added'),
    ('Customer_Orders_Picked'),
    ('Customer_Order_Lines'),
    ('Units_Picked'),
    ('Distinct_Skus_Picked');

INSERT INTO #DailyKpiMetrics (SourceName, [Date], MetricValue)
SELECT 'Total_SKUs_On_Hand', CAST([Date] AS date), TRY_CONVERT(decimal(19, 4), [Total SKUs On Hand]) FROM dbo.Total_SKUs_On_Hand
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
),
Missing AS (
    SELECT
        COALESCE(
            STUFF((
                SELECT ', ' + e.SourceName
                FROM #ExpectedDailyKpiSources e
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM #DailyKpiMetrics m
                    WHERE m.SourceName = e.SourceName
                )
                ORDER BY e.SourceName
                FOR XML PATH(''), TYPE
            ).value('.', 'varchar(max)'), 1, 2, ''),
            ''
        ) AS MissingSources
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
    CONCAT(
        'Expected 13 KPI sources; found ', SourceCount,
        CASE WHEN MissingSources <> '' THEN CONCAT('; missing sources: ', MissingSources) ELSE '' END,
        '. Recent window starts ', CONVERT(varchar(10), @RecentStart, 120),
        '.'
    )
FROM Summary
CROSS JOIN Missing;

WITH PickRows AS (
    SELECT
        EventDate,
        Users,
        Ports,
        CAST(
            COALESCE(OrdersCompleted, 0)
            + COALESCE(BinPresentationsCompleted, 0)
            + COALESCE(LinesCompleted, 0)
            + COALESCE(UnitsCompleted, 0)
            + COALESCE(MachineWaitMinutes, 0)
            + COALESCE(ActiveHandleMinutes, 0)
            + COALESCE(TotalLoggedMinutes, 0)
            + COALESCE(RateDenominatorHours, 0)
            AS decimal(19, 4)
        ) AS ProductivityActivityBasis
    FROM dbo.v_ProductivityDailyUserPortWorkType_v2
    WHERE WorkType = 'Pick'
),
Summary AS (
    SELECT
        COUNT_BIG(*) AS Rows,
        COUNT_BIG(CASE WHEN ProductivityActivityBasis > 0 THEN 1 END) AS ActivityRows,
        COUNT_BIG(CASE WHEN EventDate >= @RecentStart AND ProductivityActivityBasis > 0 THEN 1 END) AS RecentActivityRows,
        MIN(CAST(EventDate AS date)) AS MinDate,
        MAX(CAST(EventDate AS date)) AS MaxDate,
        COALESCE(SUM(CASE WHEN EventDate IS NULL OR NULLIF(Users, '') IS NULL OR NULLIF(Ports, '') IS NULL THEN 1 ELSE 0 END), 0) AS BadRows,
        COALESCE(SUM(CASE WHEN Users <> 'Unattributed' THEN 1 ELSE 0 END), 0) AS RowsWithUser,
        COALESCE(SUM(CASE WHEN Ports <> 'Unattributed' THEN 1 ELSE 0 END), 0) AS RowsWithPort,
        COALESCE(SUM(CASE WHEN ProductivityActivityBasis <= 0 THEN 1 ELSE 0 END), 0) AS ZeroActivityRows
    FROM PickRows
)
INSERT INTO #PageSmoke
SELECT
    'Productivity by User / Port',
    'Daily productivity grain has recent pick rows',
    Rows,
    MinDate,
    MaxDate,
    BadRows + CASE WHEN RecentActivityRows = 0 THEN 1 ELSE 0 END,
    CASE
        WHEN Rows = 0 OR BadRows > 0 OR MaxDate < @RecentStart THEN 'FAIL'
        WHEN RecentActivityRows = 0 THEN 'WARN'
        ELSE 'PASS'
    END,
    CONCAT(
        'Rows with named user: ', RowsWithUser,
        '; rows with named port: ', RowsWithPort,
        '; activity rows: ', ActivityRows,
        '; recent activity rows: ', RecentActivityRows,
        '; zero-activity rows hidden by PBIX measures: ', ZeroActivityRows,
        '.'
    )
FROM Summary;

WITH Summary AS (
    SELECT
        COUNT_BIG(*) AS Rows,
        MIN([Date]) AS MinDate,
        MAX([Date]) AS MaxDate,
        COALESCE(SUM(CASE
            WHEN [Date] IS NULL
              OR NULLIF([Hour], '') IS NULL
              OR NULLIF(Ports, '') IS NULL
              OR NULLIF(OrderCategory, '') IS NULL
              OR Ports = 'No Data'
              OR OrderCategory IN ('NO VALUE', 'Unknown')
                THEN 1
            ELSE 0
        END), 0) AS BadRows
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

WITH ExpectedInventoryMetrics AS (
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
LabelMetricCounts AS (
    SELECT
        CompartmentLabel,
        MetricName,
        COUNT_BIG(*) AS [RowCount]
    FROM dbo.InventoryAndLocationSummary
    GROUP BY
        CompartmentLabel,
        MetricName
),
Summary AS (
    SELECT
        (SELECT COUNT_BIG(*) FROM dbo.InventoryAndLocationSummary) AS Rows,
        (SELECT COUNT(DISTINCT MetricName) FROM dbo.InventoryAndLocationSummary) AS MetricCount,
        (SELECT COUNT(DISTINCT CompartmentLabel) FROM dbo.InventoryAndLocationSummary) AS LabelCount,
        (SELECT COALESCE(SUM(CASE WHEN NULLIF(CompartmentLabel, '') IS NULL OR NULLIF(MetricName, '') IS NULL OR NULLIF(MetricValue, '') IS NULL THEN 1 ELSE 0 END), 0) FROM dbo.InventoryAndLocationSummary) AS BadRows,
        COALESCE(SUM(CASE WHEN counts.[RowCount] IS NULL THEN 1 ELSE 0 END), 0) AS MissingMetricInstances,
        COALESCE(SUM(CASE WHEN counts.[RowCount] > 1 THEN counts.[RowCount] - 1 ELSE 0 END), 0) AS DuplicateMetricRows,
        (
            SELECT COUNT_BIG(*)
            FROM dbo.InventoryAndLocationSummary report
            LEFT JOIN ExpectedInventoryMetrics expected
                ON expected.MetricName = report.MetricName
            WHERE expected.MetricName IS NULL
        ) AS UnexpectedMetricRows
    FROM (SELECT DISTINCT CompartmentLabel FROM dbo.InventoryAndLocationSummary) labels
    CROSS JOIN ExpectedInventoryMetrics expected
    LEFT JOIN LabelMetricCounts counts
        ON counts.CompartmentLabel = labels.CompartmentLabel
       AND counts.MetricName = expected.MetricName
)
INSERT INTO #PageSmoke
SELECT
    'Inventory & Location Table Summary',
    'Inventory/location summary has complete metric rows',
    Rows,
    NULL,
    NULL,
    BadRows + MissingMetricInstances + DuplicateMetricRows + UnexpectedMetricRows + CASE WHEN MetricCount <> 18 THEN 1 ELSE 0 END,
    CASE
        WHEN Rows = 0
          OR BadRows > 0
          OR MetricCount <> 18
          OR MissingMetricInstances > 0
          OR DuplicateMetricRows > 0
          OR UnexpectedMetricRows > 0 THEN 'FAIL'
        ELSE 'PASS'
    END,
    CONCAT('Labels: ', LabelCount, '; distinct metric names: ', MetricCount, '; missing metric instances: ', MissingMetricInstances, '; duplicate metric rows: ', DuplicateMetricRows, '; unexpected metric rows: ', UnexpectedMetricRows, '.')
FROM Summary;

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

;WITH Summary AS (
    SELECT
        COUNT_BIG(*) AS ReportRows,
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
        END), 0) AS BadFragmentationRows,
        COUNT(DISTINCT Sku) AS DistinctSkus,
        COUNT(DISTINCT CompartmentSizeName) AS DistinctCompartmentSizes
    FROM dbo.DefragDetailByUomCompartmentSize_Table
)
INSERT INTO #PageSmoke
SELECT
    'Consolidation Report',
    'Consolidation detail has displayable rows',
    ReportRows,
    NULL,
    NULL,
    MissingDisplayRows + NegativeValueRows + BadFragmentationDenominatorRows + BadFragmentationRows
        + CASE WHEN @ConsolidationSourceRows > 0 AND ReportRows = 0 THEN 1 ELSE 0 END,
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
        'Source rows: ', COALESCE(CONVERT(varchar(30), @ConsolidationSourceRows), 'unavailable'),
        '; report rows: ', ReportRows,
        '; source quantity: ', COALESCE(CONVERT(varchar(30), @ConsolidationSourceQuantity), 'unavailable'),
        '; distinct SKUs: ', DistinctSkus,
        '; compartment sizes: ', DistinctCompartmentSizes,
        '; missing display rows: ', MissingDisplayRows,
        '; missing optional metric rows: ', MissingOptionalMetricRows,
        '; negative value rows: ', NegativeValueRows,
        '; bad fragmentation denominators: ', BadFragmentationDenominatorRows,
        '; bad fragmentation rows: ', BadFragmentationRows,
        '. Zero rows can mean no current consolidation candidates only when source rows are also zero.'
    )
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
        (SELECT COUNT_BIG(*) FROM dbo.FulfillmentOrders WHERE LOWER(Status) IN ('allocated', 'allocating', 'active', 'batched', 'new', 'released', 'importing', 'failed allocation', 'falied allocation', 'shorted')) AS OpenPickOrders,
        (SELECT COUNT_BIG(*) FROM dbo.FulfillmentOrderLines WHERE LOWER(Status) IN ('active', 'allocated', 'allocating', 'new', 'pending')) AS OpenPickLines,
        (SELECT COUNT_BIG(*) FROM dbo.PutAwayContainers WHERE IsClosed = 0) AS OpenPutOrders,
        (SELECT COUNT_BIG(*)
         FROM dbo.PutAwayContainerLineItems li
         INNER JOIN dbo.PutAwayContainers c
             ON c.PrimaryKey = li.PutAwayContainerPrimaryKey
         WHERE c.IsClosed = 0
           AND COALESCE(li.ActualQuantity, 0) + COALESCE(li.MissingQuantity, 0) < COALESCE(li.Quantity, 0)) AS OpenPutLines,
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
