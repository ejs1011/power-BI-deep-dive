USE [KFX_REPORTING];
GO

SET NOCOUNT ON;

/*
    Daily KPI sync troubleshooting script.

    Purpose:
      Explain why the Daily KPI inventory/inbound sections have no recent rows
      after the Daily KPI source diagnostic shows stale SQL views.

    This script is read-only. It checks:
      - SQL Agent history for the snapshot job.
      - The DataSyncDetail top-level snapshot batches.
      - Snapshot table freshness for inventory/inbound source tables.
      - Live KFX_AUTOSTORE source-table freshness, when accessible.
*/

DECLARE @Today date = CAST(GETDATE() AS date);
DECLARE @DefaultStartDate date = DATEADD(day, -7, @Today);

SELECT
    @@SERVERNAME AS ServerName,
    DB_NAME() AS DatabaseName,
    @DefaultStartDate AS PowerBIDefaultStartDate,
    @Today AS Today,
    GETDATE() AS DiagnosticRunTime;

PRINT 'Recent top-level reporting sync batches.';

SELECT TOP (30)
    Id,
    JobName,
    BatchId,
    SyncStartTime,
    SyncEndTime,
    DATEDIFF(second, SyncStartTime, COALESCE(SyncEndTime, GETDATE())) AS DurationSeconds,
    IsStarted,
    IsCompleted,
    IsDeleted,
    DatabaseName,
    TableName
FROM dbo.DataSyncDetail
WHERE TableName IS NULL
  AND JobName IN ('DynamicTableInsert', 'DyanamicTableInsert', 'DeleteDynamicData', 'TableSync')
ORDER BY Id DESC;

PRINT 'Reporting sync batch summary.';

SELECT
    JobName,
    COUNT_BIG(*) AS Rows,
    MAX(SyncStartTime) AS LastStartTime,
    MAX(SyncEndTime) AS LastEndTime,
    SUM(CASE WHEN IsStarted = 1 AND ISNULL(IsCompleted, 0) = 0 THEN 1 ELSE 0 END) AS OpenRows,
    SUM(CASE WHEN IsStarted = 1 AND IsCompleted = 1 THEN 1 ELSE 0 END) AS CompletedRows,
    SUM(CASE WHEN ISNULL(IsDeleted, 0) = 1 THEN 1 ELSE 0 END) AS DeletedRows
FROM dbo.DataSyncDetail
WHERE TableName IS NULL
  AND JobName IN ('DynamicTableInsert', 'DyanamicTableInsert', 'DeleteDynamicData', 'TableSync')
GROUP BY JobName
ORDER BY JobName;

PRINT 'Relevant non-snapshot table sync rows.';

SELECT TOP (40)
    Id,
    JobName,
    DatabaseName,
    TableName,
    BatchId,
    StartPrimaryKey,
    EndPrimaryKey,
    SyncStartTime,
    SyncEndTime,
    DATEDIFF(second, SyncStartTime, COALESCE(SyncEndTime, GETDATE())) AS DurationSeconds,
    IsStarted,
    IsCompleted,
    TotalRecordSource,
    TotalRecordSynced
FROM dbo.DataSyncDetail
WHERE TableName IN ('ReportedMetrics', 'InventoryTaskActions')
ORDER BY Id DESC;

PRINT 'Snapshot table freshness.';

IF OBJECT_ID('tempdb..#SnapshotTargets') IS NOT NULL DROP TABLE #SnapshotTargets;
CREATE TABLE #SnapshotTargets (
    TableName sysname NOT NULL,
    UsedBy varchar(50) NOT NULL
);

INSERT INTO #SnapshotTargets (TableName, UsedBy)
VALUES
    ('Inventory_Snapshot', 'Inventory'),
    ('Containers_Snapshot', 'Inventory'),
    ('PutAwayContainers_Snapshot', 'Inbound'),
    ('PutAwayContainerLineItems_Snapshot', 'Inbound'),
    ('InventoryTasks_PutAway_Snapshot', 'Inbound'),
    ('InventoryTasks_Snapshot', 'Inbound'),
    ('CompartmentSizes_Snapshot', 'Inventory Location'),
    ('ContainerTemplates_Snapshot', 'Inventory Location');

