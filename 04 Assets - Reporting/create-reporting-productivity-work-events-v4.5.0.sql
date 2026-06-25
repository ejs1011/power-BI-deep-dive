USE [KFX_REPORTING]
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO

/*
    Experimental replacement for the Productivity by User / Port helper tables.

    This script is additive: it creates new views only. It does not change the
    shipped KPI tables or the PBIX model.

    Goal:
      Build one canonical productivity event stream, then aggregate user and port
      productivity from that single grain. This avoids mixing today-only tables,
      all-time tables, bins-per-minute math, and unrelated denominators.

    Suggested workflow:
      1. Run this script in a non-production or reviewed KFX_REPORTING database.
      2. Compare dbo.v_ProductivityByUser_New and dbo.v_ProductivityByPort_New
         to the existing Power BI Productivity page.
      3. Decide whether to re-point the report to these views or materialize them
         into replacement helper tables.
*/

CREATE OR ALTER VIEW [dbo].[v_ProductivityWorkEvents]
AS
WITH PickSessions AS (
    SELECT
        signin.PrimaryKey AS SignInPrimaryKey,
        signout.PrimaryKey AS SignOutPrimaryKey,
        signin.[User],
        signin.LocationPrimaryKey,
        CAST(signin.[TimeStamp] AS datetime2(7)) AS SignInTime,
        CAST(signout.[TimeStamp] AS datetime2(7)) AS SignOutTime
    FROM (
        SELECT
            ps.*,
            ROW_NUMBER() OVER (
                PARTITION BY ps.LocationPrimaryKey, ps.[User], CAST(ps.[TimeStamp] AS date)
                ORDER BY ps.[TimeStamp], ps.PrimaryKey
            ) AS SessionRank
        FROM dbo.[Pick-SignIn] ps
        WHERE ps.[User] IS NOT NULL
    ) signin
    INNER JOIN (
        SELECT
            ps.*,
            ROW_NUMBER() OVER (
                PARTITION BY ps.LocationPrimaryKey, ps.[User], CAST(ps.[TimeStamp] AS date)
                ORDER BY ps.[TimeStamp], ps.PrimaryKey
            ) AS SessionRank
        FROM dbo.[Pick-SignOut] ps
        WHERE ps.[User] IS NOT NULL
    ) signout
        ON signout.LocationPrimaryKey = signin.LocationPrimaryKey
        AND signout.[User] = signin.[User]
        AND signout.SessionRank = signin.SessionRank
        AND CAST(signout.[TimeStamp] AS date) = CAST(signin.[TimeStamp] AS date)
        AND signout.[TimeStamp] > signin.[TimeStamp]
),
BinEvents AS (
    SELECT
        CAST('BIN_PRESENTATION' AS varchar(40)) AS EventType,
        CAST(bp.PrimaryKey AS varchar(100)) AS EventKey,
        COALESCE(session_match.[User], pick_match.[User]) AS [User],
        bp.LocationBarcode AS Port,
        CAST(bp.[TimeStamp] AS datetime2(7)) AS StartTime,
        CAST(close_match.CloseTime AS datetime2(7)) AS EndTime,
        CASE
            WHEN close_match.CloseTime IS NOT NULL
                AND close_match.CloseTime >= bp.[TimeStamp]
            THEN DATEDIFF(second, bp.[TimeStamp], close_match.CloseTime)
            WHEN TRY_CAST(bp.BinActionTime AS time(7)) IS NOT NULL
            THEN DATEDIFF(second, CAST('00:00:00' AS time), TRY_CAST(bp.BinActionTime AS time(7)))
            ELSE NULL
        END AS DurationSeconds,
        CASE
            WHEN TRY_CAST(bp.BinActionTime AS time(7)) IS NOT NULL
            THEN DATEDIFF(second, CAST('00:00:00' AS time), TRY_CAST(bp.BinActionTime AS time(7)))
            ELSE NULL
        END AS MachineWaitSeconds,
        CAST(0 AS int) AS OrderCompletedCount,
        CAST(1 AS int) AS BinPresentationCount,
        CAST(0 AS int) AS LineCompletedCount,
        CAST(0 AS bigint) AS UnitCompletedCount,
        bp.PrimaryKey AS SourcePrimaryKey,
        CAST(NULL AS bigint) AS FulfillmentOrderPrimaryKey,
        CAST(NULL AS bigint) AS FulfillmentOrderLinePrimaryKey,
        CAST(bp.ContainerBarcode AS varchar(100)) AS ContainerBarcode,
        CAST(
            CASE
                WHEN session_match.[User] IS NOT NULL THEN 'Pick session'
                WHEN pick_match.[User] IS NOT NULL THEN 'Nearest pick by container'
                ELSE 'Unattributed'
            END
            AS varchar(50)
        ) AS AttributionMethod
    FROM dbo.BinPresented bp
    OUTER APPLY (
        SELECT TOP (1)
            ps.[User]
        FROM PickSessions ps
        WHERE ps.LocationPrimaryKey = bp.LocationPrimaryKey
          AND CAST(bp.[TimeStamp] AS datetime2(7)) >= ps.SignInTime
          AND CAST(bp.[TimeStamp] AS datetime2(7)) <= ps.SignOutTime
        ORDER BY ps.SignInTime DESC
    ) session_match
    OUTER APPLY (
        SELECT TOP (1)
            p.[User]
        FROM dbo.Pick p
        WHERE p.ContainerBarcode = bp.ContainerBarcode
          AND p.[User] IS NOT NULL
          AND p.[TimeStamp] >= bp.[TimeStamp]
        ORDER BY p.[TimeStamp]
    ) pick_match
    OUTER APPLY (
        SELECT TOP (1)
            cb.[TimeStamp] AS CloseTime
        FROM dbo.CloseBin cb
        WHERE cb.ContainerBarcode = bp.ContainerBarcode
          AND (cb.LocationPrimaryKey = bp.LocationPrimaryKey OR cb.LocationPrimaryKey IS NULL OR bp.LocationPrimaryKey IS NULL)
          AND cb.[TimeStamp] >= bp.[TimeStamp]
        ORDER BY cb.[TimeStamp], cb.PrimaryKey
    ) close_match
    WHERE bp.LocationTaskType IN ('Pick', 'OnDemand')
),
PickEvents AS (
    SELECT
        CAST('PICK_COMPLETED' AS varchar(40)) AS EventType,
        CAST(p.PrimaryKey AS varchar(100)) AS EventKey,
        p.[User],
        p.LocationBarcode AS Port,
        CAST(p.[TimeStamp] AS datetime2(7)) AS StartTime,
        CAST(COALESCE(p.PickCompleteDate, p.[TimeStamp]) AS datetime2(7)) AS EndTime,
        CASE
            WHEN p.PickCompleteDate IS NOT NULL
                 AND p.PickCompleteDate >= p.[TimeStamp]
            THEN DATEDIFF(second, p.[TimeStamp], p.PickCompleteDate)
            ELSE NULL
        END AS DurationSeconds,
        CAST(NULL AS int) AS MachineWaitSeconds,
        CAST(0 AS int) AS OrderCompletedCount,
        CAST(0 AS int) AS BinPresentationCount,
        CAST(CASE WHEN p.PickPrimaryKey IS NOT NULL OR p.PercentOfOrderLine IS NOT NULL THEN 1 ELSE 0 END AS int) AS LineCompletedCount,
        CAST(CASE WHEN COALESCE(p.ActualPickQuantity, 0) >= COALESCE(p.RequiredPickQuantity, 0)
                  THEN COALESCE(p.ActualPickQuantity, 0)
                  ELSE 0
             END AS bigint) AS UnitCompletedCount,
        p.PrimaryKey AS SourcePrimaryKey,
        CAST(p.TransportOrderPrimaryKey AS bigint) AS FulfillmentOrderPrimaryKey,
        CAST(p.PickPrimaryKey AS bigint) AS FulfillmentOrderLinePrimaryKey,
        CAST(p.ContainerBarcode AS varchar(100)) AS ContainerBarcode,
        CAST('Pick row' AS varchar(50)) AS AttributionMethod
    FROM dbo.Pick p
    WHERE p.[User] IS NOT NULL
),
CompletedOrders AS (
    SELECT
        fosh.FulfillmentOrderPrimaryKey,
        fosh.[User],
        CAST(fosh.StatusDate AS datetime2(7)) AS CompletedTime,
        ROW_NUMBER() OVER (
            PARTITION BY fosh.FulfillmentOrderPrimaryKey, fosh.[User], CAST(fosh.StatusDate AS date)
            ORDER BY fosh.StatusDate DESC, fosh.PrimaryKey DESC
        ) AS CompleteRank
    FROM dbo.FulfillmentOrderStatusHistory fosh
    WHERE fosh.Status = 'Completed'
),
OrderEvents AS (
    SELECT
        CAST('ORDER_COMPLETED' AS varchar(40)) AS EventType,
        CAST(co.FulfillmentOrderPrimaryKey AS varchar(100)) + ':' + COALESCE(co.[User], '') + ':' + COALESCE(port_map.Port, '') AS EventKey,
        co.[User],
        port_map.Port,
        co.CompletedTime AS StartTime,
        co.CompletedTime AS EndTime,
        CAST(NULL AS int) AS DurationSeconds,
        CAST(NULL AS int) AS MachineWaitSeconds,
        CAST(1 AS int) AS OrderCompletedCount,
        CAST(0 AS int) AS BinPresentationCount,
        CAST(0 AS int) AS LineCompletedCount,
        CAST(0 AS bigint) AS UnitCompletedCount,
        CAST(co.FulfillmentOrderPrimaryKey AS bigint) AS SourcePrimaryKey,
        CAST(co.FulfillmentOrderPrimaryKey AS bigint) AS FulfillmentOrderPrimaryKey,
        CAST(NULL AS bigint) AS FulfillmentOrderLinePrimaryKey,
        CAST(NULL AS varchar(100)) AS ContainerBarcode,
        CAST('Completed status history' AS varchar(50)) AS AttributionMethod
    FROM CompletedOrders co
    OUTER APPLY (
        SELECT TOP (1)
            p.LocationBarcode AS Port
        FROM dbo.FulfillmentOrders fo
        INNER JOIN dbo.Pick p
            ON p.OrderNumber = fo.ExternalOrderNumber
        WHERE fo.PrimaryKey = co.FulfillmentOrderPrimaryKey
          AND p.LocationBarcode IS NOT NULL
        GROUP BY p.LocationBarcode
        ORDER BY COUNT_BIG(*) DESC, p.LocationBarcode
    ) port_map
    WHERE co.CompleteRank = 1
)
SELECT
    EventType,
    EventKey,
    [User],
    Port,
    CAST(StartTime AS date) AS EventDate,
    StartTime,
    EndTime,
    DurationSeconds,
    MachineWaitSeconds,
    OrderCompletedCount,
    BinPresentationCount,
    LineCompletedCount,
    UnitCompletedCount,
    SourcePrimaryKey,
    FulfillmentOrderPrimaryKey,
    FulfillmentOrderLinePrimaryKey,
    ContainerBarcode,
    AttributionMethod
