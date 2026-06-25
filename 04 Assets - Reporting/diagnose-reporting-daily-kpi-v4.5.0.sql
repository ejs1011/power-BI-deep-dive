USE [KFX_REPORTING];
GO

SET NOCOUNT ON;

/*
    Daily KPI troubleshooting script.

    Purpose:
      Explain why the Daily KPI Summary Report shows zero inventory/inbound
      values in the current date window.

    Key thing to watch:
      The Power BI measures add +0, so "0" can mean "the SQL view returned no
      row for that date." These result sets distinguish true zero activity from
      missing/stale rows or date filters that exclude otherwise valid source data.
*/

DECLARE @Today date = CAST(GETDATE() AS date);
DECLARE @StartDate date = DATEADD(day, -14, @Today);
DECLARE @DefaultStartDate date = DATEADD(day, -7, @Today);

SELECT
    @@SERVERNAME AS ServerName,
    DB_NAME() AS DatabaseName,
    @DefaultStartDate AS PowerBIDefaultStartDate,
    @Today AS Today,
    @StartDate AS DiagnosticStartDate;

PRINT 'Daily KPI SQL view outputs for the diagnostic window.';

WITH KpiOutputs AS (
    SELECT 'Inventory' AS GroupName, 'Total SKUs On Hand' AS MetricName, [Date], CAST([Totak SKUs On Hand] AS decimal(19, 4)) AS MetricValue
    FROM dbo.Total_SKUs_On_Hand
    UNION ALL
    SELECT 'Inventory', 'Total Units On Hand', [Date], CAST([Total Units On Hand] AS decimal(19, 4))
    FROM dbo.Total_Units_On_Hand
    UNION ALL
    SELECT 'Inventory', 'Total Locations Occupied', [Date], CAST([Total Locations Occupied] AS decimal(19, 4))
    FROM dbo.Total_Locations_Occupied
    UNION ALL
    SELECT 'Inbound', 'Orders Put Away', [Date], CAST([Orders Putaway] AS decimal(19, 4))
    FROM dbo.Orders_Putaway
    UNION ALL
    SELECT 'Inbound', 'Units Put Away', [Date], CAST([Units Putaway] AS decimal(19, 4))
    FROM dbo.Units_Putaway
    UNION ALL
    SELECT 'Inbound', 'SKUs Put Away', [Date], CAST([Skus Putaway] AS decimal(19, 4))
    FROM dbo.Skus_Putaway
    UNION ALL
    SELECT 'Inbound', 'Bin Presentations Put Away', [Date], CAST([Presentations Putaway] AS decimal(19, 4))
    FROM dbo.Presentations_Putaway
    UNION ALL
    SELECT 'Inbound', 'Distinct Bins With Inventory', [Date], CAST([Distinct bins inventory added] AS decimal(19, 4))
    FROM dbo.Distinct_bins_inventory_added
    UNION ALL
    SELECT 'Inbound', 'Distinct Bin Compartments With Inventory', [Date], CAST([Distinct bin compartments that had inventory] AS decimal(19, 4))
    FROM dbo.Distinct_bin_compartments_that_had_inventory
    UNION ALL
    SELECT 'Picking', 'Customer Orders Picked', [Date], CAST([Customer Orders Picked] AS decimal(19, 4))
    FROM dbo.Customer_Orders_Picked
    UNION ALL
    SELECT 'Picking', 'Customer Order Lines', [Date], CAST([Customer Order Lines] AS decimal(19, 4))
    FROM dbo.Customer_Order_Lines
    UNION ALL
    SELECT 'Picking', 'Units Picked', [Date], CAST([Units Picked] AS decimal(19, 4))
    FROM dbo.Units_Picked
    UNION ALL
    SELECT 'Picking', 'Distinct SKUs Picked', [Date], CAST([Distinct Skus Picked] AS decimal(19, 4))
    FROM dbo.Distinct_Skus_Picked
)
SELECT
    GroupName,
    MetricName,
    [Date],
    MetricValue
FROM KpiOutputs
WHERE [Date] >= @StartDate
ORDER BY
    CASE GroupName WHEN 'Inventory' THEN 1 WHEN 'Inbound' THEN 2 WHEN 'Picking' THEN 3 ELSE 4 END,
    MetricName,
    [Date];

PRINT 'Daily KPI source coverage summary.';