IF OBJECT_ID('tempdb..#SnapshotHealth') IS NOT NULL DROP TABLE #SnapshotHealth;
CREATE TABLE #SnapshotHealth (
    UsedBy varchar(50) NOT NULL,
    TableName sysname NOT NULL,
    ObjectStatus varchar(40) NOT NULL,
    Rows bigint NULL,
    DistinctSnapshotIds bigint NULL,
    MinSnapshotDate date NULL,
    MaxSnapshotDate date NULL,
    MaxSnapshotId bigint NULL,
    RowsInLatestSnapshot bigint NULL,
    RowsInPowerBIDefaultWindow bigint NULL
);

DECLARE @SnapshotTableName sysname;
DECLARE @SnapshotUsedBy varchar(50);
DECLARE @SnapshotSql nvarchar(max);

DECLARE snapshot_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT TableName, UsedBy
    FROM #SnapshotTargets
    ORDER BY UsedBy, TableName;

OPEN snapshot_cursor;
FETCH NEXT FROM snapshot_cursor INTO @SnapshotTableName, @SnapshotUsedBy;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(N'dbo.' + @SnapshotTableName, N'U') IS NULL
    BEGIN
        INSERT INTO #SnapshotHealth (UsedBy, TableName, ObjectStatus)
        VALUES (@SnapshotUsedBy, @SnapshotTableName, 'MISSING_OR_INACCESSIBLE');
    END
    ELSE
    BEGIN
        SET @SnapshotSql = N'
            DECLARE @MaxSnapshotId bigint;

            SELECT @MaxSnapshotId = MAX(Snapshot_Id)
            FROM dbo.' + QUOTENAME(@SnapshotTableName) + N';

            INSERT INTO #SnapshotHealth (
                UsedBy,
                TableName,
                ObjectStatus,
                Rows,
                DistinctSnapshotIds,
                MinSnapshotDate,
                MaxSnapshotDate,
                MaxSnapshotId,
                RowsInLatestSnapshot,
                RowsInPowerBIDefaultWindow
            )
            SELECT
                @UsedBy,
                @TableName,
                ''OK'',
                COUNT_BIG(*),
                COUNT_BIG(DISTINCT Snapshot_Id),
                MIN(CAST(Snapshot_Timestamp AS date)),
                MAX(CAST(Snapshot_Timestamp AS date)),
                @MaxSnapshotId,
                SUM(CASE WHEN Snapshot_Id = @MaxSnapshotId THEN 1 ELSE 0 END),
                SUM(CASE WHEN CAST(Snapshot_Timestamp AS date) >= @DefaultStartDate THEN 1 ELSE 0 END)
            FROM dbo.' + QUOTENAME(@SnapshotTableName) + N';';

        EXEC sys.sp_executesql
            @SnapshotSql,
            N'@UsedBy varchar(50), @TableName sysname, @DefaultStartDate date',
            @UsedBy = @SnapshotUsedBy,
            @TableName = @SnapshotTableName,
            @DefaultStartDate = @DefaultStartDate;
    END

    FETCH NEXT FROM snapshot_cursor INTO @SnapshotTableName, @SnapshotUsedBy;
END

CLOSE snapshot_cursor;
DEALLOCATE snapshot_cursor;

SELECT
    UsedBy,
    TableName,
    ObjectStatus,
    Rows,
    DistinctSnapshotIds,
    MinSnapshotDate,
    MaxSnapshotDate,
    MaxSnapshotId,
    RowsInLatestSnapshot,
    RowsInPowerBIDefaultWindow
FROM #SnapshotHealth
ORDER BY
    CASE UsedBy WHEN 'Inventory' THEN 1 WHEN 'Inbound' THEN 2 ELSE 3 END,
    TableName;

PRINT 'Live KFX_AUTOSTORE source table freshness.';

