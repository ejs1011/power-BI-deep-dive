USE [KFX_REPORTING]
GO

/*
    Read-only drill-through for Productivity by User / Port.

    Change the filter values below, then run the script. Use NULL for any
    filter you do not want to apply.

    Example:
      @WorkType = 'Pick'
      @Users = 'admin'
      @Ports = 'P4'
      @EventDate = '2026-06-24'
*/

DECLARE @WorkType varchar(50) = 'Pick';
DECLARE @Users varchar(100) = NULL;
DECLARE @Ports varchar(100) = NULL;
DECLARE @EventDate date = NULL;

SELECT
    EventDate,
    WorkType,
    Users,
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
    RateDenominatorSource,
    OrdersPerHour,
    BinsPerHour,
    UnitsPerHour,
    LinesPerHour,
    AverageHandleTimePerPresentationMinutes,
    EventRows,
    SessionEventRows,
    BinPresentationEventRows,
    PickEventRows,
    OrderEventRows,
    UnattributedEventRows,
    MinStartTime,
    MaxStartTime
FROM dbo.v_ProductivityDailyUserPortWorkType_v2
WHERE (@WorkType IS NULL OR WorkType = @WorkType)
  AND (@Users IS NULL OR Users = @Users)
  AND (@Ports IS NULL OR Ports = @Ports)
  AND (@EventDate IS NULL OR EventDate = @EventDate)
ORDER BY EventDate, WorkType, Users, Ports;

;WITH FilteredEvents AS (
    SELECT
        EventDate,
        WorkType,
        EventType,
        SourceName,
        SourcePrimaryKey,
        AttributionMethod,
        COALESCE([User], 'Unattributed') AS Users,
        COALESCE(Port, 'Unattributed') AS Ports,
        StartTime,
        EndTime,
        DurationSeconds,
        RateDenominatorSeconds,
        HandleSeconds,
        MachineWaitSeconds,
        OrderCompletedCount,
        BinPresentationCount,
        LineCompletedCount,
        UnitCompletedCount,
        FulfillmentOrderPrimaryKey,
        FulfillmentOrderLinePrimaryKey,
        ContainerBarcode
    FROM dbo.v_ProductivityWorkEvents_v2
    WHERE (@WorkType IS NULL OR WorkType = @WorkType)
      AND (@Users IS NULL OR COALESCE([User], 'Unattributed') = @Users)
      AND (@Ports IS NULL OR COALESCE(Port, 'Unattributed') = @Ports)
      AND (@EventDate IS NULL OR EventDate = @EventDate)
)
SELECT
    WorkType,
    EventType,
    SourceName,
    AttributionMethod,
    COUNT_BIG(*) AS EventRows,
    SUM(OrderCompletedCount) AS OrdersCompleted,
    SUM(BinPresentationCount) AS BinPresentationsCompleted,
    SUM(LineCompletedCount) AS LinesCompleted,
    SUM(UnitCompletedCount) AS UnitsCompleted,
    CAST(SUM(COALESCE(RateDenominatorSeconds, 0)) / 60.0 AS decimal(19, 4)) AS RateDenominatorMinutes,
    CAST(SUM(COALESCE(HandleSeconds, 0)) / 60.0 AS decimal(19, 4)) AS HandleMinutes,
    CAST(SUM(COALESCE(MachineWaitSeconds, 0)) / 60.0 AS decimal(19, 4)) AS MachineWaitMinutes,
    MIN(StartTime) AS MinStartTime,
    MAX(StartTime) AS MaxStartTime
FROM FilteredEvents
GROUP BY WorkType, EventType, SourceName, AttributionMethod
ORDER BY WorkType, EventType, SourceName, AttributionMethod;

;WITH FilteredEvents AS (
    SELECT
        EventDate,
        WorkType,
        EventType,
        SourceName,
        SourcePrimaryKey,
        AttributionMethod,
        COALESCE([User], 'Unattributed') AS Users,
        COALESCE(Port, 'Unattributed') AS Ports,
        StartTime,
        EndTime,
        DurationSeconds,
        RateDenominatorSeconds,
        HandleSeconds,
        MachineWaitSeconds,
        OrderCompletedCount,
        BinPresentationCount,
        LineCompletedCount,
        UnitCompletedCount,
        FulfillmentOrderPrimaryKey,
        FulfillmentOrderLinePrimaryKey,
        ContainerBarcode
    FROM dbo.v_ProductivityWorkEvents_v2
    WHERE (@WorkType IS NULL OR WorkType = @WorkType)
      AND (@Users IS NULL OR COALESCE([User], 'Unattributed') = @Users)
      AND (@Ports IS NULL OR COALESCE(Port, 'Unattributed') = @Ports)
      AND (@EventDate IS NULL OR EventDate = @EventDate)
)
SELECT TOP (500)
    EventDate,
    WorkType,
    EventType,
    SourceName,
    SourcePrimaryKey,
    AttributionMethod,
    Users,
    Ports,
    StartTime,
    EndTime,
    DurationSeconds,
    RateDenominatorSeconds,
    HandleSeconds,
    MachineWaitSeconds,
    OrderCompletedCount,
    BinPresentationCount,
    LineCompletedCount,
    UnitCompletedCount,
    FulfillmentOrderPrimaryKey,
    FulfillmentOrderLinePrimaryKey,
    ContainerBarcode
FROM FilteredEvents
ORDER BY StartTime, EventType, SourceName, SourcePrimaryKey;
GO
