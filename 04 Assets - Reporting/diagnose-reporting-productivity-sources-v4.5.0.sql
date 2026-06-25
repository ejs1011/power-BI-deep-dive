USE [KFX_REPORTING]
GO

/*
    Read-only source coverage diagnostic for Productivity reported metrics.

    Purpose:
      Identify which physical source table contains the event telemetry needed
      for Productivity by User / Port before changing reporting sync logic or
      promoting the v2 Power BI compatibility views.

    This script does not modify any data.
*/

IF OBJECT_ID('tempdb..#ReportedMetricSourceCoverage') IS NOT NULL
BEGIN
    DROP TABLE #ReportedMetricSourceCoverage;
END;

CREATE TABLE #ReportedMetricSourceCoverage
(
    SourceDatabase sysname NOT NULL,
    SourceTable sysname NOT NULL,
    DataDescription nvarchar(100) NULL,
    Rows bigint NOT NULL,
    MinPrimaryKey bigint NULL,
    MaxPrimaryKey bigint NULL,
    MinTimestamp datetime NULL,
    MaxTimestamp datetime NULL
);

IF OBJECT_ID(N'[KFX_AUTOSTORE].[dbo].[ReportedMetrics]', N'U') IS NOT NULL
BEGIN
    INSERT INTO #ReportedMetricSourceCoverage
    SELECT
        N'KFX_AUTOSTORE',
        N'ReportedMetrics',
        DataDescription,
        COUNT_BIG(*),
        MIN(PrimaryKey),
        MAX(PrimaryKey),
        MIN([TimeStamp]),
        MAX([TimeStamp])
    FROM [KFX_AUTOSTORE].[dbo].[ReportedMetrics]
    GROUP BY DataDescription;
END;

IF OBJECT_ID(N'[KFX_AUTOSTORE_ARCHIVE].[dbo].[ReportedMetrics]', N'U') IS NOT NULL
BEGIN
    INSERT INTO #ReportedMetricSourceCoverage
    SELECT
        N'KFX_AUTOSTORE_ARCHIVE',
        N'ReportedMetrics',
        DataDescription,
        COUNT_BIG(*),
        MIN(PrimaryKey),
        MAX(PrimaryKey),
        MIN([TimeStamp]),
        MAX([TimeStamp])
    FROM [KFX_AUTOSTORE_ARCHIVE].[dbo].[ReportedMetrics]
    GROUP BY DataDescription;
END;

IF OBJECT_ID(N'[KFX_AUTOSTORE_ARCHIVE_NEW].[dbo].[ArchiveReportedMetrics]', N'U') IS NOT NULL
BEGIN
    INSERT INTO #ReportedMetricSourceCoverage
    SELECT
        N'KFX_AUTOSTORE_ARCHIVE_NEW',
        N'ArchiveReportedMetrics',
        DataDescription,
        COUNT_BIG(*),
        MIN(PrimaryKey),
        MAX(PrimaryKey),
        MIN([TimeStamp]),
        MAX([TimeStamp])
    FROM [KFX_AUTOSTORE_ARCHIVE_NEW].[dbo].[ArchiveReportedMetrics]
    GROUP BY DataDescription;
END;

IF OBJECT_ID(N'[KFX_OLD_ARCHIVE].[dbo].[ReportedMetrics]', N'U') IS NOT NULL
BEGIN
    INSERT INTO #ReportedMetricSourceCoverage
    SELECT
        N'KFX_OLD_ARCHIVE',
        N'ReportedMetrics',
        DataDescription,
        COUNT_BIG(*),
        MIN(PrimaryKey),
        MAX(PrimaryKey),
        MIN([TimeStamp]),
        MAX([TimeStamp])
    FROM [KFX_OLD_ARCHIVE].[dbo].[ReportedMetrics]
    GROUP BY DataDescription;
END;

SELECT
    SourceDatabase,
    SourceTable,
    SUM(Rows) AS Rows,
    MIN(MinPrimaryKey) AS MinPrimaryKey,
    MAX(MaxPrimaryKey) AS MaxPrimaryKey,
    MIN(MinTimestamp) AS MinTimestamp,
    MAX(MaxTimestamp) AS MaxTimestamp
FROM #ReportedMetricSourceCoverage
GROUP BY SourceDatabase, SourceTable
ORDER BY MaxTimestamp DESC, SourceDatabase, SourceTable;

SELECT
    SourceDatabase,
    SourceTable,
    DataDescription,
    Rows,
    MinPrimaryKey,
    MaxPrimaryKey,
    MinTimestamp,
    MaxTimestamp
FROM #ReportedMetricSourceCoverage
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
ORDER BY DataDescription, MaxTimestamp DESC, SourceDatabase, SourceTable;

WITH RankedLatest AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY DataDescription
            ORDER BY MaxTimestamp DESC, SourceDatabase, SourceTable
        ) AS LatestRank
    FROM #ReportedMetricSourceCoverage
)
SELECT
    DataDescription,
    SourceDatabase AS LatestSourceDatabase,
    SourceTable AS LatestSourceTable,
    Rows,
    MinPrimaryKey,
    MaxPrimaryKey,
    MinTimestamp,
    MaxTimestamp
FROM RankedLatest
WHERE LatestRank = 1
ORDER BY MaxTimestamp DESC, DataDescription;
GO