IF OBJECT_ID('tempdb..#SourceTargets') IS NOT NULL DROP TABLE #SourceTargets;
CREATE TABLE #SourceTargets (
    UsedBy varchar(50) NOT NULL,
    SourceDb sysname NOT NULL,
    SchemaName sysname NOT NULL,
    TableName sysname NOT NULL,
    PrimaryColumn sysname NULL,
    DateColumn sysname NULL
);

INSERT INTO #SourceTargets (UsedBy, SourceDb, SchemaName, TableName, PrimaryColumn, DateColumn)
VALUES
    ('Inventory', 'KFX_AUTOSTORE', 'dbo', 'Inventory', 'PrimaryKey', 'LastUpdatedDate'),
    ('Inventory', 'KFX_AUTOSTORE', 'dbo', 'Containers', 'PrimaryKey', 'LastUpdatedDate'),
    ('Inbound', 'KFX_AUTOSTORE', 'dbo', 'PutAwayContainers', 'PrimaryKey', 'LastUpdatedDate'),
    ('Inbound', 'KFX_AUTOSTORE', 'dbo', 'PutAwayContainerLineItems', 'PrimaryKey', 'LastUpdatedDate'),
    ('Inbound', 'KFX_AUTOSTORE', 'dbo', 'InventoryTasks_PutAway', 'InventoryTaskPrimaryKey', NULL),
    ('Inbound', 'KFX_AUTOSTORE', 'dbo', 'InventoryTasks', 'PrimaryKey', 'LastUpdatedDate'),
    ('Inbound', 'KFX_AUTOSTORE', 'dbo', 'InventoryTaskActions', 'InventoryTaskPrimaryKey', 'CompletedTime');

IF OBJECT_ID('tempdb..#SourceHealth') IS NOT NULL DROP TABLE #SourceHealth;
CREATE TABLE #SourceHealth (
    UsedBy varchar(50) NOT NULL,
    SourceDb sysname NOT NULL,
    TableName sysname NOT NULL,
    ObjectStatus varchar(80) NOT NULL,
    Rows bigint NULL,
    MaxPrimaryKey bigint NULL,
    MinSourceDate datetime2(0) NULL,
    MaxSourceDate datetime2(0) NULL,
    RowsInPowerBIDefaultWindow bigint NULL
);

DECLARE @UsedBy varchar(50);
DECLARE @SourceDb sysname;
DECLARE @SchemaName sysname;
DECLARE @TableName sysname;
DECLARE @PrimaryColumn sysname;
DECLARE @DateColumn sysname;
DECLARE @MetadataObjectName nvarchar(776);
DECLARE @SourceObjectName nvarchar(776);
DECLARE @HasPrimaryColumn bit;
DECLARE @HasDateColumn bit;
DECLARE @MaxPrimaryExpr nvarchar(max);
DECLARE @MinDateExpr nvarchar(max);
DECLARE @MaxDateExpr nvarchar(max);
DECLARE @RecentRowsExpr nvarchar(max);
DECLARE @SourceSql nvarchar(max);

DECLARE source_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT UsedBy, SourceDb, SchemaName, TableName, PrimaryColumn, DateColumn
    FROM #SourceTargets
    ORDER BY UsedBy, TableName;

