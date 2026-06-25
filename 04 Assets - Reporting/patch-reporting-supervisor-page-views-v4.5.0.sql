USE [KFX_REPORTING];
GO

/*
    Supervisor dashboard consistency patch.

    Prerequisite:
      Run create-reporting-productivity-work-events-v4.5.0.sql first so
      dbo.v_ProductivityWorkEvents_v2 and dbo.v_ProductivityDailyUserPortWorkType_v2 exist.

    Purpose:
      Keep the existing Power BI pages/field bindings intact, but make the
      Historical Dashboard and Throughput pages aggregate from the same completed
      work-event grain used by the corrected Productivity page.
*/

CREATE OR ALTER VIEW [dbo].[OrdersCompletedHD]
AS
SELECT
    EventDate AS [Date],
    CAST(SUM(OrdersCompleted) AS bigint) AS OrdersCompleted
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
GROUP BY EventDate;
GO

CREATE OR ALTER VIEW [dbo].[LinesCompletedHD]
AS
SELECT
    EventDate AS [Date],
    CAST(SUM(LinesCompleted) AS bigint) AS LinesCompleted
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
GROUP BY EventDate;
GO

CREATE OR ALTER VIEW [dbo].[UnitsPickedHD]
AS
SELECT
    EventDate AS [Date],
    CAST(SUM(UnitsCompleted) AS bigint) AS UnitsPicked
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
GROUP BY EventDate;
GO

CREATE OR ALTER VIEW [dbo].[BinPresentedHD]
AS
SELECT
    EventDate AS [Date],
    CAST(SUM(BinPresentationsCompleted) AS bigint) AS BinPresented
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
GROUP BY EventDate;
GO

CREATE OR ALTER VIEW [dbo].[Customer_Orders_Picked]
AS
SELECT
    EventDate AS [Date],
    CAST(SUM(OrdersCompleted) AS bigint) AS [Customer Orders Picked]
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
GROUP BY EventDate;
GO

CREATE OR ALTER VIEW [dbo].[Customer_Order_Lines]
AS
SELECT
    EventDate AS [Date],
    CAST(SUM(LinesCompleted) AS bigint) AS [Customer Order Lines]
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
GROUP BY EventDate;
GO

CREATE OR ALTER VIEW [dbo].[Units_Picked]
AS
SELECT
    EventDate AS [Date],
    CAST(SUM(UnitsCompleted) AS bigint) AS [Units Picked]
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE WorkType = 'Pick'
GROUP BY EventDate;
GO

CREATE OR ALTER VIEW [dbo].[Distinct_Skus_Picked]
AS
SELECT
    CAST(COALESCE(p.PickCompleteDate, p.[TimeStamp]) AS date) AS [Date],
    CAST(COUNT(DISTINCT p.Sku) AS bigint) AS [Distinct Skus Picked]
FROM dbo.Pick p
WHERE p.Sku IS NOT NULL
  AND p.[User] IS NOT NULL
  AND COALESCE(p.PickCompleteDate, p.[TimeStamp]) IS NOT NULL
  AND COALESCE(p.ActualPickQuantity, 0) >= COALESCE(p.RequiredPickQuantity, 0)
GROUP BY CAST(COALESCE(p.PickCompleteDate, p.[TimeStamp]) AS date);
GO