FROM BinEvents
UNION ALL
SELECT
    EventType,
    EventKey,
    [User],
    Port,
    CAST(StartTime AS date) AS EventDate,
    StartTime,
    EndTime,
    DurationSeconds,
    MachineWaitSeconds,
    OrderCompletedCount,
    BinPresentationCount,
    LineCompletedCount,
    UnitCompletedCount,
    SourcePrimaryKey,
    FulfillmentOrderPrimaryKey,
    FulfillmentOrderLinePrimaryKey,
    ContainerBarcode,
    AttributionMethod
FROM PickEvents
UNION ALL
SELECT
    EventType,
    EventKey,
    [User],
    Port,
    CAST(StartTime AS date) AS EventDate,
    StartTime,
    EndTime,
    DurationSeconds,
    MachineWaitSeconds,
    OrderCompletedCount,
    BinPresentationCount,
    LineCompletedCount,
    UnitCompletedCount,
    SourcePrimaryKey,
    FulfillmentOrderPrimaryKey,
    FulfillmentOrderLinePrimaryKey,
    ContainerBarcode,
    AttributionMethod
FROM OrderEvents;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityByUser_New]
AS
SELECT
    [User] AS Users,
    SUM(OrderCompletedCount) AS OrdersCompleted,
    SUM(BinPresentationCount) AS BinPresentationsCompleted,
    SUM(LineCompletedCount) AS LinesCompleted,
    SUM(UnitCompletedCount) AS UnitsCompleted,
    CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0 AS TotalLoggedHours,
    CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 60.0 AS TotalLoggedMinutes,
    CAST(SUM(COALESCE(MachineWaitSeconds, 0)) AS decimal(19, 4)) / 60.0 AS MachineWaitMinutes,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(OrderCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS OrdersPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(BinPresentationCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS BinsPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(UnitCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS UnitsPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(LineCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS LinesPerHour,
    CASE WHEN SUM(BinPresentationCount) > 0
         THEN (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 60.0) / SUM(BinPresentationCount)
         ELSE NULL END AS AverageHandleTimePerPresentationMinutes,
    COUNT_BIG(*) AS EventRows,
    SUM(CASE WHEN AttributionMethod = 'Unattributed' THEN 1 ELSE 0 END) AS UnattributedEventRows
FROM dbo.v_ProductivityWorkEvents
WHERE [User] IS NOT NULL
GROUP BY [User];
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityByPort_New]
AS
SELECT
    COALESCE(Port, 'Unattributed') AS Ports,
    SUM(OrderCompletedCount) AS OrdersCompleted,
    SUM(BinPresentationCount) AS BinPresentationsCompleted,
    SUM(LineCompletedCount) AS LinesCompleted,
    SUM(UnitCompletedCount) AS UnitsCompleted,
    CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0 AS TotalLoggedHours,
    CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 60.0 AS TotalLoggedMinutes,
    CAST(SUM(COALESCE(MachineWaitSeconds, 0)) AS decimal(19, 4)) / 60.0 AS MachineWaitMinutes,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(OrderCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS OrdersPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(BinPresentationCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS BinsPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(UnitCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS UnitsPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(LineCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS LinesPerHour,
    CASE WHEN SUM(BinPresentationCount) > 0
         THEN (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 60.0) / SUM(BinPresentationCount)
         ELSE NULL END AS AverageHandleTimePerPresentationMinutes,
    COUNT_BIG(*) AS EventRows,
    SUM(CASE WHEN AttributionMethod = 'Unattributed' THEN 1 ELSE 0 END) AS UnattributedEventRows
FROM dbo.v_ProductivityWorkEvents
GROUP BY COALESCE(Port, 'Unattributed');
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityByUserDate_New]
AS
SELECT
    EventDate,
    [User] AS Users,
    SUM(OrderCompletedCount) AS OrdersCompleted,
    SUM(BinPresentationCount) AS BinPresentationsCompleted,
    SUM(LineCompletedCount) AS LinesCompleted,
    SUM(UnitCompletedCount) AS UnitsCompleted,
    CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0 AS TotalLoggedHours,
    CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 60.0 AS TotalLoggedMinutes,
    CAST(SUM(COALESCE(MachineWaitSeconds, 0)) AS decimal(19, 4)) / 60.0 AS MachineWaitMinutes,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(OrderCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS OrdersPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(BinPresentationCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS BinsPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(UnitCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS UnitsPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(LineCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS LinesPerHour,
    CASE WHEN SUM(BinPresentationCount) > 0
         THEN (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 60.0) / SUM(BinPresentationCount)
         ELSE NULL END AS AverageHandleTimePerPresentationMinutes,
    COUNT_BIG(*) AS EventRows,
    SUM(CASE WHEN AttributionMethod = 'Unattributed' THEN 1 ELSE 0 END) AS UnattributedEventRows
FROM dbo.v_ProductivityWorkEvents
WHERE [User] IS NOT NULL
GROUP BY EventDate, [User];
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityByPortDate_New]
AS
SELECT
    EventDate,
    COALESCE(Port, 'Unattributed') AS Ports,
    SUM(OrderCompletedCount) AS OrdersCompleted,
    SUM(BinPresentationCount) AS BinPresentationsCompleted,
    SUM(LineCompletedCount) AS LinesCompleted,
    SUM(UnitCompletedCount) AS UnitsCompleted,
    CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0 AS TotalLoggedHours,
    CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 60.0 AS TotalLoggedMinutes,
    CAST(SUM(COALESCE(MachineWaitSeconds, 0)) AS decimal(19, 4)) / 60.0 AS MachineWaitMinutes,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(OrderCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS OrdersPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(BinPresentationCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS BinsPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(UnitCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS UnitsPerHour,
    CASE WHEN SUM(COALESCE(DurationSeconds, 0)) > 0
         THEN SUM(LineCompletedCount) / (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 3600.0)
         ELSE NULL END AS LinesPerHour,
    CASE WHEN SUM(BinPresentationCount) > 0
         THEN (CAST(SUM(COALESCE(DurationSeconds, 0)) AS decimal(19, 4)) / 60.0) / SUM(BinPresentationCount)
         ELSE NULL END AS AverageHandleTimePerPresentationMinutes,
    COUNT_BIG(*) AS EventRows,
    SUM(CASE WHEN AttributionMethod = 'Unattributed' THEN 1 ELSE 0 END) AS UnattributedEventRows
FROM dbo.v_ProductivityWorkEvents
GROUP BY EventDate, COALESCE(Port, 'Unattributed');
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivitySourceDiagnostics]
AS
SELECT
    CAST('Pick' AS varchar(80)) AS SourceName,
    COUNT_BIG(*) AS TotalRows,
    SUM(CASE WHEN [User] IS NOT NULL THEN 1 ELSE 0 END) AS RowsWithUser,
    SUM(CASE WHEN LocationBarcode IS NOT NULL THEN 1 ELSE 0 END) AS RowsWithPort,
    SUM(CASE WHEN [TimeStamp] IS NOT NULL THEN 1 ELSE 0 END) AS RowsWithTimestamp,
    MIN(CAST([TimeStamp] AS datetime2(7))) AS MinTimestamp,
    MAX(CAST([TimeStamp] AS datetime2(7))) AS MaxTimestamp
FROM dbo.Pick
UNION ALL
SELECT
    'BinPresented',
    COUNT_BIG(*),
    CAST(NULL AS int),
    SUM(CASE WHEN LocationBarcode IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN [TimeStamp] IS NOT NULL THEN 1 ELSE 0 END),
    MIN(CAST([TimeStamp] AS datetime2(7))),
    MAX(CAST([TimeStamp] AS datetime2(7)))
FROM dbo.BinPresented
UNION ALL
SELECT
    'CloseBin',
    COUNT_BIG(*),
    CAST(NULL AS int),
    SUM(CASE WHEN LocationBarcode IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN [TimeStamp] IS NOT NULL THEN 1 ELSE 0 END),
    MIN(CAST([TimeStamp] AS datetime2(7))),
    MAX(CAST([TimeStamp] AS datetime2(7)))
FROM dbo.CloseBin
UNION ALL
SELECT
    'Pick-SignIn',
    COUNT_BIG(*),
    SUM(CASE WHEN [User] IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN LocationPrimaryKey IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN [TimeStamp] IS NOT NULL THEN 1 ELSE 0 END),
    MIN(CAST([TimeStamp] AS datetime2(7))),
    MAX(CAST([TimeStamp] AS datetime2(7)))
FROM dbo.[Pick-SignIn]
UNION ALL
SELECT
    'Pick-SignOut',
    COUNT_BIG(*),
    SUM(CASE WHEN [User] IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN LocationPrimaryKey IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN [TimeStamp] IS NOT NULL THEN 1 ELSE 0 END),
    MIN(CAST([TimeStamp] AS datetime2(7))),
    MAX(CAST([TimeStamp] AS datetime2(7)))
FROM dbo.[Pick-SignOut]
UNION ALL
SELECT
    'FulfillmentOrderStatusHistory Completed',
    COUNT_BIG(*),
    SUM(CASE WHEN [User] IS NOT NULL THEN 1 ELSE 0 END),
    CAST(NULL AS int),
    SUM(CASE WHEN StatusDate IS NOT NULL THEN 1 ELSE 0 END),
    MIN(CAST(StatusDate AS datetime2(7))),
    MAX(CAST(StatusDate AS datetime2(7)))
FROM dbo.FulfillmentOrderStatusHistory
WHERE Status = 'Completed';
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityBinTaskTypeDiagnostics]
AS
SELECT
    COALESCE(LocationTaskType, '(NULL)') AS LocationTaskType,
    COUNT_BIG(*) AS Rows,
    SUM(CASE WHEN LocationBarcode IS NOT NULL THEN 1 ELSE 0 END) AS RowsWithPort,
    MIN(CAST([TimeStamp] AS datetime2(7))) AS MinTimestamp,
    MAX(CAST([TimeStamp] AS datetime2(7))) AS MaxTimestamp
FROM dbo.BinPresented
GROUP BY COALESCE(LocationTaskType, '(NULL)');
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityEventDiagnostics]
AS
SELECT
    EventType,
    AttributionMethod,
    COUNT_BIG(*) AS EventRows,
    SUM(CASE WHEN [User] IS NOT NULL THEN 1 ELSE 0 END) AS RowsWithUser,
    SUM(CASE WHEN Port IS NOT NULL THEN 1 ELSE 0 END) AS RowsWithPort,
    SUM(CASE WHEN DurationSeconds IS NOT NULL THEN 1 ELSE 0 END) AS RowsWithDuration,
    MIN(StartTime) AS MinStartTime,
    MAX(StartTime) AS MaxStartTime
FROM dbo.v_ProductivityWorkEvents
GROUP BY EventType, AttributionMethod;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityReportDataDiagnostics]
AS
SELECT
    COALESCE(DataDescription, '(NULL)') AS DataDescription,
    COUNT_BIG(*) AS Rows,
    MIN(PrimaryKey) AS MinPrimaryKey,
    MAX(PrimaryKey) AS MaxPrimaryKey,
    MIN([TimeStamp]) AS MinTimestamp,
    MAX([TimeStamp]) AS MaxTimestamp,
    MIN(BatchId) AS MinBatchId,
    MAX(BatchId) AS MaxBatchId
FROM dbo.Report_Data
GROUP BY COALESCE(DataDescription, '(NULL)');
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivitySyncDiagnostics]
AS
SELECT TOP (200)
    Id,
    JobName,
    DatabaseName,
    TableName,
    BatchId,
    StartPrimaryKey,
    EndPrimaryKey,
    SyncStartTime,
    SyncEndTime,
    IsStarted,
    IsCompleted,
    TotalRecordSource,
    TotalRecordSynced,
    IsDeleted
FROM dbo.DataSyncDetail
WHERE
    JobName IN ('TableSync', 'DynamicTableInsert', 'DeleteDynamicData')
    OR TableName IN (
        'ReportedMetrics',
        'ContainerCompartmentBarcodes',
        'ContainerTemplateCompartments',
        'InventoryTaskActions',
        'TaskCategories'
    )
ORDER BY Id DESC;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityComparison_User]
AS
SELECT
    COALESCE(n.Users, o.Users) AS Users,
    o.OrdersCompleted AS OldOrdersCompleted,
    n.OrdersCompleted AS NewOrdersCompleted,
    o.BinPresentationsCompleted AS OldBinPresentationsCompleted,
    n.BinPresentationsCompleted AS NewBinPresentationsCompleted,
    o.LinesCompleted AS OldLinesCompleted,
    n.LinesCompleted AS NewLinesCompleted,
    o.UnitsCompleted AS OldUnitsCompleted,
    n.UnitsCompleted AS NewUnitsCompleted,
    o.OrdersPerHourPerUser AS OldOrdersPerHour,
    n.OrdersPerHour AS NewOrdersPerHour,
    o.BinsPerHour AS OldBinsPerHour,
    n.BinsPerHour AS NewBinsPerHour,
    o.UnitsPerHour AS OldUnitsPerHour,
    n.UnitsPerHour AS NewUnitsPerHour,
    o.LinesPerHour AS OldLinesPerHour,
    n.LinesPerHour AS NewLinesPerHour,
    o.MachineWaitTime AS OldMachineWaitTime,
    n.MachineWaitMinutes AS NewMachineWaitMinutes,
    o.AverageHandlingTime AS OldAverageHandleTime,
    n.AverageHandleTimePerPresentationMinutes AS NewAverageHandleTimePerPresentationMinutes,
    o.TotalLoggedTime AS OldTotalLoggedTime,
    n.TotalLoggedMinutes AS NewTotalLoggedMinutes,
    n.EventRows,
    n.UnattributedEventRows
FROM (
    SELECT
        du.Users,
        oc.OrdersCompleted,
        bp.BinPresentationsCompleted,
        lc.LinesCompleted,
        uc.UnitsCompleted,
        oph.OrdersPerHourPerUser,
        bph.BinsPerHour,
        uph.UnitsPerHour,
        lph.LinesPerHour,
        mw.MachineWaitTime,
        aht.AverageHandlingTime,
        tlt.TotalLoggedTime
    FROM (
        SELECT Users FROM dbo.AverageHandlingTimePerUser
        UNION SELECT Users FROM dbo.BinPresentationsCompletedPerUser
        UNION SELECT Users FROM dbo.BinsPerHourPerUser
        UNION SELECT Users FROM dbo.LinesCompletedPerUser
        UNION SELECT Users FROM dbo.LinesperHourPerUser
        UNION SELECT Users FROM dbo.MachineWaitTimePerUser
        UNION SELECT Users FROM dbo.OrdersCompletedPerUser
        UNION SELECT Users FROM dbo.OrdersPerHourPerUser
        UNION SELECT Users FROM dbo.TotalLoggedTimePerUser
        UNION SELECT Users FROM dbo.UnitsCompletedPerUser
        UNION SELECT Users FROM dbo.UnitsPerHourPerUser
    ) du
    LEFT JOIN dbo.OrdersCompletedPerUser oc ON oc.Users = du.Users
    LEFT JOIN dbo.BinPresentationsCompletedPerUser bp ON bp.Users = du.Users
    LEFT JOIN dbo.LinesCompletedPerUser lc ON lc.Users = du.Users
    LEFT JOIN dbo.UnitsCompletedPerUser uc ON uc.Users = du.Users
    LEFT JOIN dbo.OrdersPerHourPerUser oph ON oph.Users = du.Users
    LEFT JOIN dbo.BinsPerHourPerUser bph ON bph.Users = du.Users
    LEFT JOIN dbo.UnitsPerHourPerUser uph ON uph.Users = du.Users
    LEFT JOIN dbo.LinesperHourPerUser lph ON lph.Users = du.Users
    LEFT JOIN dbo.MachineWaitTimePerUser mw ON mw.Users = du.Users
    LEFT JOIN dbo.AverageHandlingTimePerUser aht ON aht.Users = du.Users
    LEFT JOIN dbo.TotalLoggedTimePerUser tlt ON tlt.Users = du.Users
) o
FULL OUTER JOIN dbo.v_ProductivityByUser_New n
    ON n.Users = o.Users;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityComparison_Port]
AS
SELECT
    COALESCE(n.Ports, o.Ports) AS Ports,
    o.OrdersCompleted AS OldOrdersCompleted,
    n.OrdersCompleted AS NewOrdersCompleted,
    o.BinPresentationsCompleted AS OldBinPresentationsCompleted,
    n.BinPresentationsCompleted AS NewBinPresentationsCompleted,
    o.LinesCompleted AS OldLinesCompleted,
    n.LinesCompleted AS NewLinesCompleted,
    o.UnitsCompleted AS OldUnitsCompleted,
    n.UnitsCompleted AS NewUnitsCompleted,
    o.OrdersPerHourPerPort AS OldOrdersPerHour,
    n.OrdersPerHour AS NewOrdersPerHour,
    o.BinsPerHour AS OldBinsPerHour,
    n.BinsPerHour AS NewBinsPerHour,
    o.UnitsPerHour AS OldUnitsPerHour,
    n.UnitsPerHour AS NewUnitsPerHour,
    o.LinesPerHour AS OldLinesPerHour,
    n.LinesPerHour AS NewLinesPerHour,
    o.MachineWaitTime AS OldMachineWaitTime,
    n.MachineWaitMinutes AS NewMachineWaitMinutes,
    o.AverageHandlingTime AS OldAverageHandleTime,
    n.AverageHandleTimePerPresentationMinutes AS NewAverageHandleTimePerPresentationMinutes,
    o.TotalLoggedTime AS OldTotalLoggedTime,
    n.TotalLoggedMinutes AS NewTotalLoggedMinutes,
    n.EventRows,
    n.UnattributedEventRows
FROM (
    SELECT
        dp.Ports,
        oc.OrdersCompleted,
        bp.BinPresentationsCompleted,
        lc.LinesCompleted,
        uc.UnitsCompleted,
        oph.OrdersPerHourPerPort,
        bph.BinsPerHour,
        uph.UnitsPerHour,
        lph.LinesPerHour,
        mw.MachineWaitTime,
        aht.AverageHandlingTime,
        tlt.TotalLoggedTime
    FROM (
        SELECT Ports FROM dbo.AverageHandlingTimePerPort
        UNION SELECT Ports FROM dbo.BinPresentationsCompletedPerPort
        UNION SELECT Ports FROM dbo.BinsPerHourPerPort
        UNION SELECT Ports FROM dbo.LinesCompletedPerPort
        UNION SELECT Ports FROM dbo.LinesperHourPerPort
        UNION SELECT Ports FROM dbo.MachineWaitTimePerPort
        UNION SELECT Ports FROM dbo.OrdersCompletedPerPort
        UNION SELECT Ports FROM dbo.OrdersPerHourPerPort
        UNION SELECT Ports FROM dbo.TotalLoggedTimePerPort
        UNION SELECT Ports FROM dbo.UnitsCompletedPerPort
        UNION SELECT Ports FROM dbo.UnitsPerHourPerPort
    ) dp
    LEFT JOIN dbo.OrdersCompletedPerPort oc ON oc.Ports = dp.Ports
    LEFT JOIN dbo.BinPresentationsCompletedPerPort bp ON bp.Ports = dp.Ports
    LEFT JOIN dbo.LinesCompletedPerPort lc ON lc.Ports = dp.Ports
    LEFT JOIN dbo.UnitsCompletedPerPort uc ON uc.Ports = dp.Ports
    LEFT JOIN dbo.OrdersPerHourPerPort oph ON oph.Ports = dp.Ports
    LEFT JOIN dbo.BinsPerHourPerPort bph ON bph.Ports = dp.Ports
    LEFT JOIN dbo.UnitsPerHourPerPort uph ON uph.Ports = dp.Ports
    LEFT JOIN dbo.LinesperHourPerPort lph ON lph.Ports = dp.Ports
    LEFT JOIN dbo.MachineWaitTimePerPort mw ON mw.Ports = dp.Ports
    LEFT JOIN dbo.AverageHandlingTimePerPort aht ON aht.Ports = dp.Ports
    LEFT JOIN dbo.TotalLoggedTimePerPort tlt ON tlt.Ports = dp.Ports
) o
FULL OUTER JOIN dbo.v_ProductivityByPort_New n
    ON n.Ports = o.Ports;
GO

/*
    Second-generation additive views.

    The original candidate view above focused on pick/on-demand rows. These v2
    views keep the same safety boundary, but make the grain and denominator
    explicit:

      - one row per source work event or paired login session
      - WorkType identifies Pick, PutAway, CycleCount, OnDemand, etc.
      - RateDenominatorSeconds comes only from paired SignIn/SignOut sessions
      - HandleSeconds comes from BinPresented -> CloseBin handling windows
      - order, line, unit, and bin counts are flags on the same event stream

    If session rows are absent, aggregate views expose HANDLE_FALLBACK as the
    rate denominator source. That is a diagnostic clue, not a preferred final
    definition.
*/

CREATE OR ALTER VIEW [dbo].[v_ProductivityLocationMap]
AS
WITH LocationCandidates AS (
    SELECT
        LocationPrimaryKey,
        LocationBarcode,
        CAST([TimeStamp] AS datetime2(7)) AS EventTime
    FROM dbo.BinPresented
    WHERE LocationPrimaryKey IS NOT NULL
      AND LocationBarcode IS NOT NULL
    UNION ALL
    SELECT
        LocationPrimaryKey,
        LocationBarcode,
        CAST([TimeStamp] AS datetime2(7))
    FROM dbo.OpenBin
    WHERE LocationPrimaryKey IS NOT NULL
      AND LocationBarcode IS NOT NULL
    UNION ALL
    SELECT
        LocationPrimaryKey,
        LocationBarcode,
        CAST([TimeStamp] AS datetime2(7))
    FROM dbo.CloseBin
    WHERE LocationPrimaryKey IS NOT NULL
      AND LocationBarcode IS NOT NULL
),
LocationCounts AS (
    SELECT
        LocationPrimaryKey,
        LocationBarcode,
        COUNT_BIG(*) AS SeenRows,
        MAX(EventTime) AS LastSeenTime
    FROM LocationCandidates
    GROUP BY LocationPrimaryKey, LocationBarcode
),
RankedLocations AS (
    SELECT
        LocationPrimaryKey,
        LocationBarcode,
        SeenRows,
        LastSeenTime,
        ROW_NUMBER() OVER (
            PARTITION BY LocationPrimaryKey
            ORDER BY SeenRows DESC, LastSeenTime DESC, LocationBarcode
        ) AS LocationRank
    FROM LocationCounts
)
SELECT
    LocationPrimaryKey,
    LocationBarcode,
    SeenRows,
    LastSeenTime
FROM RankedLocations
WHERE LocationRank = 1;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityWorkSessions]
AS
WITH SignIns AS (
    SELECT 'Pick' AS WorkType, PrimaryKey, [TimeStamp], LocationPrimaryKey, [User]
    FROM dbo.[Pick-SignIn]
    UNION ALL
    SELECT 'PutAway', PrimaryKey, CAST([TimeStamp] AS datetime2(7)), LocationPrimaryKey, [User]
    FROM dbo.[PutAway-SignIn]
    UNION ALL
    SELECT 'CycleCount', PrimaryKey, CAST([TimeStamp] AS datetime2(7)), LocationPrimaryKey, [User]
    FROM dbo.[CycleCount-SignIn]
    UNION ALL
    SELECT 'OnDemand', PrimaryKey, CAST([TimeStamp] AS datetime2(7)), LocationPrimaryKey, [User]
    FROM dbo.[OnDemand-SignIn]
),
SignOuts AS (
    SELECT 'Pick' AS WorkType, PrimaryKey, [TimeStamp], LocationPrimaryKey, [User]
    FROM dbo.[Pick-SignOut]
    UNION ALL
    SELECT 'PutAway', PrimaryKey, CAST([TimeStamp] AS datetime2(7)), LocationPrimaryKey, [User]
    FROM dbo.[PutAway-SignOut]
    UNION ALL
    SELECT 'CycleCount', PrimaryKey, CAST([TimeStamp] AS datetime2(7)), LocationPrimaryKey, [User]
    FROM dbo.[CycleCount-SignOut]
    UNION ALL
    SELECT 'OnDemand', PrimaryKey, CAST([TimeStamp] AS datetime2(7)), LocationPrimaryKey, [User]
    FROM dbo.[OnDemand-SignOut]
),
RankedSignIns AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY WorkType, LocationPrimaryKey, [User], CAST([TimeStamp] AS date)
            ORDER BY [TimeStamp], PrimaryKey
        ) AS SessionRank
    FROM SignIns
    WHERE [User] IS NOT NULL
),
RankedSignOuts AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY WorkType, LocationPrimaryKey, [User], CAST([TimeStamp] AS date)
            ORDER BY [TimeStamp], PrimaryKey
        ) AS SessionRank
    FROM SignOuts
    WHERE [User] IS NOT NULL
)
SELECT
    signin.WorkType,
    signin.PrimaryKey AS SignInPrimaryKey,
    signout.PrimaryKey AS SignOutPrimaryKey,
    signin.[User],
    signin.LocationPrimaryKey,
    lm.LocationBarcode AS Port,
    CAST(signin.[TimeStamp] AS datetime2(7)) AS SignInTime,
    CAST(signout.[TimeStamp] AS datetime2(7)) AS SignOutTime,
    CAST(
        CASE
            WHEN signout.[TimeStamp] > signin.[TimeStamp]
            THEN DATEDIFF_BIG(millisecond, signin.[TimeStamp], signout.[TimeStamp]) / 1000.0
            ELSE NULL
        END
        AS decimal(19, 3)
    ) AS SessionSeconds
