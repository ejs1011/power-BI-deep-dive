USE [KFX_REPORTING]
GO

/*
    Optional drop-in patch for the existing Power BI Productivity by User / Port page.

    Prerequisite:
      Run create-reporting-productivity-work-events-v4.5.0.sql first and validate:
        - dbo.v_ProductivityCurrentFeedReadiness_v2
        - dbo.v_ProductivityValidation_v2
        - dbo.v_ProductivityByUserWorkType_v2
        - dbo.v_ProductivityByPortWorkType_v2

    What this does:
      Repoints the existing report-facing productivity views to the v2 event grain.
      The PBIX already imports these view names, so this is the lowest-friction
      way to test the corrected logic without changing visual field bindings.

    Important:
      These drop-in views intentionally use WorkType = 'Pick'. The current PBIX
      page has no WorkType column, and mixing PutAway/CycleCount time into pick
      order/line/unit rates would make the headline productivity values misleading.

      /HR fields only populate when the v2 denominator source is SESSION.
      HANDLE_FALLBACK remains available in the v2 diagnostic views, but this
      drop-in patch does not surface fallback-denominator rates in the PBIX.

      Integer-shaped fields are rounded to whole minutes to match the current
      PBIX metadata. For more precise time reporting, update the PBIX model to
      consume the v2 views directly and use decimal columns.
*/

CREATE OR ALTER VIEW [dbo].[OrdersCompletedPerUser]
AS
SELECT
    CAST(Users AS nvarchar(50)) AS Users,
    CAST(OrdersCompleted AS int) AS OrdersCompleted
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[OrdersCompletedPerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(OrdersCompleted AS int) AS OrdersCompleted
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[BinPresentationsCompletedPerUser]
AS
SELECT
    CAST(Users AS varchar(50)) AS Users,
    CAST(BinPresentationsCompleted AS int) AS BinPresentationsCompleted
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[BinPresentationsCompletedPerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(BinPresentationsCompleted AS int) AS BinPresentationsCompleted
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[LinesCompletedPerUser]
AS
SELECT
    CAST(Users AS nvarchar(50)) AS Users,
    CAST(LinesCompleted AS int) AS LinesCompleted
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[LinesCompletedPerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(LinesCompleted AS int) AS LinesCompleted
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[UnitsCompletedPerUser]
AS
SELECT
    CAST(Users AS varchar(50)) AS Users,
    CAST(UnitsCompleted AS bigint) AS UnitsCompleted
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[UnitsCompletedPerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(UnitsCompleted AS bigint) AS UnitsCompleted
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[OrdersPerHourPerUser]
AS
SELECT
    CAST(Users AS nvarchar(50)) AS Users,
    CAST(CASE WHEN RateDenominatorSource = 'SESSION' THEN OrdersPerHour ELSE NULL END AS float) AS OrdersPerHourPerUser
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[OrdersPerHourPerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(CASE WHEN RateDenominatorSource = 'SESSION' THEN OrdersPerHour ELSE NULL END AS float) AS OrdersPerHourPerPort
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[BinsPerHourPerUser]
AS
SELECT
    CAST(Users AS varchar(50)) AS Users,
    CAST(CASE WHEN RateDenominatorSource = 'SESSION' THEN BinsPerHour ELSE NULL END AS float) AS BinsPerHour
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[BinsPerHourPerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(CASE WHEN RateDenominatorSource = 'SESSION' THEN BinsPerHour ELSE NULL END AS float) AS BinsPerHour
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[LinesperHourPerUser]
AS
SELECT
    CAST(Users AS nvarchar(50)) AS Users,
    CAST(CASE WHEN RateDenominatorSource = 'SESSION' THEN LinesPerHour ELSE NULL END AS float) AS LinesPerHour
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[LinesperHourPerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(CASE WHEN RateDenominatorSource = 'SESSION' THEN LinesPerHour ELSE NULL END AS float) AS LinesPerHour
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[UnitsPerHourPerUser]
AS
SELECT
    CAST(Users AS varchar(50)) AS Users,
    CAST(CASE WHEN RateDenominatorSource = 'SESSION' THEN UnitsPerHour ELSE NULL END AS float) AS UnitsPerHour
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[UnitsPerHourPerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(CASE WHEN RateDenominatorSource = 'SESSION' THEN UnitsPerHour ELSE NULL END AS float) AS UnitsPerHour
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[AverageHandlingTimePerUser]
AS
SELECT
    CAST(Users AS varchar(50)) AS Users,
    CAST(AverageHandleTimePerPresentationMinutes AS float) AS AverageHandlingTime
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[AverageHandlingTimePerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(AverageHandleTimePerPresentationMinutes AS float) AS AverageHandlingTime
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[MachineWaitTimePerUser]
AS
SELECT
    CAST(Users AS varchar(50)) AS Users,
    CAST(ROUND(MachineWaitMinutes, 0) AS bigint) AS MachineWaitTime
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[MachineWaitTimePerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(ROUND(MachineWaitMinutes, 0) AS bigint) AS MachineWaitTime
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[TotalLoggedTimePerUser]
AS
SELECT
    CAST(Users AS varchar(50)) AS Users,
    CAST(ROUND(TotalLoggedMinutes, 0) AS bigint) AS TotalLoggedTime
FROM dbo.v_ProductivityByUserWorkType_v2
WHERE WorkType = 'Pick';
GO

CREATE OR ALTER VIEW [dbo].[TotalLoggedTimePerPort]
AS
SELECT
    CAST(CASE WHEN Ports = 'Unattributed' THEN 'No Data' ELSE Ports END AS varchar(50)) AS Ports,
    CAST(ROUND(TotalLoggedMinutes, 0) AS bigint) AS TotalLoggedTime
FROM dbo.v_ProductivityByPortWorkType_v2
WHERE WorkType = 'Pick';
GO