CREATE OR ALTER VIEW [dbo].[Throughput]
AS
WITH OrderEvents AS (
    SELECT
        CAST(e.StartTime AS date) AS [Date],
        FORMAT(e.StartTime, 'h tt') AS [Hour],
        COALESCE(NULLIF(e.Port, ''), 'No Data') AS Ports,
        COALESCE(NULLIF(category_match.OrderCategory, ''), 'NO VALUE') AS OrderCategory,
        e.OrderCompletedCount AS OrdersCompleted,
        CAST(0 AS int) AS LinesCompleted,
        CAST(0 AS int) AS BinPresentationsCompleted
    FROM dbo.v_ProductivityWorkEvents_v2 e
    OUTER APPLY (
        SELECT TOP (1)
            p.OrderCategory
        FROM dbo.Pick p
        WHERE p.TransportOrderPrimaryKey = e.FulfillmentOrderPrimaryKey
        ORDER BY p.[TimeStamp], p.PrimaryKey
    ) category_match
    WHERE e.WorkType = 'Pick'
      AND e.EventType = 'ORDER_COMPLETED'
      AND e.StartTime IS NOT NULL
),
LineEvents AS (
    SELECT
        CAST(e.StartTime AS date) AS [Date],
        FORMAT(e.StartTime, 'h tt') AS [Hour],
        COALESCE(NULLIF(e.Port, ''), 'No Data') AS Ports,
        COALESCE(NULLIF(category_match.OrderCategory, ''), 'NO VALUE') AS OrderCategory,
        CAST(0 AS int) AS OrdersCompleted,
        e.LineCompletedCount AS LinesCompleted,
        CAST(0 AS int) AS BinPresentationsCompleted
    FROM dbo.v_ProductivityWorkEvents_v2 e
    OUTER APPLY (
        SELECT TOP (1)
            p.OrderCategory
        FROM dbo.Pick p
        WHERE p.PickPrimaryKey = e.FulfillmentOrderLinePrimaryKey
        ORDER BY p.PrimaryKey
    ) category_match
    WHERE e.WorkType = 'Pick'
      AND e.EventType = 'LINE_COMPLETED'
      AND e.StartTime IS NOT NULL
),
BinEvents AS (
    SELECT
        CAST(e.StartTime AS date) AS [Date],
        FORMAT(e.StartTime, 'h tt') AS [Hour],
        COALESCE(NULLIF(e.Port, ''), 'No Data') AS Ports,
        COALESCE(NULLIF(category_match.OrderCategory, ''), 'NO VALUE') AS OrderCategory,
        CAST(0 AS int) AS OrdersCompleted,
        CAST(0 AS int) AS LinesCompleted,
        e.BinPresentationCount AS BinPresentationsCompleted
    FROM dbo.v_ProductivityWorkEvents_v2 e
    OUTER APPLY (
        SELECT TOP (1)
            p.OrderCategory
        FROM dbo.Pick p
        WHERE p.ContainerBarcode = e.ContainerBarcode
          AND p.[TimeStamp] >= e.StartTime
        ORDER BY p.[TimeStamp], p.PrimaryKey
    ) category_match
    WHERE e.WorkType = 'Pick'
      AND e.EventType = 'BIN_PRESENTATION'
      AND e.StartTime IS NOT NULL
),
CombinedEvents AS (
    SELECT * FROM OrderEvents
    UNION ALL
    SELECT * FROM LineEvents
    UNION ALL
    SELECT * FROM BinEvents
)
SELECT
    [Date],
    [Hour],
    Ports,
    CAST(SUM(OrdersCompleted) AS bigint) AS OrdersCompleted,
    CAST(SUM(LinesCompleted) AS bigint) AS LinesCompleted,
    OrderCategory,
    CAST(SUM(BinPresentationsCompleted) AS bigint) AS BinPresentationsCompleted
FROM CombinedEvents
GROUP BY
    [Date],
    [Hour],
    Ports,
    OrderCategory;
GO

