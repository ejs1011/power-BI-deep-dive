USE [KFX_REPORTING]
GO

/*
    Source-aware reported-metric grain for Productivity analysis.

    This script is additive and read-only against source databases. It creates
    views only in KFX_REPORTING.

    Why this exists:
      dbo.Report_Data has PrimaryKey as its primary key. That makes it unsafe to
      union live and archive reported metrics into Report_Data when source
      databases reuse or overlap PrimaryKey ranges.

      These views keep the physical source identity and de-duplicate by
      DataDescription + TimeStamp + JsonData hash instead of assuming PrimaryKey
      is globally unique.

    Use this layer to reason about historical source coverage before changing
    the reporting sync or redesigning the PBIX page.
*/

CREATE OR ALTER VIEW [dbo].[v_ProductivityReportedMetricSources_v2]
AS
SELECT
    CAST('KFX_AUTOSTORE' AS sysname) AS SourceDatabase,
    CAST('ReportedMetrics' AS sysname) AS SourceTable,
    CAST(1 AS int) AS SourcePriority,
    CAST(PrimaryKey AS bigint) AS SourcePrimaryKey,
    CAST(DataDescription AS nvarchar(100)) AS DataDescription,
    CAST(JsonData AS nvarchar(max)) AS JsonData,
    CAST([TimeStamp] AS datetime2(7)) AS EventTimestamp
FROM [KFX_AUTOSTORE].[dbo].[ReportedMetrics]
UNION ALL
SELECT
    CAST('KFX_AUTOSTORE_ARCHIVE_NEW' AS sysname),
    CAST('ArchiveReportedMetrics' AS sysname),
    CAST(2 AS int),
    CAST(PrimaryKey AS bigint),
    CAST(DataDescription AS nvarchar(100)),
    CAST(JsonData AS nvarchar(max)),
    CAST([TimeStamp] AS datetime2(7))
FROM [KFX_AUTOSTORE_ARCHIVE_NEW].[dbo].[ArchiveReportedMetrics]
UNION ALL
SELECT
    CAST('KFX_AUTOSTORE_ARCHIVE' AS sysname),
    CAST('ReportedMetrics' AS sysname),
    CAST(3 AS int),
    CAST(PrimaryKey AS bigint),
    CAST(DataDescription AS nvarchar(100)),
    CAST(JsonData AS nvarchar(max)),
    CAST([TimeStamp] AS datetime2(7))
FROM [KFX_AUTOSTORE_ARCHIVE].[dbo].[ReportedMetrics]
UNION ALL
SELECT
    CAST('KFX_OLD_ARCHIVE' AS sysname),
    CAST('ReportedMetrics' AS sysname),
    CAST(4 AS int),
    CAST(PrimaryKey AS bigint),
    CAST(DataDescription AS nvarchar(100)),
    CAST(JsonData AS nvarchar(max)),
    CAST([TimeStamp] AS datetime2(7))
FROM [KFX_OLD_ARCHIVE].[dbo].[ReportedMetrics];
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityReportedMetricDeduped_v2]
AS
WITH Hashed AS (
    SELECT
        SourceDatabase,
        SourceTable,
        SourcePriority,
        SourcePrimaryKey,
        DataDescription,
        JsonData,
        EventTimestamp,
        HASHBYTES(
            'SHA2_256',
            CONVERT(varbinary(max), CONCAT(DataDescription, N'|', CONVERT(nvarchar(40), EventTimestamp, 126), N'|', JsonData))
        ) AS EventHash
    FROM dbo.v_ProductivityReportedMetricSources_v2
),
Ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY DataDescription, EventTimestamp, EventHash
            ORDER BY SourcePriority, SourceDatabase, SourceTable, SourcePrimaryKey
        ) AS SourceRank,
        COUNT_BIG(*) OVER (
            PARTITION BY DataDescription, EventTimestamp, EventHash
        ) AS DuplicateSourceRows
    FROM Hashed
)
SELECT
    SourceDatabase,
    SourceTable,
    SourcePriority,
    SourcePrimaryKey,
    DataDescription,
    JsonData,
    EventTimestamp,
    EventHash,
    DuplicateSourceRows
FROM Ranked
WHERE SourceRank = 1;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityReportedMetricSourceDiagnostics_v2]
AS
SELECT
    SourceDatabase,
    SourceTable,
    DataDescription,
    COUNT_BIG(*) AS SourceRows,
    MIN(SourcePrimaryKey) AS MinSourcePrimaryKey,
    MAX(SourcePrimaryKey) AS MaxSourcePrimaryKey,
    MIN(EventTimestamp) AS MinEventTimestamp,
    MAX(EventTimestamp) AS MaxEventTimestamp
FROM dbo.v_ProductivityReportedMetricSources_v2
GROUP BY SourceDatabase, SourceTable, DataDescription;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityReportedMetricDedupDiagnostics_v2]
AS
SELECT
    DataDescription,
    COUNT_BIG(*) AS DedupedRows,
    SUM(DuplicateSourceRows - 1) AS RemovedDuplicateRows,
    MIN(EventTimestamp) AS MinEventTimestamp,
    MAX(EventTimestamp) AS MaxEventTimestamp