FROM RankedSignIns signin
INNER JOIN RankedSignOuts signout
    ON signout.WorkType = signin.WorkType
    AND signout.LocationPrimaryKey = signin.LocationPrimaryKey
    AND signout.[User] = signin.[User]
    AND signout.SessionRank = signin.SessionRank
    AND CAST(signout.[TimeStamp] AS date) = CAST(signin.[TimeStamp] AS date)
    AND signout.[TimeStamp] > signin.[TimeStamp]
LEFT JOIN dbo.v_ProductivityLocationMap lm
    ON lm.LocationPrimaryKey = signin.LocationPrimaryKey;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityWorkEvents_v2]
AS
WITH SessionEvents AS (
    SELECT
        CAST(ws.WorkType AS varchar(50)) AS WorkType,
        CAST('SESSION' AS varchar(50)) AS EventType,
        CAST(CONCAT(ws.WorkType, ':', ws.SignInPrimaryKey, ':', ws.SignOutPrimaryKey) AS varchar(120)) AS EventKey,
        ws.[User],
        ws.Port,
        CAST(ws.SignInTime AS date) AS EventDate,
        ws.SignInTime AS StartTime,
        ws.SignOutTime AS EndTime,
        ws.SessionSeconds AS DurationSeconds,
        ws.SessionSeconds AS RateDenominatorSeconds,
        CAST(0 AS decimal(19, 3)) AS HandleSeconds,
        CAST(0 AS decimal(19, 3)) AS MachineWaitSeconds,
        CAST(0 AS int) AS OrderCompletedCount,
        CAST(0 AS int) AS BinPresentationCount,
        CAST(0 AS int) AS LineCompletedCount,
        CAST(0 AS bigint) AS UnitCompletedCount,
        CAST(CONCAT(ws.WorkType, '-Session') AS varchar(80)) AS SourceName,
        ws.SignInPrimaryKey AS SourcePrimaryKey,
        CAST(NULL AS bigint) AS FulfillmentOrderPrimaryKey,
        CAST(NULL AS bigint) AS FulfillmentOrderLinePrimaryKey,
        CAST(NULL AS varchar(100)) AS ContainerBarcode,
        CAST('Paired SignIn/SignOut' AS varchar(100)) AS AttributionMethod
    FROM dbo.v_ProductivityWorkSessions ws
    WHERE ws.SessionSeconds IS NOT NULL
),
BinEvents AS (
    SELECT
        CAST(COALESCE(NULLIF(bp.LocationTaskType, ''), 'Unknown') AS varchar(50)) AS WorkType,
        CAST('BIN_PRESENTATION' AS varchar(50)) AS EventType,
        CAST(bp.PrimaryKey AS varchar(120)) AS EventKey,
        COALESCE(session_match.[User], pick_match.[User]) AS [User],
        bp.LocationBarcode AS Port,
        CAST(bp.[TimeStamp] AS date) AS EventDate,
        CAST(bp.[TimeStamp] AS datetime2(7)) AS StartTime,
        CAST(close_match.CloseTime AS datetime2(7)) AS EndTime,
        CAST(
            CASE
                WHEN close_match.CloseTime IS NOT NULL
                    AND close_match.CloseTime >= bp.[TimeStamp]
                THEN DATEDIFF_BIG(millisecond, bp.[TimeStamp], close_match.CloseTime) / 1000.0
                WHEN TRY_CAST(bp.BinActionTime AS time(7)) IS NOT NULL
                THEN DATEDIFF_BIG(millisecond, CAST('00:00:00' AS time), TRY_CAST(bp.BinActionTime AS time(7))) / 1000.0
                ELSE NULL
            END
            AS decimal(19, 3)
        ) AS DurationSeconds,
        CAST(0 AS decimal(19, 3)) AS RateDenominatorSeconds,
        CAST(
            CASE
                WHEN close_match.CloseTime IS NOT NULL
                    AND close_match.CloseTime >= bp.[TimeStamp]
                THEN DATEDIFF_BIG(millisecond, bp.[TimeStamp], close_match.CloseTime) / 1000.0
                WHEN TRY_CAST(bp.BinActionTime AS time(7)) IS NOT NULL
                THEN DATEDIFF_BIG(millisecond, CAST('00:00:00' AS time), TRY_CAST(bp.BinActionTime AS time(7))) / 1000.0
                ELSE NULL
            END
            AS decimal(19, 3)
        ) AS HandleSeconds,
        CAST(
            CASE
                WHEN TRY_CAST(bp.BinActionTime AS time(7)) IS NOT NULL
                THEN DATEDIFF_BIG(millisecond, CAST('00:00:00' AS time), TRY_CAST(bp.BinActionTime AS time(7))) / 1000.0
                ELSE NULL
            END
            AS decimal(19, 3)
        ) AS MachineWaitSeconds,
        CAST(0 AS int) AS OrderCompletedCount,
        CAST(1 AS int) AS BinPresentationCount,
        CAST(0 AS int) AS LineCompletedCount,
        CAST(0 AS bigint) AS UnitCompletedCount,
        CAST('BinPresented' AS varchar(80)) AS SourceName,
        bp.PrimaryKey AS SourcePrimaryKey,
        CAST(NULL AS bigint) AS FulfillmentOrderPrimaryKey,
        CAST(NULL AS bigint) AS FulfillmentOrderLinePrimaryKey,
        CAST(bp.ContainerBarcode AS varchar(100)) AS ContainerBarcode,
        CAST(
            CASE
                WHEN session_match.[User] IS NOT NULL THEN 'Task session'
                WHEN pick_match.[User] IS NOT NULL THEN 'Nearest pick by container'
                ELSE 'Unattributed'
            END
            AS varchar(100)
        ) AS AttributionMethod
    FROM dbo.BinPresented bp
    OUTER APPLY (
        SELECT TOP (1)
            ws.[User]
        FROM dbo.v_ProductivityWorkSessions ws
        WHERE ws.LocationPrimaryKey = bp.LocationPrimaryKey
          AND (bp.LocationTaskType IS NULL OR ws.WorkType = bp.LocationTaskType)
          AND CAST(bp.[TimeStamp] AS datetime2(7)) >= ws.SignInTime
          AND CAST(bp.[TimeStamp] AS datetime2(7)) <= ws.SignOutTime
        ORDER BY ws.SignInTime DESC
    ) session_match
    OUTER APPLY (
        SELECT TOP (1)
            p.[User]
        FROM dbo.Pick p
        WHERE p.ContainerBarcode = bp.ContainerBarcode
          AND p.[User] IS NOT NULL
          AND p.[TimeStamp] >= bp.[TimeStamp]
        ORDER BY p.[TimeStamp], p.PrimaryKey
    ) pick_match
    OUTER APPLY (
        SELECT TOP (1)
            cb.[TimeStamp] AS CloseTime
        FROM dbo.CloseBin cb
        WHERE cb.ContainerBarcode = bp.ContainerBarcode
          AND (cb.LocationPrimaryKey = bp.LocationPrimaryKey OR cb.LocationPrimaryKey IS NULL OR bp.LocationPrimaryKey IS NULL)
          AND cb.[TimeStamp] >= bp.[TimeStamp]
        ORDER BY cb.[TimeStamp], cb.PrimaryKey
    ) close_match
),
PickLineEvents AS (
    SELECT
        CAST('Pick' AS varchar(50)) AS WorkType,
        CAST('LINE_COMPLETED' AS varchar(50)) AS EventType,
        CAST(p.PrimaryKey AS varchar(120)) AS EventKey,
        p.[User],
        p.LocationBarcode AS Port,
        CAST(COALESCE(p.PickCompleteDate, p.[TimeStamp]) AS date) AS EventDate,
        CAST(p.[TimeStamp] AS datetime2(7)) AS StartTime,
        CAST(COALESCE(p.PickCompleteDate, p.[TimeStamp]) AS datetime2(7)) AS EndTime,
        CAST(
            CASE
                WHEN p.PickCompleteDate IS NOT NULL
                    AND p.PickCompleteDate >= p.[TimeStamp]
                THEN DATEDIFF_BIG(millisecond, p.[TimeStamp], p.PickCompleteDate) / 1000.0
                ELSE NULL
            END
            AS decimal(19, 3)
        ) AS DurationSeconds,
        CAST(0 AS decimal(19, 3)) AS RateDenominatorSeconds,
        CAST(0 AS decimal(19, 3)) AS HandleSeconds,
        CAST(0 AS decimal(19, 3)) AS MachineWaitSeconds,
        CAST(0 AS int) AS OrderCompletedCount,
        CAST(0 AS int) AS BinPresentationCount,
        CAST(CASE WHEN COALESCE(p.ActualPickQuantity, 0) >= COALESCE(p.RequiredPickQuantity, 0) THEN 1 ELSE 0 END AS int) AS LineCompletedCount,
        CAST(CASE WHEN COALESCE(p.ActualPickQuantity, 0) >= COALESCE(p.RequiredPickQuantity, 0) THEN COALESCE(p.ActualPickQuantity, 0) ELSE 0 END AS bigint) AS UnitCompletedCount,
        CAST('Pick' AS varchar(80)) AS SourceName,
        p.PrimaryKey AS SourcePrimaryKey,
        CAST(p.TransportOrderPrimaryKey AS bigint) AS FulfillmentOrderPrimaryKey,
        CAST(p.PickPrimaryKey AS bigint) AS FulfillmentOrderLinePrimaryKey,
        CAST(p.ContainerBarcode AS varchar(100)) AS ContainerBarcode,
        CAST('Pick row' AS varchar(100)) AS AttributionMethod
    FROM dbo.Pick p
    WHERE p.[User] IS NOT NULL
),
OrderMetricEvents AS (
    SELECT
        CAST('Pick' AS varchar(50)) AS WorkType,
        CAST('ORDER_COMPLETED' AS varchar(50)) AS EventType,
        CAST(o.PrimaryKey AS varchar(120)) AS EventKey,
        o.[User],
        o.Port,
        CAST(o.CompletedDate AS date) AS EventDate,
        CAST(o.CompletedDate AS datetime2(7)) AS StartTime,
        CAST(o.CompletedDate AS datetime2(7)) AS EndTime,
        CAST(NULL AS decimal(19, 3)) AS DurationSeconds,
        CAST(0 AS decimal(19, 3)) AS RateDenominatorSeconds,
        CAST(0 AS decimal(19, 3)) AS HandleSeconds,
        CAST(0 AS decimal(19, 3)) AS MachineWaitSeconds,
        CAST(1 AS int) AS OrderCompletedCount,
        CAST(0 AS int) AS BinPresentationCount,
        CAST(
            CASE
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM dbo.Pick p
                    WHERE p.TransportOrderPrimaryKey = o.OrderPrimaryKey
                       OR (p.OrderNumber IS NOT NULL AND p.OrderNumber = o.OrderNumber)
                )
                THEN COALESCE(o.OrderLineCount, 0)
                ELSE 0
            END
            AS int
        ) AS LineCompletedCount,
        CAST(
            CASE
                WHEN NOT EXISTS (
                    SELECT 1
                    FROM dbo.Pick p
                    WHERE p.TransportOrderPrimaryKey = o.OrderPrimaryKey
                       OR (p.OrderNumber IS NOT NULL AND p.OrderNumber = o.OrderNumber)
                )
                THEN COALESCE(o.EachUnitCount, 0)
                ELSE 0
            END
            AS bigint
        ) AS UnitCompletedCount,
        CAST('Order' AS varchar(80)) AS SourceName,
        o.PrimaryKey AS SourcePrimaryKey,
        CAST(o.OrderPrimaryKey AS bigint) AS FulfillmentOrderPrimaryKey,
        CAST(NULL AS bigint) AS FulfillmentOrderLinePrimaryKey,
        CAST(NULL AS varchar(100)) AS ContainerBarcode,
        CAST('Reported order row' AS varchar(100)) AS AttributionMethod
    FROM dbo.[Order] o
    WHERE o.CompletedDate IS NOT NULL
)
SELECT * FROM SessionEvents
UNION ALL
SELECT * FROM BinEvents
UNION ALL
SELECT * FROM PickLineEvents
UNION ALL
SELECT * FROM OrderMetricEvents;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityByUserWorkType_v2]
AS
WITH Aggregated AS (
    SELECT
        WorkType,
        [User] AS Users,
        SUM(OrderCompletedCount) AS OrdersCompleted,
        SUM(BinPresentationCount) AS BinPresentationsCompleted,
        SUM(LineCompletedCount) AS LinesCompleted,
        SUM(UnitCompletedCount) AS UnitsCompleted,
        SUM(COALESCE(RateDenominatorSeconds, 0)) AS SessionSeconds,
        SUM(COALESCE(HandleSeconds, 0)) AS HandleSeconds,
        SUM(COALESCE(MachineWaitSeconds, 0)) AS MachineWaitSeconds,
        COUNT_BIG(*) AS EventRows,
        SUM(CASE WHEN EventType = 'SESSION' THEN 1 ELSE 0 END) AS SessionEventRows,
        SUM(CASE WHEN EventType = 'BIN_PRESENTATION' THEN 1 ELSE 0 END) AS BinPresentationEventRows,
        SUM(CASE WHEN SourceName = 'Pick' THEN 1 ELSE 0 END) AS PickEventRows,
        SUM(CASE WHEN EventType = 'ORDER_COMPLETED' THEN 1 ELSE 0 END) AS OrderEventRows,
        SUM(CASE WHEN AttributionMethod = 'Unattributed' THEN 1 ELSE 0 END) AS UnattributedEventRows
    FROM dbo.v_ProductivityWorkEvents_v2
    WHERE [User] IS NOT NULL
    GROUP BY WorkType, [User]
),
WithDenominator AS (
    SELECT
        *,
        CASE WHEN SessionSeconds > 0 THEN SessionSeconds ELSE HandleSeconds END AS RateDenominatorSeconds,
        CASE
            WHEN SessionSeconds > 0 THEN 'SESSION'
            WHEN HandleSeconds > 0 THEN 'HANDLE_FALLBACK'
            ELSE 'NONE'
        END AS RateDenominatorSource
    FROM Aggregated
)
SELECT
    WorkType,
    Users,
    OrdersCompleted,
    BinPresentationsCompleted,
    LinesCompleted,
    UnitsCompleted,
    CAST(SessionSeconds / 3600.0 AS decimal(19, 4)) AS TotalLoggedHours,
    CAST(SessionSeconds / 60.0 AS decimal(19, 4)) AS TotalLoggedMinutes,
    CAST(HandleSeconds / 60.0 AS decimal(19, 4)) AS ActiveHandleMinutes,
    CAST(MachineWaitSeconds / 60.0 AS decimal(19, 4)) AS MachineWaitMinutes,
    CAST(RateDenominatorSeconds / 3600.0 AS decimal(19, 4)) AS RateDenominatorHours,
    RateDenominatorSource,
    CASE WHEN RateDenominatorSeconds > 0 THEN OrdersCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS OrdersPerHour,
    CASE WHEN RateDenominatorSeconds > 0 THEN BinPresentationsCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS BinsPerHour,
    CASE WHEN RateDenominatorSeconds > 0 THEN UnitsCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS UnitsPerHour,
    CASE WHEN RateDenominatorSeconds > 0 THEN LinesCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS LinesPerHour,
    CASE WHEN BinPresentationsCompleted > 0 THEN (HandleSeconds / 60.0) / BinPresentationsCompleted ELSE NULL END AS AverageHandleTimePerPresentationMinutes,
    EventRows,
    SessionEventRows,
    BinPresentationEventRows,
    PickEventRows,
    OrderEventRows,
    UnattributedEventRows