OPEN source_cursor;
FETCH NEXT FROM source_cursor INTO @UsedBy, @SourceDb, @SchemaName, @TableName, @PrimaryColumn, @DateColumn;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @MetadataObjectName = QUOTENAME(@SourceDb) + N'.' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);
    SET @SourceObjectName = @SourceDb + N'.' + @SchemaName + N'.' + @TableName;

    IF DB_ID(@SourceDb) IS NULL
    BEGIN
        INSERT INTO #SourceHealth (UsedBy, SourceDb, TableName, ObjectStatus)
        VALUES (@UsedBy, @SourceDb, @TableName, 'SOURCE_DATABASE_MISSING_OR_INACCESSIBLE');
    END
    ELSE IF OBJECT_ID(@SourceObjectName, N'U') IS NULL
    BEGIN
        INSERT INTO #SourceHealth (UsedBy, SourceDb, TableName, ObjectStatus)
        VALUES (@UsedBy, @SourceDb, @TableName, 'SOURCE_TABLE_MISSING_OR_INACCESSIBLE');
    END
    ELSE
    BEGIN
        SET @HasPrimaryColumn = CASE WHEN @PrimaryColumn IS NOT NULL AND COL_LENGTH(@SourceObjectName, @PrimaryColumn) IS NOT NULL THEN 1 ELSE 0 END;
        SET @HasDateColumn = CASE WHEN @DateColumn IS NOT NULL AND COL_LENGTH(@SourceObjectName, @DateColumn) IS NOT NULL THEN 1 ELSE 0 END;
        SET @MaxPrimaryExpr = CASE WHEN @HasPrimaryColumn = 1 THEN N'MAX(TRY_CONVERT(bigint, ' + QUOTENAME(@PrimaryColumn) + N'))' ELSE N'CAST(NULL AS bigint)' END;
        SET @MinDateExpr = CASE WHEN @HasDateColumn = 1 THEN N'MIN(TRY_CONVERT(datetime2(0), ' + QUOTENAME(@DateColumn) + N'))' ELSE N'CAST(NULL AS datetime2(0))' END;
        SET @MaxDateExpr = CASE WHEN @HasDateColumn = 1 THEN N'MAX(TRY_CONVERT(datetime2(0), ' + QUOTENAME(@DateColumn) + N'))' ELSE N'CAST(NULL AS datetime2(0))' END;
        SET @RecentRowsExpr = CASE WHEN @HasDateColumn = 1 THEN N'SUM(CASE WHEN TRY_CONVERT(date, ' + QUOTENAME(@DateColumn) + N') >= @DefaultStartDate THEN 1 ELSE 0 END)' ELSE N'CAST(NULL AS bigint)' END;

        SET @SourceSql = N'
            INSERT INTO #SourceHealth (
                UsedBy,
                SourceDb,
                TableName,
                ObjectStatus,
                Rows,
                MaxPrimaryKey,
                MinSourceDate,
                MaxSourceDate,
                RowsInPowerBIDefaultWindow
            )
            SELECT
                @UsedBy,
                @SourceDb,
                @TableName,
                ''OK'',
                COUNT_BIG(*),
                ' + @MaxPrimaryExpr + N',
                ' + @MinDateExpr + N',
                ' + @MaxDateExpr + N',
                ' + @RecentRowsExpr + N'
            FROM ' + @MetadataObjectName + N';';

        EXEC sys.sp_executesql
            @SourceSql,
            N'@UsedBy varchar(50), @SourceDb sysname, @TableName sysname, @DefaultStartDate date',
            @UsedBy = @UsedBy,
            @SourceDb = @SourceDb,
            @TableName = @TableName,
            @DefaultStartDate = @DefaultStartDate;
    END

    FETCH NEXT FROM source_cursor INTO @UsedBy, @SourceDb, @SchemaName, @TableName, @PrimaryColumn, @DateColumn;
END

CLOSE source_cursor;
DEALLOCATE source_cursor;

SELECT
    UsedBy,
    SourceDb,
    TableName,
    ObjectStatus,
    Rows,
    MaxPrimaryKey,
    MinSourceDate,
    MaxSourceDate,
    RowsInPowerBIDefaultWindow
FROM #SourceHealth
ORDER BY
    CASE UsedBy WHEN 'Inventory' THEN 1 WHEN 'Inbound' THEN 2 ELSE 3 END,
    TableName;

PRINT 'SQL Agent reporting job schedule.';

IF OBJECT_ID('tempdb..#AgentSchedule') IS NOT NULL DROP TABLE #AgentSchedule;
CREATE TABLE #AgentSchedule (
    JobName sysname NULL,
    JobEnabled varchar(20) NULL,
    ScheduleName sysname NULL,
    ScheduleEnabled varchar(20) NULL,
    NextRunAt datetime NULL,
    DiagnosticStatus varchar(40) NOT NULL,
    Details nvarchar(4000) NULL
);