CREATE OR ALTER PROCEDURE [dbo].[InventoryAndLocationSummaryData]
AS
BEGIN
    SET NOCOUNT ON;

    /*
        The original procedure filtered every snapshot-backed source to
        CAST(LastUpdatedDate AS date) = CAST(GETDATE() AS date). That can blank
        the Inventory & Location page whenever template/container metadata did
        not change today. Use the latest available snapshot for each source
        instead, which is the current-state behavior a supervisor expects.
    */
    DECLARE @InventorySnapshotId bigint = (SELECT MAX(Snapshot_Id) FROM dbo.Inventory);
    DECLARE @ContainerSnapshotId bigint = (SELECT MAX(Snapshot_Id) FROM dbo.Containers);
    DECLARE @TemplateSnapshotId bigint = (SELECT MAX(Snapshot_Id) FROM dbo.ContainerTemplates);
    DECLARE @CompartmentSizeSnapshotId bigint = (SELECT MAX(Snapshot_Id) FROM dbo.CompartmentSizes);
    DECLARE @UnitsOfMeasureSnapshotId bigint = (SELECT MAX(Snapshot_Id) FROM dbo.UnitsOfMeasure);

    IF OBJECT_ID('tempdb..#Inventory1') IS NOT NULL DROP TABLE #Inventory1;
    IF OBJECT_ID('tempdb..#Containers1') IS NOT NULL DROP TABLE #Containers1;
    IF OBJECT_ID('tempdb..#ContainerTemplates1') IS NOT NULL DROP TABLE #ContainerTemplates1;
    IF OBJECT_ID('tempdb..#CompartmentSizes1') IS NOT NULL DROP TABLE #CompartmentSizes1;
    IF OBJECT_ID('tempdb..#UnitsOfMeasure1') IS NOT NULL DROP TABLE #UnitsOfMeasure1;

    SELECT *
    INTO #Inventory1
    FROM dbo.Inventory
    WHERE Snapshot_Id = @InventorySnapshotId;

    SELECT *
    INTO #Containers1
    FROM dbo.Containers
    WHERE Snapshot_Id = @ContainerSnapshotId;

    SELECT *
    INTO #ContainerTemplates1
    FROM dbo.ContainerTemplates
    WHERE Snapshot_Id = @TemplateSnapshotId;

    SELECT *
    INTO #CompartmentSizes1
    FROM dbo.CompartmentSizes
    WHERE Snapshot_Id = @CompartmentSizeSnapshotId;

    SELECT *
    INTO #UnitsOfMeasure1
    FROM dbo.UnitsOfMeasure
    WHERE Snapshot_Id = @UnitsOfMeasureSnapshotId;

    IF OBJECT_ID('dbo.InventoryAndLocationSummary', 'U') IS NULL
    BEGIN
        CREATE TABLE dbo.InventoryAndLocationSummary (
            CompartmentLabel nvarchar(100) NULL,
            MetricName nvarchar(50) NULL,
            MetricValue nvarchar(50) NULL
        );
    END
    ELSE
    BEGIN
        TRUNCATE TABLE dbo.InventoryAndLocationSummary;
    END;

    ;WITH TemplateCompartments AS (
        SELECT DISTINCT
            ct.PrimaryKey AS TemplatePrimaryKey,
            ct.TemplateName,
            cs.Name AS CompartmentName,
            CONCAT(
                cs.Name,
                ' (',
                NULLIF(LTRIM(RTRIM(REPLACE(ct.TemplateName, 'Autostore ', ''))), ''),
                ')'
            ) AS CompartmentLabel
        FROM #ContainerTemplates1 ct
        INNER JOIN dbo.ContainerTemplateCompartments ctc
            ON ctc.TemplatePrimaryKey = ct.PrimaryKey
        INNER JOIN #CompartmentSizes1 cs
            ON cs.PrimaryKey = ctc.CompartmentSizePrimaryKey
        WHERE ct.IsGoodsToPerson = 1
          AND NULLIF(ct.TemplateName, '') IS NOT NULL
          AND NULLIF(cs.Name, '') IS NOT NULL
    ),
    ContainersByTemplate AS (
        SELECT
            tc.TemplatePrimaryKey,
            c.PrimaryKey AS ContainerPrimaryKey
        FROM (SELECT DISTINCT TemplatePrimaryKey FROM TemplateCompartments) tc
        INNER JOIN #Containers1 c
            ON c.TemplatePrimaryKey = tc.TemplatePrimaryKey
        WHERE COALESCE(c.Status, '') <> 'Outside'
    ),
    TemplateBins AS (
        SELECT
            TemplatePrimaryKey,
            COUNT_BIG(*) AS TotalBins
        FROM ContainersByTemplate
        GROUP BY TemplatePrimaryKey
    ),
    TemplateLocations AS (
        SELECT
            cbt.TemplatePrimaryKey,
            COUNT_BIG(*) AS TotalLocations
        FROM ContainersByTemplate cbt
        INNER JOIN dbo.ContainerTemplateCompartments ctc
            ON ctc.TemplatePrimaryKey = cbt.TemplatePrimaryKey
        GROUP BY cbt.TemplatePrimaryKey
    ),
    InventoryRows AS (
        SELECT
            ct.PrimaryKey AS TemplatePrimaryKey,
            i.ContainerPrimaryKey,
            i.ContainerX,
            i.ContainerY,
            COALESCE(uom.ProductPrimaryKey, i.UnitOfMeasurePrimaryKey) AS SkuKey,
            CAST(i.Quantity AS decimal(19, 4))
                * COALESCE(NULLIF(CAST(uom.BaseMultiple AS decimal(19, 4)), 0), 1) AS UnitsStocked
        FROM #Inventory1 i
        INNER JOIN #Containers1 c
            ON c.PrimaryKey = i.ContainerPrimaryKey
        INNER JOIN #ContainerTemplates1 ct
            ON ct.PrimaryKey = c.TemplatePrimaryKey
        LEFT JOIN #UnitsOfMeasure1 uom
            ON uom.PrimaryKey = i.UnitOfMeasurePrimaryKey
        WHERE COALESCE(i.Status, '') <> 'Pending'
          AND COALESCE(c.Status, '') <> 'Outside'
          AND COALESCE(i.Quantity, 0) > 0
          AND ct.IsGoodsToPerson = 1
    ),
    StockSummary AS (
        SELECT
            TemplatePrimaryKey,
            COUNT(DISTINCT ContainerPrimaryKey) AS BinsWithStock,
            COUNT(DISTINCT CONCAT(ContainerPrimaryKey, '|', ContainerX, '|', ContainerY)) AS LocationsOccupied,
            COUNT(DISTINCT SkuKey) AS DistinctSkusStocked,
            SUM(UnitsStocked) AS UnitsStocked
        FROM InventoryRows
        GROUP BY TemplatePrimaryKey
    ),
    SkuLocationCounts AS (
        SELECT
            TemplatePrimaryKey,
            SkuKey,
            COUNT(DISTINCT CONCAT(ContainerPrimaryKey, '|', ContainerX, '|', ContainerY)) AS LocationCount
        FROM InventoryRows
        WHERE SkuKey IS NOT NULL
        GROUP BY
            TemplatePrimaryKey,
            SkuKey
    ),
    SkuLocationSummary AS (
        SELECT
            TemplatePrimaryKey,
            AVG(CAST(LocationCount AS decimal(19, 4))) AS AvgLocationsStockedPerSku
        FROM SkuLocationCounts
        GROUP BY TemplatePrimaryKey
    ),
    TotalStock AS (
        SELECT NULLIF(SUM(COALESCE(UnitsStocked, 0)), 0) AS AllUnitsStocked
        FROM StockSummary
    ),
    MetricsBase AS (
        SELECT
            tc.CompartmentLabel,
            COALESCE(ss.BinsWithStock, 0) AS BinsWithStock,
            COALESCE(tb.TotalBins, 0) AS TotalBins,
            COALESCE(tl.TotalLocations, 0) AS TotalLocations,
            COALESCE(ss.LocationsOccupied, 0) AS LocationsOccupied,
            COALESCE(ss.DistinctSkusStocked, 0) AS DistinctSkusStocked,
            COALESCE(ss.UnitsStocked, 0) AS UnitsStocked,
            COALESCE(sl.AvgLocationsStockedPerSku, 0) AS AvgLocationsStockedPerSku,
            ts.AllUnitsStocked
        FROM TemplateCompartments tc
        LEFT JOIN TemplateBins tb
            ON tb.TemplatePrimaryKey = tc.TemplatePrimaryKey
        LEFT JOIN TemplateLocations tl
            ON tl.TemplatePrimaryKey = tc.TemplatePrimaryKey
        LEFT JOIN StockSummary ss
            ON ss.TemplatePrimaryKey = tc.TemplatePrimaryKey
        LEFT JOIN SkuLocationSummary sl
            ON sl.TemplatePrimaryKey = tc.TemplatePrimaryKey
        CROSS JOIN TotalStock ts
    ),
    Metrics AS (
        SELECT
            mb.CompartmentLabel,
            v.MetricName,
            v.MetricValue
        FROM MetricsBase mb
        CROSS APPLY (VALUES
            ('Total Bin(s) w/ Inventory', FORMAT(mb.BinsWithStock, 'N0')),
            ('Total Bin(s) w/ No Inventory', FORMAT(CASE WHEN mb.TotalBins > mb.BinsWithStock THEN mb.TotalBins - mb.BinsWithStock ELSE 0 END, 'N0')),
            ('Total Bin(s)', FORMAT(mb.TotalBins, 'N0')),
            ('% of Bin(s) w/ Inventory', CONCAT(FORMAT(CASE WHEN mb.TotalBins = 0 THEN 0 ELSE mb.BinsWithStock * 100.0 / mb.TotalBins END, 'N2'), '%')),
            ('% of Bin(s) w/ No Inventory', CONCAT(FORMAT(CASE WHEN mb.TotalBins = 0 THEN 0 ELSE (mb.TotalBins - mb.BinsWithStock) * 100.0 / mb.TotalBins END, 'N2'), '%')),
            ('% of Total Bin(s)', CONCAT(FORMAT(CASE WHEN mb.TotalBins = 0 THEN 0 ELSE (mb.BinsWithStock + CASE WHEN mb.TotalBins > mb.BinsWithStock THEN mb.TotalBins - mb.BinsWithStock ELSE 0 END) * 100.0 / mb.TotalBins END, 'N2'), '%')),
            ('Total Locations Occupied', FORMAT(mb.LocationsOccupied, 'N0')),
            ('Total Locations Empty', FORMAT(CASE WHEN mb.TotalLocations > mb.LocationsOccupied THEN mb.TotalLocations - mb.LocationsOccupied ELSE 0 END, 'N0')),
            ('Total Locations', FORMAT(mb.TotalLocations, 'N0')),
            ('% Locations Occupied', CONCAT(FORMAT(CASE WHEN mb.TotalLocations = 0 THEN 0 ELSE mb.LocationsOccupied * 100.0 / mb.TotalLocations END, 'N2'), '%')),
            ('% Locations Empty', CONCAT(FORMAT(CASE WHEN mb.TotalLocations = 0 THEN 0 ELSE (mb.TotalLocations - mb.LocationsOccupied) * 100.0 / mb.TotalLocations END, 'N2'), '%')),
            ('Distinct SKUs Stocked', FORMAT(mb.DistinctSkusStocked, 'N0')),
            ('Units Stocked', FORMAT(mb.UnitsStocked, 'N2')),
            ('% Units Stocked', CONCAT(FORMAT(CASE WHEN mb.AllUnitsStocked IS NULL THEN 0 ELSE mb.UnitsStocked * 100.0 / mb.AllUnitsStocked END, 'N2'), '%')),
            ('Avg Units Stocked Per Location', FORMAT(CASE WHEN mb.TotalLocations = 0 THEN 0 ELSE mb.UnitsStocked / mb.TotalLocations END, 'N2')),
            ('Avg Units Stocked per Bin(s)', FORMAT(CASE WHEN mb.TotalBins = 0 THEN 0 ELSE mb.UnitsStocked / mb.TotalBins END, 'N2')),
            ('Avg Units Stocked per SKU', FORMAT(CASE WHEN mb.DistinctSkusStocked = 0 THEN 0 ELSE mb.UnitsStocked / mb.DistinctSkusStocked END, 'N2')),
            ('Avg Locations Stocked per SKU', FORMAT(mb.AvgLocationsStockedPerSku, 'N2'))
        ) v(MetricName, MetricValue)
    )
    INSERT INTO dbo.InventoryAndLocationSummary (CompartmentLabel, MetricName, MetricValue)
    SELECT
        CompartmentLabel,
        MetricName,
        MetricValue
    FROM Metrics;
END;
GO

EXEC dbo.InventoryAndLocationSummaryData;
GO
