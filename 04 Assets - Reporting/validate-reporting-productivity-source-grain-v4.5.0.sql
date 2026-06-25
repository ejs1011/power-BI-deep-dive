USE [KFX_REPORTING]
GO

/*
    Validation bundle for create-reporting-productivity-source-grain-v4.5.0.sql.

    This is read-only. It validates the source-aware reported metric layer used
    to reason about historical/live/archive coverage.
*/

SELECT
    SourceDatabase,
    SourceTable,
    SUM(SourceRows) AS SourceRows,
    MIN(MinEventTimestamp) AS MinEventTimestamp,
    MAX(MaxEventTimestamp) AS MaxEventTimestamp
FROM dbo.v_ProductivityReportedMetricSourceDiagnostics_v2
GROUP BY SourceDatabase, SourceTable
ORDER BY MaxEventTimestamp DESC, SourceDatabase, SourceTable;

SELECT
    DataDescription,
    DedupedRows,
    RemovedDuplicateRows,
    MinEventTimestamp,
    MaxEventTimestamp
FROM dbo.v_ProductivityReportedMetricDedupDiagnostics_v2
WHERE DataDescription IN (
    N'Order',
    N'Pick',
    N'Pick-SignIn',
    N'Pick-SignOut',
    N'BinPresented',
    N'CloseBin',
    N'OpenBin',
    N'PutAway',
    N'PutAway-SignIn',
    N'PutAway-SignOut',
    N'CycleCountService',
    N'CycleCount-SignIn',
    N'CycleCount-SignOut',
    N'OnDemand-SignIn',
    N'OnDemand-SignOut'
)
ORDER BY MaxEventTimestamp DESC, DataDescription;

SELECT
    DataDescription,
    EventRows,
    RowsWithUser,
    RowsWithPort,
    MinEventTimestamp,
    MaxEventTimestamp
FROM dbo.v_ProductivityRawEventSummary_v2
WHERE DataDescription IN (
    N'Order',
    N'Pick',
    N'Pick-SignIn',
    N'Pick-SignOut',
    N'BinPresented',
    N'CloseBin',
    N'OpenBin',
    N'PutAway',
    N'PutAway-SignIn',
    N'PutAway-SignOut',
    N'CycleCountService',
    N'CycleCount-SignIn',
    N'CycleCount-SignOut',
    N'OnDemand-SignIn',
    N'OnDemand-SignOut'
)
ORDER BY MaxEventTimestamp DESC, DataDescription;

SELECT
    WorkType,
    [User],
    LocationPrimaryKey,
    COUNT_BIG(*) AS SessionRows,
    SUM(SessionSeconds) AS SessionSeconds,
    MIN(SignInTime) AS MinSignInTime,
    MAX(SignOutTime) AS MaxSignOutTime
FROM dbo.v_ProductivityRawWorkSessions_v2
GROUP BY WorkType, [User], LocationPrimaryKey
ORDER BY WorkType, [User], LocationPrimaryKey;
GO