FROM WithDenominator;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityByPortWorkType_v2]
AS
WITH Aggregated AS (
    SELECT
        WorkType,
        COALESCE(Port, 'Unattributed') AS Ports,
        SUM(OrderCompletedCount) AS OrdersCompleted,
        SUM(BinPresentationCount) AS BinPresentationsCompleted,
        SUM(LineCompletedCount) AS LinesCompleted,
        SUM(UnitCompletedCount) AS UnitsCompleted,
        SUM(COALESCE(RateDenominatorSeconds, 0)) AS SessionSeconds,
        SUM(COALESCE(HandleSeconds, 0)) AS HandleSeconds,
        SUM(COALESCE(MachineWaitSeconds, 0)) AS MachineWaitSeconds,
        COUNT_BIG(*) AS EventRows,
        SUM(CASE WHEN EventType = 'SESSION' THEN 1 ELSE 0 END) AS SessionEventRows,
        SUM(CASE WHEN EventType = 'BIN_PRESENTATION' THEN 1 ELSE 0 END) AS BinPresentationEventRows,
        SUM(CASE WHEN SourceName = 'Pick' THEN 1 ELSE 0 END) AS PickEventRows,
        SUM(CASE WHEN EventType = 'ORDER_COMPLETED' THEN 1 ELSE 0 END) AS OrderEventRows,
        SUM(CASE WHEN AttributionMethod = 'Unattributed' THEN 1 ELSE 0 END) AS UnattributedEventRows
    FROM dbo.v_ProductivityWorkEvents_v2
    GROUP BY WorkType, COALESCE(Port, 'Unattributed')
),
WithDenominator AS (
    SELECT
        *,
        CASE WHEN SessionSeconds > 0 THEN SessionSeconds ELSE HandleSeconds END AS RateDenominatorSeconds,
        CASE
            WHEN SessionSeconds > 0 THEN 'SESSION'
            WHEN HandleSeconds > 0 THEN 'HANDLE_FALLBACK'
            ELSE 'NONE'
        END AS RateDenominatorSource
    FROM Aggregated
)
SELECT
    WorkType,
    Ports,
    OrdersCompleted,
    BinPresentationsCompleted,
    LinesCompleted,
    UnitsCompleted,
    CAST(SessionSeconds / 3600.0 AS decimal(19, 4)) AS TotalLoggedHours,
    CAST(SessionSeconds / 60.0 AS decimal(19, 4)) AS TotalLoggedMinutes,
    CAST(HandleSeconds / 60.0 AS decimal(19, 4)) AS ActiveHandleMinutes,
    CAST(MachineWaitSeconds / 60.0 AS decimal(19, 4)) AS MachineWaitMinutes,
    CAST(RateDenominatorSeconds / 3600.0 AS decimal(19, 4)) AS RateDenominatorHours,
    RateDenominatorSource,
    CASE WHEN RateDenominatorSeconds > 0 THEN OrdersCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS OrdersPerHour,
    CASE WHEN RateDenominatorSeconds > 0 THEN BinPresentationsCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS BinsPerHour,
    CASE WHEN RateDenominatorSeconds > 0 THEN UnitsCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS UnitsPerHour,
    CASE WHEN RateDenominatorSeconds > 0 THEN LinesCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS LinesPerHour,
    CASE WHEN BinPresentationsCompleted > 0 THEN (HandleSeconds / 60.0) / BinPresentationsCompleted ELSE NULL END AS AverageHandleTimePerPresentationMinutes,
    EventRows,
    SessionEventRows,
    BinPresentationEventRows,
    PickEventRows,
    OrderEventRows,
    UnattributedEventRows
