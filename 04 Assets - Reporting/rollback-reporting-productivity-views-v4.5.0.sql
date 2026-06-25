USE [KFX_REPORTING]
GO

/*
    Rollback for patch-reporting-productivity-views-v4.5.0.sql.

    This restores the original shipped pattern: report-facing productivity views
    select from the helper tables rebuilt by dbo.CreateKPITables.
*/

CREATE OR ALTER VIEW [dbo].[OrdersCompletedPerUser]
AS
SELECT * FROM dbo.OrdersCompletedPerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[OrdersCompletedPerPort]
AS
SELECT * FROM dbo.OrdersCompletedPerPort_Table;
GO

CREATE OR ALTER VIEW [dbo].[BinPresentationsCompletedPerUser]
AS
SELECT * FROM dbo.BinPresentationsCompletedPerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[BinPresentationsCompletedPerPort]
AS
SELECT * FROM dbo.BinPresentationsCompletedPerPort_Table;
GO

CREATE OR ALTER VIEW [dbo].[LinesCompletedPerUser]
AS
SELECT * FROM dbo.LinesCompletedPerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[LinesCompletedPerPort]
AS
SELECT * FROM dbo.LinesCompletedPerPort_Table;
GO

CREATE OR ALTER VIEW [dbo].[UnitsCompletedPerUser]
AS
SELECT * FROM dbo.UnitsCompletedPerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[UnitsCompletedPerPort]
AS
SELECT * FROM dbo.UnitsCompletedPerPort_Table;
GO

CREATE OR ALTER VIEW [dbo].[OrdersPerHourPerUser]
AS
SELECT * FROM dbo.OrdersPerHourPerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[OrdersPerHourPerPort]
AS
SELECT * FROM dbo.OrdersPerHourPerPort_Table;
GO

CREATE OR ALTER VIEW [dbo].[BinsPerHourPerUser]
AS
SELECT * FROM dbo.BinsPerHourPerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[BinsPerHourPerPort]
AS
SELECT * FROM dbo.BinsPerHourPerPort_Table;
GO

CREATE OR ALTER VIEW [dbo].[LinesperHourPerUser]
AS
SELECT * FROM dbo.LinesperHourPerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[LinesperHourPerPort]
AS
SELECT * FROM dbo.LinesperHourPerPort_Table;
GO

CREATE OR ALTER VIEW [dbo].[UnitsPerHourPerUser]
AS
SELECT * FROM dbo.UnitsPerHourPerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[UnitsPerHourPerPort]
AS
SELECT * FROM dbo.UnitsPerHourPerPort_Table;
GO

CREATE OR ALTER VIEW [dbo].[AverageHandlingTimePerUser]
AS
SELECT * FROM dbo.AverageHandlingTimePerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[AverageHandlingTimePerPort]
AS
SELECT * FROM dbo.AverageHandlingTimePerPort_Table;
GO

CREATE OR ALTER VIEW [dbo].[MachineWaitTimePerUser]
AS
SELECT * FROM dbo.MachineWaitTimePerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[MachineWaitTimePerPort]
AS
SELECT * FROM dbo.MachineWaitTimePerPort_Table;
GO

CREATE OR ALTER VIEW [dbo].[TotalLoggedTimePerUser]
AS
SELECT * FROM dbo.TotalLoggedTimePerUser_Table;
GO

CREATE OR ALTER VIEW [dbo].[TotalLoggedTimePerPort]
AS
SELECT * FROM dbo.TotalLoggedTimePerPort_Table;
GO