WITH KpiOutputs AS (
    SELECT 'Inventory' AS GroupName, 'Total_SKUs_On_Hand' AS SourceName, [Date], CAST([Totak SKUs On Hand] AS decimal(19, 4)) AS MetricValue
    FROM dbo.Total_SKUs_On_Hand
    UNION ALL
    SELECT 'Inventory', 'Total_Units_On_Hand', [Date], CAST([Total Units On Hand] AS decimal(19, 4))
    FROM dbo.Total_Units_On_Hand
    UNION ALL
    SELECT 'Inventory', 'Total_Locations_Occupied', [Date], CAST([Total Locations Occupied] AS decimal(19, 4))
    FROM dbo.Total_Locations_Occupied
    UNION ALL
    SELECT 'Inbound', 'Orders_Putaway', [Date], CAST([Orders Putaway] AS decimal(19, 4))
    FROM dbo.Orders_Putaway
    UNION ALL
    SELECT 'Inbound', 'Units_Putaway', [Date], CAST([Units Putaway] AS decimal(19, 4))
    FROM dbo.Units_Putaway
    UNION ALL
    SELECT 'Inbound', 'Skus_Putaway', [Date], CAST([Skus Putaway] AS decimal(19, 4))
    FROM dbo.Skus_Putaway
    UNION ALL
    SELECT 'Inbound', 'Presentations_Putaway', [Date], CAST([Presentations Putaway] AS decimal(19, 4))
    FROM dbo.Presentations_Putaway
    UNION ALL
    SELECT 'Inbound', 'Distinct_bins_inventory_added', [Date], CAST([Distinct bins inventory added] AS decimal(19, 4))
    FROM dbo.Distinct_bins_inventory_added
    UNION ALL
    SELECT 'Inbound', 'Distinct_bin_compartments_that_had_inventory', [Date], CAST([Distinct bin compartments that had inventory] AS decimal(19, 4))
    FROM dbo.Distinct_bin_compartments_that_had_inventory
    UNION ALL
    SELECT 'Picking', 'Customer_Orders_Picked', [Date], CAST([Customer Orders Picked] AS decimal(19, 4))
    FROM dbo.Customer_Orders_Picked
    UNION ALL
    SELECT 'Picking', 'Customer_Order_Lines', [Date], CAST([Customer Order Lines] AS decimal(19, 4))
    FROM dbo.Customer_Order_Lines
    UNION ALL
    SELECT 'Picking', 'Units_Picked', [Date], CAST([Units Picked] AS decimal(19, 4))
    FROM dbo.Units_Picked
    UNION ALL
    SELECT 'Picking', 'Distinct_Skus_Picked', [Date], CAST([Distinct Skus Picked] AS decimal(19, 4))
    FROM dbo.Distinct_Skus_Picked
)
SELECT
    GroupName,
    SourceName,
    COUNT_BIG(*) AS TotalRows,
    MIN([Date]) AS MinDate,
    MAX([Date]) AS MaxDate,
    SUM(CASE WHEN [Date] >= @DefaultStartDate THEN 1 ELSE 0 END) AS RowsInPowerBIDefaultWindow,
    SUM(CASE WHEN [Date] >= @DefaultStartDate THEN MetricValue ELSE 0 END) AS ValueInPowerBIDefaultWindow
FROM KpiOutputs
GROUP BY
    GroupName,
    SourceName
ORDER BY
    CASE GroupName WHEN 'Inventory' THEN 1 WHEN 'Inbound' THEN 2 WHEN 'Picking' THEN 3 ELSE 4 END,
    SourceName;

PRINT 'Inventory source freshness and Daily KPI filter survival.';

SELECT
    'Inventory' AS SourceName,
    COUNT_BIG(*) AS Rows,
    MIN(CAST(LastUpdatedDate AS date)) AS MinSnapshotDate,
    MAX(CAST(LastUpdatedDate AS date)) AS MaxSnapshotDate,
    MIN(CAST(LastUpdatedDateInventory AS date)) AS MinBusinessLastUpdatedDate,
    MAX(CAST(LastUpdatedDateInventory AS date)) AS MaxBusinessLastUpdatedDate,
    MAX(Snapshot_Id) AS MaxSnapshotId
FROM dbo.Inventory
UNION ALL
SELECT
    'Containers',
    COUNT_BIG(*),
    MIN(CAST(LastUpdatedDate AS date)),
    MAX(CAST(LastUpdatedDate AS date)),
    MIN(CAST(LastUpdatedDateInventory AS date)),
    MAX(CAST(LastUpdatedDateInventory AS date)),
    MAX(Snapshot_Id)