FROM WithDenominator;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityByUser_v2]
AS
WITH Aggregated AS (
    SELECT
        Users,
        SUM(OrdersCompleted) AS OrdersCompleted,
        SUM(BinPresentationsCompleted) AS BinPresentationsCompleted,
        SUM(LinesCompleted) AS LinesCompleted,
        SUM(UnitsCompleted) AS UnitsCompleted,
        SUM(TotalLoggedHours) AS TotalLoggedHours,
        SUM(TotalLoggedMinutes) AS TotalLoggedMinutes,
        SUM(ActiveHandleMinutes) AS ActiveHandleMinutes,
        SUM(MachineWaitMinutes) AS MachineWaitMinutes,
        SUM(RateDenominatorHours) AS RateDenominatorHours,
        SUM(EventRows) AS EventRows,
        SUM(SessionEventRows) AS SessionEventRows,
        SUM(BinPresentationEventRows) AS BinPresentationEventRows,
        SUM(PickEventRows) AS PickEventRows,
        SUM(OrderEventRows) AS OrderEventRows,
        SUM(UnattributedEventRows) AS UnattributedEventRows
    FROM dbo.v_ProductivityByUserWorkType_v2
    GROUP BY Users
)
SELECT
    Users,
    OrdersCompleted,
    BinPresentationsCompleted,
    LinesCompleted,
    UnitsCompleted,
    TotalLoggedHours,
    TotalLoggedMinutes,
    ActiveHandleMinutes,
    MachineWaitMinutes,
    RateDenominatorHours,
    CASE WHEN RateDenominatorHours > 0 THEN OrdersCompleted / RateDenominatorHours ELSE NULL END AS OrdersPerHour,
    CASE WHEN RateDenominatorHours > 0 THEN BinPresentationsCompleted / RateDenominatorHours ELSE NULL END AS BinsPerHour,
    CASE WHEN RateDenominatorHours > 0 THEN UnitsCompleted / RateDenominatorHours ELSE NULL END AS UnitsPerHour,
    CASE WHEN RateDenominatorHours > 0 THEN LinesCompleted / RateDenominatorHours ELSE NULL END AS LinesPerHour,
    CASE WHEN BinPresentationsCompleted > 0 THEN ActiveHandleMinutes / BinPresentationsCompleted ELSE NULL END AS AverageHandleTimePerPresentationMinutes,
    EventRows,
    SessionEventRows,
    BinPresentationEventRows,
    PickEventRows,
    OrderEventRows,
    UnattributedEventRows