FROM dbo.v_ProductivityReportedMetricDeduped_v2
GROUP BY DataDescription;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityRawWorkSessions_v2]
AS
WITH SignIns AS (
    SELECT
        CASE DataDescription
            WHEN 'Pick-SignIn' THEN 'Pick'
            WHEN 'PutAway-SignIn' THEN 'PutAway'
            WHEN 'CycleCount-SignIn' THEN 'CycleCount'
            WHEN 'OnDemand-SignIn' THEN 'OnDemand'
            ELSE REPLACE(DataDescription, '-SignIn', '')
        END AS WorkType,
        SourceDatabase,
        SourceTable,
        SourcePrimaryKey,
        EventTimestamp,
        JsonData,
        JSON_VALUE(JsonData, '$.User') AS [User],
        TRY_CAST(JSON_VALUE(JsonData, '$.LocationPrimaryKey') AS bigint) AS LocationPrimaryKey
    FROM dbo.v_ProductivityReportedMetricDeduped_v2
    WHERE DataDescription IN ('Pick-SignIn', 'PutAway-SignIn', 'CycleCount-SignIn', 'OnDemand-SignIn')
),
SignOuts AS (
    SELECT
        CASE DataDescription
            WHEN 'Pick-SignOut' THEN 'Pick'
            WHEN 'PutAway-SignOut' THEN 'PutAway'
            WHEN 'CycleCount-SignOut' THEN 'CycleCount'
            WHEN 'OnDemand-SignOut' THEN 'OnDemand'
            ELSE REPLACE(DataDescription, '-SignOut', '')
        END AS WorkType,
        SourceDatabase,
        SourceTable,
        SourcePrimaryKey,
        EventTimestamp,
        JsonData,
        JSON_VALUE(JsonData, '$.User') AS [User],
        TRY_CAST(JSON_VALUE(JsonData, '$.LocationPrimaryKey') AS bigint) AS LocationPrimaryKey
    FROM dbo.v_ProductivityReportedMetricDeduped_v2
    WHERE DataDescription IN ('Pick-SignOut', 'PutAway-SignOut', 'CycleCount-SignOut', 'OnDemand-SignOut')
),
RankedSignIns AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY WorkType, LocationPrimaryKey, [User], CAST(EventTimestamp AS date)
            ORDER BY EventTimestamp, SourcePrioritySort
        ) AS SessionRank
    FROM (
        SELECT
            *,
            CONCAT(SourceDatabase, ':', SourceTable, ':', SourcePrimaryKey) AS SourcePrioritySort
        FROM SignIns
    ) s
    WHERE [User] IS NOT NULL
),
RankedSignOuts AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY WorkType, LocationPrimaryKey, [User], CAST(EventTimestamp AS date)
            ORDER BY EventTimestamp, SourcePrioritySort
        ) AS SessionRank
    FROM (
        SELECT
            *,
            CONCAT(SourceDatabase, ':', SourceTable, ':', SourcePrimaryKey) AS SourcePrioritySort
        FROM SignOuts
    ) s
    WHERE [User] IS NOT NULL
)
SELECT
    signin.WorkType,
    signin.[User],
    signin.LocationPrimaryKey,
    CAST(NULL AS varchar(50)) AS Port,
    signin.EventTimestamp AS SignInTime,
    signout.EventTimestamp AS SignOutTime,
    CAST(
        CASE
            WHEN signout.EventTimestamp > signin.EventTimestamp
            THEN DATEDIFF_BIG(millisecond, signin.EventTimestamp, signout.EventTimestamp) / 1000.0
            ELSE NULL
        END
        AS decimal(19, 3)
    ) AS SessionSeconds,
    signin.SourceDatabase AS SignInSourceDatabase,
    signin.SourceTable AS SignInSourceTable,
    signin.SourcePrimaryKey AS SignInSourcePrimaryKey,
    signout.SourceDatabase AS SignOutSourceDatabase,
    signout.SourceTable AS SignOutSourceTable,
    signout.SourcePrimaryKey AS SignOutSourcePrimaryKey
FROM RankedSignIns signin
INNER JOIN RankedSignOuts signout
    ON signout.WorkType = signin.WorkType
    AND signout.LocationPrimaryKey = signin.LocationPrimaryKey
    AND signout.[User] = signin.[User]
    AND signout.SessionRank = signin.SessionRank
    AND CAST(signout.EventTimestamp AS date) = CAST(signin.EventTimestamp AS date)
    AND signout.EventTimestamp > signin.EventTimestamp;
GO

CREATE OR ALTER VIEW [dbo].[v_ProductivityRawEventSummary_v2]
AS
SELECT
    DataDescription,
    COUNT_BIG(*) AS EventRows,
    SUM(CASE WHEN JSON_VALUE(JsonData, '$.User') IS NOT NULL THEN 1 ELSE 0 END) AS RowsWithUser,
    SUM(CASE WHEN JSON_VALUE(JsonData, '$.LocationBarcode') IS NOT NULL THEN 1 ELSE 0 END) AS RowsWithPort,
    MIN(EventTimestamp) AS MinEventTimestamp,
    MAX(EventTimestamp) AS MaxEventTimestamp
FROM dbo.v_ProductivityReportedMetricDeduped_v2
GROUP BY DataDescription;
GO