BEGIN TRY
    EXEC sys.sp_executesql N'
        INSERT INTO #AgentSchedule (
            JobName,
            JobEnabled,
            ScheduleName,
            ScheduleEnabled,
            NextRunAt,
            DiagnosticStatus,
            Details
        )
        SELECT
            j.name,
            CASE WHEN j.enabled = 1 THEN ''Enabled'' ELSE ''Disabled'' END,
            s.name,
            CASE WHEN s.enabled = 1 THEN ''Enabled'' ELSE ''Disabled'' END,
            CASE WHEN js.next_run_date > 0 THEN msdb.dbo.agent_datetime(js.next_run_date, js.next_run_time) END,
            ''OK'',
            NULL
        FROM msdb.dbo.sysjobs j
        LEFT JOIN msdb.dbo.sysjobschedules js
            ON js.job_id = j.job_id
        LEFT JOIN msdb.dbo.sysschedules s
            ON s.schedule_id = js.schedule_id
        WHERE j.name IN (''reporting-snapshot-sync-job'', ''reporting-sync-job'', ''reporting-data-cleanup-job'')
        ORDER BY j.name;';
END TRY
BEGIN CATCH
    INSERT INTO #AgentSchedule (DiagnosticStatus, Details)
    VALUES ('MSDB_QUERY_FAILED', ERROR_MESSAGE());
END CATCH;

SELECT
    JobName,
    JobEnabled,
    ScheduleName,
    ScheduleEnabled,
    NextRunAt,
    DiagnosticStatus,
    Details
FROM #AgentSchedule
ORDER BY JobName;

PRINT 'Recent SQL Agent reporting job history.';

IF OBJECT_ID('tempdb..#AgentHistory') IS NOT NULL DROP TABLE #AgentHistory;
CREATE TABLE #AgentHistory (
    JobName sysname NULL,
    StepId int NULL,
    StepName sysname NULL,
    RunStatus varchar(30) NULL,
    RunStart datetime NULL,
    RunDurationSeconds int NULL,
    Message nvarchar(4000) NULL,
    DiagnosticStatus varchar(40) NOT NULL,
    Details nvarchar(4000) NULL
);

BEGIN TRY
    EXEC sys.sp_executesql N'
        INSERT INTO #AgentHistory (
            JobName,
            StepId,
            StepName,
            RunStatus,
            RunStart,
            RunDurationSeconds,
            Message,
            DiagnosticStatus,
            Details
        )
        SELECT TOP (30)
            j.name,
            h.step_id,
            h.step_name,
            CASE h.run_status
                WHEN 0 THEN ''Failed''
                WHEN 1 THEN ''Succeeded''
                WHEN 2 THEN ''Retry''
                WHEN 3 THEN ''Canceled''
                WHEN 4 THEN ''In Progress''
                ELSE CONCAT(''Unknown '', h.run_status)
            END,
            CASE WHEN h.run_date > 0 THEN msdb.dbo.agent_datetime(h.run_date, h.run_time) END,
            (h.run_duration / 10000) * 3600
                + ((h.run_duration % 10000) / 100) * 60
                + (h.run_duration % 100),
            LEFT(h.message, 4000),
            ''OK'',
            NULL
        FROM msdb.dbo.sysjobs j
        INNER JOIN msdb.dbo.sysjobhistory h
            ON h.job_id = j.job_id
        WHERE j.name IN (''reporting-snapshot-sync-job'', ''reporting-sync-job'', ''reporting-data-cleanup-job'')
        ORDER BY h.instance_id DESC;';
END TRY
BEGIN CATCH
    INSERT INTO #AgentHistory (DiagnosticStatus, Details)
    VALUES ('MSDB_QUERY_FAILED', ERROR_MESSAGE());
END CATCH;

SELECT
    JobName,
    StepId,
    StepName,
    RunStatus,
    RunStart,
    RunDurationSeconds,
    Message,
    DiagnosticStatus,
    Details
FROM #AgentHistory
ORDER BY RunStart DESC, StepId;

PRINT 'Daily KPI sync diagnostic checks.';

