USE [KFX_REPORTING]
GO

/*
    Post-patch validation for the existing Power BI Productivity by User / Port page.

    Run after:
      1. create-reporting-productivity-work-events-v4.5.0.sql
      2. validate-reporting-productivity-v4.5.0.sql returns DropInPatchPromotionGate = PASS
      3. patch-reporting-productivity-views-v4.5.0.sql

    This proves the PBIX-imported helper views now reconcile back to the
    corrected v2 Pick aggregate. Differences should be 0, allowing for small
    floating-point variance on rate fields.
*/

IF OBJECT_ID('tempdb..#PowerBIPatchChecks') IS NOT NULL
    DROP TABLE #PowerBIPatchChecks;

IF OBJECT_ID('tempdb..#PowerBIImportViewCheck') IS NOT NULL
    DROP TABLE #PowerBIImportViewCheck;

IF OBJECT_ID('tempdb..#PowerBIRowChecks') IS NOT NULL
    DROP TABLE #PowerBIRowChecks;

;WITH UserPick AS (
    SELECT *
    FROM dbo.v_ProductivityByUserWorkType_v2
    WHERE WorkType = 'Pick'
),
PortPick AS (
    SELECT *
    FROM dbo.v_ProductivityByPortWorkType_v2
    WHERE WorkType = 'Pick'
),
Checks AS (
    SELECT
        CAST('User' AS varchar(10)) AS Grain,
        CAST('OrdersCompletedPerUser' AS varchar(80)) AS HelperView,
        CAST(COUNT(*) AS decimal(19, 4)) AS ExpectedRows,
        CAST((SELECT COUNT(*) FROM dbo.OrdersCompletedPerUser) AS decimal(19, 4)) AS ActualRows,
        CAST(COALESCE(SUM(OrdersCompleted), 0) AS decimal(19, 4)) AS ExpectedValue,
        CAST((SELECT COALESCE(SUM(OrdersCompleted), 0) FROM dbo.OrdersCompletedPerUser) AS decimal(19, 4)) AS ActualValue
    FROM UserPick
    UNION ALL
    SELECT 'User', 'BinPresentationsCompletedPerUser', COUNT(*), (SELECT COUNT(*) FROM dbo.BinPresentationsCompletedPerUser), COALESCE(SUM(BinPresentationsCompleted), 0), (SELECT COALESCE(SUM(BinPresentationsCompleted), 0) FROM dbo.BinPresentationsCompletedPerUser)
    FROM UserPick
    UNION ALL
    SELECT 'User', 'LinesCompletedPerUser', COUNT(*), (SELECT COUNT(*) FROM dbo.LinesCompletedPerUser), COALESCE(SUM(LinesCompleted), 0), (SELECT COALESCE(SUM(LinesCompleted), 0) FROM dbo.LinesCompletedPerUser)
    FROM UserPick
    UNION ALL
    SELECT 'User', 'UnitsCompletedPerUser', COUNT(*), (SELECT COUNT(*) FROM dbo.UnitsCompletedPerUser), COALESCE(SUM(UnitsCompleted), 0), (SELECT COALESCE(SUM(UnitsCompleted), 0) FROM dbo.UnitsCompletedPerUser)
    FROM UserPick
    UNION ALL
    SELECT 'User', 'OrdersPerHourPerUser', COUNT(*), (SELECT COUNT(*) FROM dbo.OrdersPerHourPerUser), COALESCE(SUM(CASE WHEN RateDenominatorSource = 'SESSION' THEN OrdersPerHour ELSE NULL END), 0), (SELECT COALESCE(SUM(OrdersPerHourPerUser), 0) FROM dbo.OrdersPerHourPerUser)
    FROM UserPick
    UNION ALL
    SELECT 'User', 'BinsPerHourPerUser', COUNT(*), (SELECT COUNT(*) FROM dbo.BinsPerHourPerUser), COALESCE(SUM(CASE WHEN RateDenominatorSource = 'SESSION' THEN BinsPerHour ELSE NULL END), 0), (SELECT COALESCE(SUM(BinsPerHour), 0) FROM dbo.BinsPerHourPerUser)
    FROM UserPick
    UNION ALL
    SELECT 'User', 'UnitsPerHourPerUser', COUNT(*), (SELECT COUNT(*) FROM dbo.UnitsPerHourPerUser), COALESCE(SUM(CASE WHEN RateDenominatorSource = 'SESSION' THEN UnitsPerHour ELSE NULL END), 0), (SELECT COALESCE(SUM(UnitsPerHour), 0) FROM dbo.UnitsPerHourPerUser)
    FROM UserPick
    UNION ALL
    SELECT 'User', 'LinesperHourPerUser', COUNT(*), (SELECT COUNT(*) FROM dbo.LinesperHourPerUser), COALESCE(SUM(CASE WHEN RateDenominatorSource = 'SESSION' THEN LinesPerHour ELSE NULL END), 0), (SELECT COALESCE(SUM(LinesPerHour), 0) FROM dbo.LinesperHourPerUser)
    FROM UserPick
    UNION ALL
    SELECT 'User', 'MachineWaitTimePerUser', COUNT(*), (SELECT COUNT(*) FROM dbo.MachineWaitTimePerUser), COALESCE(SUM(ROUND(MachineWaitMinutes, 0)), 0), (SELECT COALESCE(SUM(MachineWaitTime), 0) FROM dbo.MachineWaitTimePerUser)
    FROM UserPick
    UNION ALL
    SELECT 'User', 'AverageHandlingTimePerUser', COUNT(*), (SELECT COUNT(*) FROM dbo.AverageHandlingTimePerUser), COALESCE(SUM(AverageHandleTimePerPresentationMinutes), 0), (SELECT COALESCE(SUM(AverageHandlingTime), 0) FROM dbo.AverageHandlingTimePerUser)
    FROM UserPick
    UNION ALL
    SELECT 'User', 'TotalLoggedTimePerUser', COUNT(*), (SELECT COUNT(*) FROM dbo.TotalLoggedTimePerUser), COALESCE(SUM(ROUND(TotalLoggedMinutes, 0)), 0), (SELECT COALESCE(SUM(TotalLoggedTime), 0) FROM dbo.TotalLoggedTimePerUser)
    FROM UserPick
    UNION ALL
    SELECT 'Port', 'OrdersCompletedPerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.OrdersCompletedPerPort), COALESCE(SUM(OrdersCompleted), 0), (SELECT COALESCE(SUM(OrdersCompleted), 0) FROM dbo.OrdersCompletedPerPort)
    FROM PortPick
    UNION ALL
    SELECT 'Port', 'BinPresentationsCompletedPerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.BinPresentationsCompletedPerPort), COALESCE(SUM(BinPresentationsCompleted), 0), (SELECT COALESCE(SUM(BinPresentationsCompleted), 0) FROM dbo.BinPresentationsCompletedPerPort)
    FROM PortPick
    UNION ALL
    SELECT 'Port', 'LinesCompletedPerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.LinesCompletedPerPort), COALESCE(SUM(LinesCompleted), 0), (SELECT COALESCE(SUM(LinesCompleted), 0) FROM dbo.LinesCompletedPerPort)
    FROM PortPick
    UNION ALL
    SELECT 'Port', 'UnitsCompletedPerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.UnitsCompletedPerPort), COALESCE(SUM(UnitsCompleted), 0), (SELECT COALESCE(SUM(UnitsCompleted), 0) FROM dbo.UnitsCompletedPerPort)
    FROM PortPick
    UNION ALL
    SELECT 'Port', 'OrdersPerHourPerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.OrdersPerHourPerPort), COALESCE(SUM(CASE WHEN RateDenominatorSource = 'SESSION' THEN OrdersPerHour ELSE NULL END), 0), (SELECT COALESCE(SUM(OrdersPerHourPerPort), 0) FROM dbo.OrdersPerHourPerPort)
    FROM PortPick
    UNION ALL
    SELECT 'Port', 'BinsPerHourPerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.BinsPerHourPerPort), COALESCE(SUM(CASE WHEN RateDenominatorSource = 'SESSION' THEN BinsPerHour ELSE NULL END), 0), (SELECT COALESCE(SUM(BinsPerHour), 0) FROM dbo.BinsPerHourPerPort)
    FROM PortPick
    UNION ALL
    SELECT 'Port', 'UnitsPerHourPerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.UnitsPerHourPerPort), COALESCE(SUM(CASE WHEN RateDenominatorSource = 'SESSION' THEN UnitsPerHour ELSE NULL END), 0), (SELECT COALESCE(SUM(UnitsPerHour), 0) FROM dbo.UnitsPerHourPerPort)
    FROM PortPick
    UNION ALL
    SELECT 'Port', 'LinesperHourPerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.LinesperHourPerPort), COALESCE(SUM(CASE WHEN RateDenominatorSource = 'SESSION' THEN LinesPerHour ELSE NULL END), 0), (SELECT COALESCE(SUM(LinesPerHour), 0) FROM dbo.LinesperHourPerPort)
    FROM PortPick
    UNION ALL
    SELECT 'Port', 'MachineWaitTimePerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.MachineWaitTimePerPort), COALESCE(SUM(ROUND(MachineWaitMinutes, 0)), 0), (SELECT COALESCE(SUM(MachineWaitTime), 0) FROM dbo.MachineWaitTimePerPort)
    FROM PortPick
    UNION ALL
    SELECT 'Port', 'AverageHandlingTimePerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.AverageHandlingTimePerPort), COALESCE(SUM(AverageHandleTimePerPresentationMinutes), 0), (SELECT COALESCE(SUM(AverageHandlingTime), 0) FROM dbo.AverageHandlingTimePerPort)
    FROM PortPick
    UNION ALL
    SELECT 'Port', 'TotalLoggedTimePerPort', COUNT(*), (SELECT COUNT(*) FROM dbo.TotalLoggedTimePerPort), COALESCE(SUM(ROUND(TotalLoggedMinutes, 0)), 0), (SELECT COALESCE(SUM(TotalLoggedTime), 0) FROM dbo.TotalLoggedTimePerPort)
    FROM PortPick
)
SELECT
    Grain,
    HelperView,
    ExpectedRows,
    ActualRows,
    ActualRows - ExpectedRows AS RowDifference,
    ExpectedValue,
    ActualValue,
    ActualValue - ExpectedValue AS ValueDifference,
    CASE
        WHEN ABS(ActualRows - ExpectedRows) <= 0.001
         AND ABS(ActualValue - ExpectedValue) <= 0.001
        THEN 'PASS'
        ELSE 'REVIEW'
    END AS CheckStatus
