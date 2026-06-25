USE [KFX_REPORTING]
GO

/*
    Validation bundle for the v2 Productivity by User / Port rework.

    Run order:
      1. create-reporting-productivity-work-events-v4.5.0.sql
      2. validate-reporting-productivity-v4.5.0.sql
      3. patch-reporting-productivity-views-v4.5.0.sql only after validation passes

    Paste these result sets back into the investigation notes before promoting
    the compatibility patch or changing PBIX fields.
*/

SELECT *
FROM dbo.v_ProductivityCurrentFeedReadiness_v2;

SELECT
    CheckName,
    RawValue,
    EventValue,
    RawValue - EventValue AS Difference
FROM dbo.v_ProductivityValidation_v2
ORDER BY CheckName;

;WITH ValidationFailures AS (
    SELECT
        COUNT(*) AS FailedValidationChecks
    FROM dbo.v_ProductivityValidation_v2
    WHERE ABS(RawValue - EventValue) > 0.001
),
Readiness AS (
    SELECT *
    FROM dbo.v_ProductivityCurrentFeedReadiness_v2
),
PickDenominator AS (
    SELECT
        COUNT(*) AS PickAggregateRows,
        COALESCE(SUM(CASE WHEN RateDenominatorSource = 'SESSION' THEN 1 ELSE 0 END), 0) AS PickRowsWithSessionDenominator,
        COALESCE(SUM(CASE WHEN RateDenominatorSource <> 'SESSION' THEN 1 ELSE 0 END), 0) AS PickRowsWithoutSessionDenominator
    FROM dbo.v_ProductivityByUserWorkType_v2
    WHERE WorkType = 'Pick'
)
SELECT
    CASE
        WHEN vf.FailedValidationChecks = 0
         AND r.HasPickRows = 1
         AND pd.PickAggregateRows > 0
         AND pd.PickRowsWithoutSessionDenominator = 0
        THEN 'PASS'
        ELSE 'REVIEW'
    END AS DropInPatchPromotionGate,
    vf.FailedValidationChecks,
    r.HasPickRows,
    r.HasOrderRows,
    r.HasBinPresentedRows,
    r.HasPairedWorkSessions,
    pd.PickAggregateRows,
    pd.PickRowsWithSessionDenominator,
    pd.PickRowsWithoutSessionDenominator,
    r.ReportDataRows,
    r.ReportDataMinPrimaryKey,
    r.ReportDataMaxPrimaryKey,
    r.ReportDataMinTimestamp,
    r.ReportDataMaxTimestamp
FROM ValidationFailures vf
CROSS JOIN Readiness r
CROSS JOIN PickDenominator pd;

SELECT
    WorkType,
    EventType,
    SourceName,
    AttributionMethod,
    COUNT(*) AS EventRows,
    SUM(OrderCompletedCount) AS OrdersCompleted,
    SUM(BinPresentationCount) AS BinPresentationsCompleted,
    SUM(LineCompletedCount) AS LinesCompleted,
    SUM(UnitCompletedCount) AS UnitsCompleted,
    SUM(RateDenominatorSeconds) AS RateDenominatorSeconds,
    SUM(HandleSeconds) AS HandleSeconds,
    SUM(MachineWaitSeconds) AS MachineWaitSeconds,
    MIN(StartTime) AS MinStartTime,
    MAX(StartTime) AS MaxStartTime
FROM dbo.v_ProductivityWorkEvents_v2
GROUP BY WorkType, EventType, SourceName, AttributionMethod
ORDER BY WorkType, EventType, SourceName, AttributionMethod;

SELECT
    WorkType,
    Users,
    OrdersCompleted,
    BinPresentationsCompleted,
    LinesCompleted,
    UnitsCompleted,
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
    UnattributedEventRows
FROM dbo.v_ProductivityByUserWorkType_v2
ORDER BY Users, WorkType;

SELECT
    WorkType,
    Ports,
    OrdersCompleted,
    BinPresentationsCompleted,
    LinesCompleted,
    UnitsCompleted,
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
    UnattributedEventRows
FROM dbo.v_ProductivityByPortWorkType_v2
ORDER BY Ports, WorkType;

IF OBJECT_ID(N'[dbo].[v_ProductivityDailyUserPortWorkType_v2]', N'V') IS NOT NULL
BEGIN
    EXEC(N'
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
        ORDER BY EventDate, WorkType, Users, Ports;
    ');
END
ELSE
BEGIN
    SELECT
        CAST('SKIPPED' AS varchar(20)) AS DailyUserPortWorkTypeValidation,
        CAST('dbo.v_ProductivityDailyUserPortWorkType_v2 was not found. Re-run create-reporting-productivity-work-events-v4.5.0.sql from the latest repo copy to create the report-friendly daily aggregate.' AS varchar(300)) AS Message;
END;

SELECT TOP (50)
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
    TotalRecordSynced
FROM dbo.DataSyncDetail
WHERE TableName = 'ReportedMetrics'
   OR JobName = 'TableSync'
ORDER BY Id DESC;
GO
