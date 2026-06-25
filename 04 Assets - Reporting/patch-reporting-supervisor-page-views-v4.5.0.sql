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