INTO #PowerBIPatchChecks
FROM Checks
ORDER BY Grain, HelperView;

;WITH UserPick AS (
    SELECT *
    FROM dbo.v_ProductivityByUserWorkType_v2
    WHERE WorkType = 'Pick'
),
PortPick AS (
    SELECT
        CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS Ports,
        OrdersCompleted,
        BinPresentationsCompleted,
        LinesCompleted,
        UnitsCompleted,
        RateDenominatorSource,
        OrdersPerHour,
        BinsPerHour,
        UnitsPerHour,
        LinesPerHour,
        MachineWaitMinutes,
        AverageHandleTimePerPresentationMinutes,
        TotalLoggedMinutes
    FROM dbo.v_ProductivityByPortWorkType_v2
    WHERE WorkType = 'Pick'
),
RowChecks AS (
    SELECT 'User' AS Grain, 'OrdersCompletedPerUser' AS HelperView, CAST(COALESCE(e.Users, a.Users) AS varchar(100)) AS LabelValue, CAST(e.OrdersCompleted AS decimal(19, 4)) AS ExpectedValue, CAST(a.OrdersCompleted AS decimal(19, 4)) AS ActualValue
    FROM UserPick e
    FULL OUTER JOIN dbo.OrdersCompletedPerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'User', 'BinPresentationsCompletedPerUser', CAST(COALESCE(e.Users, a.Users) AS varchar(100)), CAST(e.BinPresentationsCompleted AS decimal(19, 4)), CAST(a.BinPresentationsCompleted AS decimal(19, 4))
    FROM UserPick e
    FULL OUTER JOIN dbo.BinPresentationsCompletedPerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'User', 'LinesCompletedPerUser', CAST(COALESCE(e.Users, a.Users) AS varchar(100)), CAST(e.LinesCompleted AS decimal(19, 4)), CAST(a.LinesCompleted AS decimal(19, 4))
    FROM UserPick e
    FULL OUTER JOIN dbo.LinesCompletedPerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'User', 'UnitsCompletedPerUser', CAST(COALESCE(e.Users, a.Users) AS varchar(100)), CAST(e.UnitsCompleted AS decimal(19, 4)), CAST(a.UnitsCompleted AS decimal(19, 4))
    FROM UserPick e
    FULL OUTER JOIN dbo.UnitsCompletedPerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'User', 'OrdersPerHourPerUser', CAST(COALESCE(e.Users, a.Users) AS varchar(100)), CAST(CASE WHEN e.RateDenominatorSource = 'SESSION' THEN e.OrdersPerHour ELSE NULL END AS decimal(19, 4)), CAST(a.OrdersPerHourPerUser AS decimal(19, 4))
    FROM UserPick e
    FULL OUTER JOIN dbo.OrdersPerHourPerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'User', 'BinsPerHourPerUser', CAST(COALESCE(e.Users, a.Users) AS varchar(100)), CAST(CASE WHEN e.RateDenominatorSource = 'SESSION' THEN e.BinsPerHour ELSE NULL END AS decimal(19, 4)), CAST(a.BinsPerHour AS decimal(19, 4))
    FROM UserPick e
    FULL OUTER JOIN dbo.BinsPerHourPerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'User', 'UnitsPerHourPerUser', CAST(COALESCE(e.Users, a.Users) AS varchar(100)), CAST(CASE WHEN e.RateDenominatorSource = 'SESSION' THEN e.UnitsPerHour ELSE NULL END AS decimal(19, 4)), CAST(a.UnitsPerHour AS decimal(19, 4))
    FROM UserPick e
    FULL OUTER JOIN dbo.UnitsPerHourPerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'User', 'LinesperHourPerUser', CAST(COALESCE(e.Users, a.Users) AS varchar(100)), CAST(CASE WHEN e.RateDenominatorSource = 'SESSION' THEN e.LinesPerHour ELSE NULL END AS decimal(19, 4)), CAST(a.LinesPerHour AS decimal(19, 4))
    FROM UserPick e
    FULL OUTER JOIN dbo.LinesperHourPerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'User', 'MachineWaitTimePerUser', CAST(COALESCE(e.Users, a.Users) AS varchar(100)), CAST(ROUND(e.MachineWaitMinutes, 0) AS decimal(19, 4)), CAST(a.MachineWaitTime AS decimal(19, 4))
    FROM UserPick e
    FULL OUTER JOIN dbo.MachineWaitTimePerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'User', 'AverageHandlingTimePerUser', CAST(COALESCE(e.Users, a.Users) AS varchar(100)), CAST(e.AverageHandleTimePerPresentationMinutes AS decimal(19, 4)), CAST(a.AverageHandlingTime AS decimal(19, 4))
    FROM UserPick e
    FULL OUTER JOIN dbo.AverageHandlingTimePerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'User', 'TotalLoggedTimePerUser', CAST(COALESCE(e.Users, a.Users) AS varchar(100)), CAST(ROUND(e.TotalLoggedMinutes, 0) AS decimal(19, 4)), CAST(a.TotalLoggedTime AS decimal(19, 4))
    FROM UserPick e
    FULL OUTER JOIN dbo.TotalLoggedTimePerUser a ON a.Users = e.Users
    UNION ALL
    SELECT 'Port', 'OrdersCompletedPerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(e.OrdersCompleted AS decimal(19, 4)), CAST(a.OrdersCompleted AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.OrdersCompletedPerPort a ON a.Ports = e.Ports
    UNION ALL
    SELECT 'Port', 'BinPresentationsCompletedPerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(e.BinPresentationsCompleted AS decimal(19, 4)), CAST(a.BinPresentationsCompleted AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.BinPresentationsCompletedPerPort a ON a.Ports = e.Ports
    UNION ALL
    SELECT 'Port', 'LinesCompletedPerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(e.LinesCompleted AS decimal(19, 4)), CAST(a.LinesCompleted AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.LinesCompletedPerPort a ON a.Ports = e.Ports
    UNION ALL
    SELECT 'Port', 'UnitsCompletedPerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(e.UnitsCompleted AS decimal(19, 4)), CAST(a.UnitsCompleted AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.UnitsCompletedPerPort a ON a.Ports = e.Ports
    UNION ALL
    SELECT 'Port', 'OrdersPerHourPerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(CASE WHEN e.RateDenominatorSource = 'SESSION' THEN e.OrdersPerHour ELSE NULL END AS decimal(19, 4)), CAST(a.OrdersPerHourPerPort AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.OrdersPerHourPerPort a ON a.Ports = e.Ports
    UNION ALL
    SELECT 'Port', 'BinsPerHourPerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(CASE WHEN e.RateDenominatorSource = 'SESSION' THEN e.BinsPerHour ELSE NULL END AS decimal(19, 4)), CAST(a.BinsPerHour AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.BinsPerHourPerPort a ON a.Ports = e.Ports
    UNION ALL
    SELECT 'Port', 'UnitsPerHourPerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(CASE WHEN e.RateDenominatorSource = 'SESSION' THEN e.UnitsPerHour ELSE NULL END AS decimal(19, 4)), CAST(a.UnitsPerHour AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.UnitsPerHourPerPort a ON a.Ports = e.Ports
    UNION ALL
    SELECT 'Port', 'LinesperHourPerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(CASE WHEN e.RateDenominatorSource = 'SESSION' THEN e.LinesPerHour ELSE NULL END AS decimal(19, 4)), CAST(a.LinesPerHour AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.LinesperHourPerPort a ON a.Ports = e.Ports
    UNION ALL
    SELECT 'Port', 'MachineWaitTimePerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(ROUND(e.MachineWaitMinutes, 0) AS decimal(19, 4)), CAST(a.MachineWaitTime AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.MachineWaitTimePerPort a ON a.Ports = e.Ports
    UNION ALL
    SELECT 'Port', 'AverageHandlingTimePerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(e.AverageHandleTimePerPresentationMinutes AS decimal(19, 4)), CAST(a.AverageHandlingTime AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.AverageHandlingTimePerPort a ON a.Ports = e.Ports
    UNION ALL
    SELECT 'Port', 'TotalLoggedTimePerPort', CAST(COALESCE(e.Ports, a.Ports) AS varchar(100)), CAST(ROUND(e.TotalLoggedMinutes, 0) AS decimal(19, 4)), CAST(a.TotalLoggedTime AS decimal(19, 4))
    FROM PortPick e
    FULL OUTER JOIN dbo.TotalLoggedTimePerPort a ON a.Ports = e.Ports
)
SELECT
    Grain,
    HelperView,
    LabelValue,
    ExpectedValue,
    ActualValue,
    ActualValue - ExpectedValue AS ValueDifference,
    CASE
        WHEN ExpectedValue IS NULL
         AND ActualValue IS NULL
        THEN 'PASS'
        WHEN ExpectedValue IS NOT NULL
         AND ActualValue IS NOT NULL
         AND ABS(ActualValue - ExpectedValue) <= 0.001
        THEN 'PASS'
        ELSE 'REVIEW'
    END AS CheckStatus
