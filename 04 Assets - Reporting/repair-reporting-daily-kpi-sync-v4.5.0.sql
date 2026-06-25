USE [KFX_REPORTING];
GO

SET NOCOUNT ON;

/*
    Daily KPI snapshot sync repair.

    Root cause this repairs:
      reporting-snapshot-sync-job calls dbo.ProcessDynamicData, but that proc
      exits with "ALREADY RUNNING" when a DynamicTableInsert row is left open.
      The follow-up completion proc was checking the misspelled job name
      DyanamicTableInsert, so it could not clear the stuck DynamicTableInsert row.

    What this does:
      1. Corrects dbo.ProcessDataDynamicCompletion to check DynamicTableInsert.
      2. Executes dbo.ProcessDataDynamicCompletion once to clear the stuck row and
         let dbo.ProcessDynamicData load a fresh snapshot.
      3. Prints a PASS/WARN gate based on current snapshot freshness.
*/

SELECT
    'BeforeRepair' AS Phase,
    COUNT_BIG(*) AS OpenDynamicTableInsertRows,
    MIN(SyncStartTime) AS OldestOpenStartTime,
    MAX(SyncStartTime) AS NewestOpenStartTime
FROM dbo.DataSyncDetail
WHERE TableName IS NULL
  AND JobName = 'DynamicTableInsert'
  AND IsStarted = 1
  AND ISNULL(IsCompleted, 0) = 0;
GO

ALTER PROC [dbo].[ProcessDataDynamicCompletion]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunningId AS bigint;

    IF EXISTS (
        SELECT TOP (1) Id
        FROM dbo.DataSyncDetail
        WHERE TableName IS NULL
          AND IsStarted = 1
          AND IsCompleted = 0
          AND JobName = 'DynamicTableInsert'
        ORDER BY Id DESC
    )
    BEGIN
        PRINT 'Completing an open DynamicTableInsert row, then starting a fresh snapshot load.';

        SELECT TOP (1) @RunningId = Id
        FROM dbo.DataSyncDetail
        WHERE TableName IS NULL
          AND IsStarted = 1
          AND IsCompleted = 0
          AND JobName = 'DynamicTableInsert'
        ORDER BY Id DESC;

        UPDATE dbo.DataSyncDetail
        SET IsCompleted = 1,
            SyncEndTime = GETDATE()
        WHERE Id = @RunningId;

        EXEC dbo.ProcessDynamicData;
    END
END;
GO

PRINT 'Executing repaired completion procedure.';
EXEC dbo.ProcessDataDynamicCompletion;
GO

DECLARE @Today date = CAST(GETDATE() AS date);
DECLARE @OpenRows bigint;
DECLARE @LatestDynamicTableInsertEnd datetime;
DECLARE @InventoryMaxSnapshotDate date;
DECLARE @InboundMaxSnapshotDate date;

SELECT @OpenRows = COUNT_BIG(*)
FROM dbo.DataSyncDetail
WHERE TableName IS NULL
  AND JobName = 'DynamicTableInsert'
  AND IsStarted = 1
  AND ISNULL(IsCompleted, 0) = 0;

SELECT @LatestDynamicTableInsertEnd = MAX(SyncEndTime)
FROM dbo.DataSyncDetail
WHERE TableName IS NULL
  AND JobName = 'DynamicTableInsert'
  AND IsStarted = 1
  AND IsCompleted = 1;

SELECT @InventoryMaxSnapshotDate = MAX(MaxSnapshotDate)
FROM (
    SELECT MAX(CAST(Snapshot_Timestamp AS date)) AS MaxSnapshotDate
    FROM dbo.Inventory_Snapshot
    UNION ALL
    SELECT MAX(CAST(Snapshot_Timestamp AS date))
    FROM dbo.Containers_Snapshot
) inventory_snapshots;

SELECT @InboundMaxSnapshotDate = MAX(MaxSnapshotDate)
FROM (
    SELECT MAX(CAST(Snapshot_Timestamp AS date)) AS MaxSnapshotDate
    FROM dbo.PutAwayContainers_Snapshot
    UNION ALL
    SELECT MAX(CAST(Snapshot_Timestamp AS date))
    FROM dbo.PutAwayContainerLineItems_Snapshot
    UNION ALL
    SELECT MAX(CAST(Snapshot_Timestamp AS date))
    FROM dbo.InventoryTasks_PutAway_Snapshot
    UNION ALL
    SELECT MAX(CAST(Snapshot_Timestamp AS date))
    FROM dbo.InventoryTasks_Snapshot
) inbound_snapshots;

SELECT
    'AfterRepair' AS Phase,
    @OpenRows AS OpenDynamicTableInsertRows,
    @LatestDynamicTableInsertEnd AS LatestDynamicTableInsertEnd,
    @InventoryMaxSnapshotDate AS InventoryMaxSnapshotDate,
    @InboundMaxSnapshotDate AS InboundMaxSnapshotDate;

SELECT
    'DailyKpiSyncRepairGate' AS CheckName,
    CASE
        WHEN @OpenRows = 0
         AND CAST(@LatestDynamicTableInsertEnd AS date) = @Today
         AND @InventoryMaxSnapshotDate = @Today
         AND @InboundMaxSnapshotDate = @Today
            THEN 'PASS'
        ELSE 'WARN'
    END AS Status,
    CONCAT(
        'OpenRows=', @OpenRows,
        '; LatestDynamicTableInsertEnd=', COALESCE(CONVERT(varchar(19), @LatestDynamicTableInsertEnd, 120), 'NULL'),
        '; InventoryMaxSnapshotDate=', COALESCE(CONVERT(varchar(10), @InventoryMaxSnapshotDate, 120), 'NULL'),
        '; InboundMaxSnapshotDate=', COALESCE(CONVERT(varchar(10), @InboundMaxSnapshotDate, 120), 'NULL')
    ) AS Details;