FROM Aggregated;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityByPort_v2]
AS
WITH Aggregated AS (
    SELECT
        Ports,
        SUM(OrdersCompleted) AS OrdersCompleted,
        SUM(BinPresentationsCompleted) AS BinPresentationsCompleted,
        SUM(LinesCompleted) AS LinesCompleted,
        SUM(UnitsCompleted) AS UnitsCompleted,
        SUM(TotalLoggedHours) AS TotalLoggedHours,
        SUM(TotalLoggedMinutes) AS TotalLoggedMinutes,
        SUM(ActiveHandleMinutes) AS ActiveHandleMinutes,
        SUM(MachineWaitMinutes) AS MachineWaitMinutes,
        SUM(RateDenominatorHours) AS RateDenominatorHours,
        SUM(EventRows) AS EventRows,
        SUM(SessionEventRows) AS SessionEventRows,
        SUM(BinPresentationEventRows) AS BinPresentationEventRows,
        SUM(PickEventRows) AS PickEventRows,
        SUM(OrderEventRows) AS OrderEventRows,
        SUM(UnattributedEventRows) AS UnattributedEventRows
    FROM dbo.v_ProductivityByPortWorkType_v2
    GROUP BY Ports
)
SELECT
    Ports,
    OrdersCompleted,
    BinPresentationsCompleted,
    LinesCompleted,
    UnitsCompleted,
    TotalLoggedHours,
    TotalLoggedMinutes,
    ActiveHandleMinutes,
    MachineWaitMinutes,
    RateDenominatorHours,
    CASE WHEN RateDenominatorHours > 0 THEN OrdersCompleted / RateDenominatorHours ELSE NULL END AS OrdersPerHour,
    CASE WHEN RateDenominatorHours > 0 THEN BinPresentationsCompleted / RateDenominatorHours ELSE NULL END AS BinsPerHour,
    CASE WHEN RateDenominatorHours > 0 THEN UnitsCompleted / RateDenominatorHours ELSE NULL END AS UnitsPerHour,
    CASE WHEN RateDenominatorHours > 0 THEN LinesCompleted / RateDenominatorHours ELSE NULL END AS LinesPerHour,
    CASE WHEN BinPresentationsCompleted > 0 THEN ActiveHandleMinutes / BinPresentationsCompleted ELSE NULL END AS AverageHandleTimePerPresentationMinutes,
    EventRows,
    SessionEventRows,
    BinPresentationEventRows,
    PickEventRows,
    OrderEventRows,
    UnattributedEventRows