FROM dbo.Containers;

WITH InventoryJoin AS (
    SELECT
        CAST(i.LastUpdatedDate AS date) AS InventorySnapshotDate,
        i.PrimaryKey AS InventoryPrimaryKey,
        i.UnitOfMeasurePrimaryKey,
        i.ContainerPrimaryKey,
        i.ContainerX,
        i.ContainerY,
        i.Quantity,
        i.Status AS InventoryStatus,
        c.PrimaryKey AS ContainerMatchedPrimaryKey,
        c.Status AS ContainerStatus,
        CAST(c.LastUpdatedDate AS date) AS ContainerSnapshotDate
    FROM dbo.Inventory i
    LEFT JOIN dbo.Containers c
        ON c.PrimaryKey = i.ContainerPrimaryKey
)
SELECT
    InventorySnapshotDate,
    COUNT_BIG(*) AS InventoryRows,
    SUM(CASE WHEN InventoryStatus <> 'Pending' THEN 1 ELSE 0 END) AS InventoryNotPendingRows,
    SUM(CASE WHEN InventoryStatus <> 'Pending' AND ContainerMatchedPrimaryKey IS NOT NULL THEN 1 ELSE 0 END) AS NotPendingRowsWithContainerMatch,
    SUM(CASE WHEN InventoryStatus <> 'Pending' AND COALESCE(ContainerStatus, '') <> 'Outside' THEN 1 ELSE 0 END) AS RowsEligibleBeforeDateMatch,
    SUM(CASE WHEN InventoryStatus <> 'Pending' AND COALESCE(ContainerStatus, '') <> 'Outside' AND InventorySnapshotDate = ContainerSnapshotDate THEN 1 ELSE 0 END) AS RowsEligibleAfterDateMatch,
    COUNT(DISTINCT CASE WHEN InventoryStatus <> 'Pending' AND COALESCE(ContainerStatus, '') <> 'Outside' AND InventorySnapshotDate = ContainerSnapshotDate THEN UnitOfMeasurePrimaryKey END) AS TotalSkusOnHandViewWouldCount,
    SUM(CASE WHEN InventoryStatus <> 'Pending' AND COALESCE(ContainerStatus, '') <> 'Outside' AND InventorySnapshotDate = ContainerSnapshotDate THEN COALESCE(Quantity, 0) ELSE 0 END) AS TotalUnitsOnHandViewWouldSum,
    COUNT(DISTINCT CASE WHEN InventoryStatus <> 'Pending' AND COALESCE(ContainerStatus, '') <> 'Outside' AND InventorySnapshotDate = ContainerSnapshotDate THEN CONCAT(ContainerPrimaryKey, '|', ContainerX, '|', ContainerY) END) AS DistinctBinsOrCompartmentsViewWouldCount
FROM InventoryJoin
GROUP BY InventorySnapshotDate
ORDER BY InventorySnapshotDate DESC;

PRINT 'Inbound source freshness and Daily KPI filter survival.';

SELECT
    'PutAwayContainers' AS SourceName,
    COUNT_BIG(*) AS Rows,
    MIN(CAST(LastUpdatedDate AS date)) AS MinSnapshotDate,
    MAX(CAST(LastUpdatedDate AS date)) AS MaxSnapshotDate,
    MIN(CAST(LastUpdatedDateInventory AS date)) AS MinBusinessLastUpdatedDate,
    MAX(CAST(LastUpdatedDateInventory AS date)) AS MaxBusinessLastUpdatedDate,
    MAX(Snapshot_Id) AS MaxSnapshotId
FROM dbo.PutAwayContainers
UNION ALL
SELECT
    'PutAwayContainerLineItems',
    COUNT_BIG(*),
    MIN(CAST(LastUpdatedDate AS date)),
    MAX(CAST(LastUpdatedDate AS date)),
    MIN(CAST(LastUpdatedDateInventory AS date)),
    MAX(CAST(LastUpdatedDateInventory AS date)),
    MAX(Snapshot_Id)
FROM dbo.PutAwayContainerLineItems
UNION ALL
SELECT
    'InventoryTasks_PutAway',
    COUNT_BIG(*),
    MIN(CAST(LastUpdatedDate AS date)),
    MAX(CAST(LastUpdatedDate AS date)),
    NULL,
    NULL,
    MAX(Snapshot_Id)