INTO #PowerBIRowChecks
FROM RowChecks;

SELECT
    CAST('PowerBIImportView' AS varchar(40)) AS CheckName,
    COUNT(*) AS RowsAvailable,
    MIN(EventDate) AS MinEventDate,
    MAX(EventDate) AS MaxEventDate,
    COUNT(DISTINCT WorkType) AS WorkTypes,
    COUNT(DISTINCT Users) AS Users,
    COUNT(DISTINCT Ports) AS Ports
INTO #PowerBIImportViewCheck
FROM dbo.v_ProductivityDailyUserPortWorkType_v2;

SELECT
    CASE
        WHEN NOT EXISTS (SELECT 1 FROM #PowerBIPatchChecks WHERE CheckStatus <> 'PASS')
         AND NOT EXISTS (SELECT 1 FROM #PowerBIRowChecks WHERE CheckStatus <> 'PASS')
         AND EXISTS (SELECT 1 FROM #PowerBIImportViewCheck WHERE RowsAvailable > 0)
        THEN 'PASS'
        ELSE 'REVIEW'
    END AS PowerBIPatchValidationGate,
    (SELECT COUNT(*) FROM #PowerBIPatchChecks WHERE CheckStatus <> 'PASS') AS FailedHelperViewChecks,
    (SELECT COUNT(*) FROM #PowerBIRowChecks WHERE CheckStatus <> 'PASS') AS FailedHelperViewRowChecks,
    (SELECT RowsAvailable FROM #PowerBIImportViewCheck) AS DailyAggregateRowsAvailable,
    (SELECT MinEventDate FROM #PowerBIImportViewCheck) AS DailyAggregateMinEventDate,
    (SELECT MaxEventDate FROM #PowerBIImportViewCheck) AS DailyAggregateMaxEventDate,
    (SELECT WorkTypes FROM #PowerBIImportViewCheck) AS DailyAggregateWorkTypes,
    (SELECT Users FROM #PowerBIImportViewCheck) AS DailyAggregateUsers,
    (SELECT Ports FROM #PowerBIImportViewCheck) AS DailyAggregatePorts;

SELECT *
FROM #PowerBIPatchChecks
ORDER BY Grain, HelperView;

SELECT *
FROM #PowerBIRowChecks
ORDER BY Grain, LabelValue, HelperView;

SELECT *
FROM #PowerBIImportViewCheck;
GO