FROM Aggregated;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityDailyUserPortWorkType_v2]
AS
WITH Aggregated AS (
    SELECT
        EventDate,
        WorkType,
        COALESCE([User], 'Unattributed') AS Users,
        COALESCE(Port, 'Unattributed') AS Ports,
        SUM(OrderCompletedCount) AS OrdersCompleted,
        SUM(BinPresentationCount) AS BinPresentationsCompleted,
        SUM(LineCompletedCount) AS LinesCompleted,
        SUM(UnitCompletedCount) AS UnitsCompleted,
        SUM(COALESCE(RateDenominatorSeconds, 0)) AS SessionSeconds,
        SUM(COALESCE(HandleSeconds, 0)) AS HandleSeconds,
        SUM(COALESCE(MachineWaitSeconds, 0)) AS MachineWaitSeconds,
        COUNT_BIG(*) AS EventRows,
        SUM(CASE WHEN EventType = 'SESSION' THEN 1 ELSE 0 END) AS SessionEventRows,
        SUM(CASE WHEN EventType = 'BIN_PRESENTATION' THEN 1 ELSE 0 END) AS BinPresentationEventRows,
        SUM(CASE WHEN SourceName = 'Pick' THEN 1 ELSE 0 END) AS PickEventRows,
        SUM(CASE WHEN EventType = 'ORDER_COMPLETED' THEN 1 ELSE 0 END) AS OrderEventRows,
        SUM(CASE WHEN AttributionMethod = 'Unattributed' THEN 1 ELSE 0 END) AS UnattributedEventRows,
        MIN(StartTime) AS MinStartTime,
        MAX(StartTime) AS MaxStartTime
    FROM dbo.v_ProductivityWorkEvents_v2
    GROUP BY
        EventDate,
        WorkType,
        COALESCE([User], 'Unattributed'),
        COALESCE(Port, 'Unattributed')
),
WithDenominator AS (
    SELECT
        *,
        CASE WHEN SessionSeconds > 0 THEN SessionSeconds ELSE HandleSeconds END AS RateDenominatorSeconds,
        CASE
            WHEN SessionSeconds > 0 THEN 'SESSION'
            WHEN HandleSeconds > 0 THEN 'HANDLE_FALLBACK'
            ELSE 'NONE'
        END AS RateDenominatorSource
    FROM Aggregated
)
SELECT
    EventDate,
    WorkType,
    Users,
    Ports,
    OrdersCompleted,
    BinPresentationsCompleted,
    LinesCompleted,
    UnitsCompleted,
    CAST(SessionSeconds / 3600.0 AS decimal(19, 4)) AS TotalLoggedHours,
    CAST(SessionSeconds / 60.0 AS decimal(19, 4)) AS TotalLoggedMinutes,
    CAST(HandleSeconds / 60.0 AS decimal(19, 4)) AS ActiveHandleMinutes,
    CAST(MachineWaitSeconds / 60.0 AS decimal(19, 4)) AS MachineWaitMinutes,
    CAST(RateDenominatorSeconds / 3600.0 AS decimal(19, 4)) AS RateDenominatorHours,
    RateDenominatorSource,
    CASE WHEN RateDenominatorSeconds > 0 THEN OrdersCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS OrdersPerHour,
    CASE WHEN RateDenominatorSeconds > 0 THEN BinPresentationsCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS BinsPerHour,
    CASE WHEN RateDenominatorSeconds > 0 THEN UnitsCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS UnitsPerHour,
    CASE WHEN RateDenominatorSeconds > 0 THEN LinesCompleted / (RateDenominatorSeconds / 3600.0) ELSE NULL END AS LinesPerHour,
    CASE WHEN BinPresentationsCompleted > 0 THEN (HandleSeconds / 60.0) / BinPresentationsCompleted ELSE NULL END AS AverageHandleTimePerPresentationMinutes,
    EventRows,
    SessionEventRows,
    BinPresentationEventRows,
    PickEventRows,
    OrderEventRows,
    UnattributedEventRows,
    MinStartTime,
    MaxStartTime