FROM dbo.InventoryTasks_PutAway
UNION ALL
SELECT
    'InventoryTasks',
    COUNT_BIG(*),
    MIN(CAST(LastUpdatedDate AS date)),
    MAX(CAST(LastUpdatedDate AS date)),
    MIN(CAST(LastUpdatedDateInventory AS date)),
    MAX(CAST(LastUpdatedDateInventory AS date)),
    MAX(Snapshot_Id)
FROM dbo.InventoryTasks;

WITH PutAwayJoin AS (
    SELECT
        CAST(pac.LastUpdatedDate AS date) AS PutAwaySnapshotDate,
        CAST(pac.LastUpdatedDateInventory AS date) AS PutAwayBusinessUpdatedDate,
        pac.PrimaryKey AS PutAwayContainerPrimaryKey,
        pac.Status AS PutAwayStatus,
        pacli.PrimaryKey AS LineItemPrimaryKey,
        pacli.UnitOfMeasurePrimaryKey,
        pacli.ActualQuantity,
        CAST(pacli.LastUpdatedDate AS date) AS LineItemSnapshotDate
    FROM dbo.PutAwayContainers pac
    LEFT JOIN dbo.PutAwayContainerLineItems pacli
        ON pacli.PutAwayContainerPrimaryKey = pac.PrimaryKey
)
SELECT
    PutAwaySnapshotDate,
    COUNT_BIG(DISTINCT PutAwayContainerPrimaryKey) AS PutAwayContainerRows,
    COUNT_BIG(DISTINCT CASE WHEN PutAwayStatus = 'Closed' THEN PutAwayContainerPrimaryKey END) AS ClosedContainers,
    COUNT_BIG(DISTINCT CASE WHEN PutAwayStatus = 'Closed' AND PutAwaySnapshotDate = PutAwayBusinessUpdatedDate THEN PutAwayContainerPrimaryKey END) AS ClosedContainersPassingOrdersPutawayViewFilter,
    COUNT_BIG(CASE WHEN PutAwayStatus = 'Closed' AND LineItemPrimaryKey IS NOT NULL THEN 1 END) AS ClosedLineRows,
    COUNT_BIG(CASE WHEN PutAwayStatus = 'Closed' AND ActualQuantity > 0 THEN 1 END) AS ClosedPositiveQtyLineRows,
    COUNT_BIG(CASE WHEN PutAwayStatus = 'Closed' AND ActualQuantity > 0 AND PutAwaySnapshotDate = LineItemSnapshotDate AND PutAwaySnapshotDate = PutAwayBusinessUpdatedDate THEN 1 END) AS LinesPassingUnitsAndSkusPutawayViewFilter,
    SUM(CASE WHEN PutAwayStatus = 'Closed' AND ActualQuantity > 0 AND PutAwaySnapshotDate = LineItemSnapshotDate AND PutAwaySnapshotDate = PutAwayBusinessUpdatedDate THEN ActualQuantity ELSE 0 END) AS UnitsPutawayViewWouldSum,
    COUNT(DISTINCT CASE WHEN PutAwayStatus = 'Closed' AND ActualQuantity > 0 AND PutAwaySnapshotDate = LineItemSnapshotDate AND PutAwaySnapshotDate = PutAwayBusinessUpdatedDate THEN UnitOfMeasurePrimaryKey END) AS SkusPutawayViewWouldCount
FROM PutAwayJoin
GROUP BY PutAwaySnapshotDate
ORDER BY PutAwaySnapshotDate DESC;

PRINT 'Closed putaway containers by alternate date basis. Use this to see whether inbound exists but falls outside the report date key.';

SELECT
    'SnapshotDate' AS DateBasis,
    CAST(LastUpdatedDate AS date) AS [Date],
    COUNT_BIG(*) AS ClosedPutAwayContainers
FROM dbo.PutAwayContainers
WHERE Status = 'Closed'
GROUP BY CAST(LastUpdatedDate AS date)
UNION ALL
SELECT
    'BusinessLastUpdatedDate',
    CAST(LastUpdatedDateInventory AS date),
    COUNT_BIG(*)
FROM dbo.PutAwayContainers
WHERE Status = 'Closed'
GROUP BY CAST(LastUpdatedDateInventory AS date)
UNION ALL
SELECT
    'CreatedDate',
    CAST(CreatedDate AS date),
    COUNT_BIG(*)
FROM dbo.PutAwayContainers
WHERE Status = 'Closed'
GROUP BY CAST(CreatedDate AS date)
ORDER BY
    [Date] DESC,
    DateBasis;