SELECT
    'Inventory snapshots exist in Power BI default window' AS CheckName,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM #SnapshotHealth
            WHERE UsedBy = 'Inventory'
              AND ObjectStatus = 'OK'
              AND RowsInPowerBIDefaultWindow > 0
        ) THEN 'PASS'
        ELSE 'WARN'
    END AS Status,
    CONCAT('Default window starts ', CONVERT(varchar(10), @DefaultStartDate, 120), '. Inventory snapshot max date is ',
        COALESCE(CONVERT(varchar(10), (SELECT MAX(MaxSnapshotDate) FROM #SnapshotHealth WHERE UsedBy = 'Inventory'), 120), 'NULL'),
        '.') AS Details
UNION ALL
SELECT
    'Inbound snapshots exist in Power BI default window',
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM #SnapshotHealth
            WHERE UsedBy = 'Inbound'
              AND ObjectStatus = 'OK'
              AND RowsInPowerBIDefaultWindow > 0
        ) THEN 'PASS'
        ELSE 'WARN'
    END,
    CONCAT('Default window starts ', CONVERT(varchar(10), @DefaultStartDate, 120), '. Inbound snapshot max date is ',
        COALESCE(CONVERT(varchar(10), (SELECT MAX(MaxSnapshotDate) FROM #SnapshotHealth WHERE UsedBy = 'Inbound'), 120), 'NULL'),
        '.')
UNION ALL
SELECT
    'DynamicTableInsert completed recently',
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM dbo.DataSyncDetail
            WHERE TableName IS NULL
              AND JobName = 'DynamicTableInsert'
              AND IsStarted = 1
              AND IsCompleted = 1
              AND SyncEndTime >= DATEADD(hour, -4, GETDATE())
        ) THEN 'PASS'
        ELSE 'WARN'
    END,
    CONCAT('Latest DynamicTableInsert end time: ',
        COALESCE(CONVERT(varchar(19), (
            SELECT MAX(SyncEndTime)
            FROM dbo.DataSyncDetail
            WHERE TableName IS NULL
              AND JobName = 'DynamicTableInsert'
              AND IsCompleted = 1
        ), 120), 'NULL'),
        '.')
UNION ALL
SELECT
    'No open DynamicTableInsert row',
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM dbo.DataSyncDetail
            WHERE TableName IS NULL
              AND JobName = 'DynamicTableInsert'
              AND IsStarted = 1
              AND ISNULL(IsCompleted, 0) = 0
        ) THEN 'WARN'
        ELSE 'PASS'
    END,
    CONCAT('Open DynamicTableInsert rows: ',
        CONVERT(varchar(30), (
            SELECT COUNT_BIG(*)
            FROM dbo.DataSyncDetail
            WHERE TableName IS NULL
              AND JobName = 'DynamicTableInsert'
              AND IsStarted = 1
              AND ISNULL(IsCompleted, 0) = 0
        )),
        '.')
UNION ALL
SELECT
    'Live source has recent inventory/inbound rows',
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM #SourceHealth
            WHERE ObjectStatus = 'OK'
              AND RowsInPowerBIDefaultWindow > 0
        ) THEN 'PASS'
        ELSE 'WARN'
    END,
    CONCAT('Max live source date seen: ',
        COALESCE(CONVERT(varchar(19), (SELECT MAX(MaxSourceDate) FROM #SourceHealth WHERE ObjectStatus = 'OK'), 120), 'NULL'),
        '.')
UNION ALL
SELECT
    'ProcessDataDynamicCompletion checks the right job name',
    CASE
        WHEN OBJECT_DEFINITION(OBJECT_ID(N'dbo.ProcessDataDynamicCompletion')) LIKE '%DyanamicTableInsert%'
         AND OBJECT_DEFINITION(OBJECT_ID(N'dbo.ProcessDataDynamicCompletion')) NOT LIKE '%JobName = ''DynamicTableInsert''%'
            THEN 'WARN'
        ELSE 'PASS'
    END,
    'If this warns, the completion step likely cannot clear a stuck DynamicTableInsert row because it looks for DyanamicTableInsert.';