FROM WithDenominator;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityCurrentFeedReadiness_v2]
AS
SELECT
    (SELECT COUNT_BIG(*) FROM dbo.Report_Data) AS ReportDataRows,
    (SELECT MIN(PrimaryKey) FROM dbo.Report_Data) AS ReportDataMinPrimaryKey,
    (SELECT MAX(PrimaryKey) FROM dbo.Report_Data) AS ReportDataMaxPrimaryKey,
    (SELECT MIN([TimeStamp]) FROM dbo.Report_Data) AS ReportDataMinTimestamp,
    (SELECT MAX([TimeStamp]) FROM dbo.Report_Data) AS ReportDataMaxTimestamp,
    (SELECT COUNT_BIG(*) FROM dbo.Pick) AS PickRows,
    (SELECT COUNT_BIG(*) FROM dbo.[Order]) AS OrderRows,
    (SELECT COUNT_BIG(*) FROM dbo.[Order] WHERE CompletedDate IS NOT NULL) AS CompletedOrderRows,
    (SELECT COUNT_BIG(*) FROM dbo.BinPresented) AS BinPresentedRows,
    (SELECT COUNT_BIG(*) FROM dbo.CloseBin) AS CloseBinRows,
    (SELECT COUNT_BIG(*) FROM dbo.[Pick-SignIn]) AS PickSignInRows,
    (SELECT COUNT_BIG(*) FROM dbo.[Pick-SignOut]) AS PickSignOutRows,
    (SELECT COUNT_BIG(*) FROM dbo.[PutAway-SignIn]) AS PutAwaySignInRows,
    (SELECT COUNT_BIG(*) FROM dbo.[PutAway-SignOut]) AS PutAwaySignOutRows,
    (SELECT COUNT_BIG(*) FROM dbo.[CycleCount-SignIn]) AS CycleCountSignInRows,
    (SELECT COUNT_BIG(*) FROM dbo.[CycleCount-SignOut]) AS CycleCountSignOutRows,
    CASE WHEN EXISTS (SELECT 1 FROM dbo.Pick) THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS HasPickRows,
    CASE WHEN EXISTS (SELECT 1 FROM dbo.[Order]) THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS HasOrderRows,
    CASE WHEN EXISTS (SELECT 1 FROM dbo.BinPresented) THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS HasBinPresentedRows,
    CASE WHEN EXISTS (SELECT 1 FROM dbo.v_ProductivityWorkSessions) THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS HasPairedWorkSessions;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityValidation_v2]
AS
SELECT
    CAST('Bin presentations' AS varchar(80)) AS CheckName,
    CAST((SELECT COUNT_BIG(*) FROM dbo.BinPresented) AS decimal(19, 3)) AS RawValue,
    CAST((SELECT COALESCE(SUM(BinPresentationCount), 0) FROM dbo.v_ProductivityWorkEvents_v2 WHERE EventType = 'BIN_PRESENTATION') AS decimal(19, 3)) AS EventValue
UNION ALL
SELECT
    'Completed pick lines',
    CAST((SELECT COUNT_BIG(*) FROM dbo.Pick WHERE COALESCE(ActualPickQuantity, 0) >= COALESCE(RequiredPickQuantity, 0)) AS decimal(19, 3)),
    CAST((SELECT COALESCE(SUM(LineCompletedCount), 0) FROM dbo.v_ProductivityWorkEvents_v2 WHERE SourceName = 'Pick') AS decimal(19, 3))
UNION ALL
SELECT
    'Completed pick units',
    CAST((SELECT COALESCE(SUM(CASE WHEN COALESCE(ActualPickQuantity, 0) >= COALESCE(RequiredPickQuantity, 0) THEN ActualPickQuantity ELSE 0 END), 0) FROM dbo.Pick) AS decimal(19, 3)),
    CAST((SELECT COALESCE(SUM(UnitCompletedCount), 0) FROM dbo.v_ProductivityWorkEvents_v2 WHERE SourceName = 'Pick') AS decimal(19, 3))
UNION ALL
SELECT
    'Reported order rows',
    CAST((SELECT COUNT_BIG(*) FROM dbo.[Order] WHERE CompletedDate IS NOT NULL) AS decimal(19, 3)),
    CAST((SELECT COALESCE(SUM(OrderCompletedCount), 0) FROM dbo.v_ProductivityWorkEvents_v2 WHERE SourceName = 'Order') AS decimal(19, 3))
UNION ALL
SELECT
    'Paired session seconds',
    CAST((SELECT COALESCE(SUM(SessionSeconds), 0) FROM dbo.v_ProductivityWorkSessions) AS decimal(19, 3)),
    CAST((SELECT COALESCE(SUM(RateDenominatorSeconds), 0) FROM dbo.v_ProductivityWorkEvents_v2 WHERE EventType = 'SESSION') AS decimal(19, 3));
GO
