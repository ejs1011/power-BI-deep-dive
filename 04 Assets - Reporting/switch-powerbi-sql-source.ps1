[CmdletBinding()]
param(
    [string]$OldServer = "10.0.26.70",
    [string]$NewServer = "vm-as-dbsql0011",
    [string]$Database = "KFX_REPORTING"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$semanticModelTables = Join-Path $scriptDir "Kardex-v4.5.0_out.SemanticModel\definition\tables"

if (-not (Test-Path $semanticModelTables)) {
    throw "Could not find semantic model tables folder: $semanticModelTables"
}

$powerBiProcesses = Get-Process -Name PBIDesktop -ErrorAction SilentlyContinue
if ($powerBiProcesses) {
    throw "Power BI Desktop is currently running. Close it before changing PBIP source files."
}

$oldExpression = "Sql.Database(`"$OldServer`", `"$Database`")"
$newExpression = "Sql.Database(`"$NewServer`", `"$Database`")"
$changedFiles = New-Object System.Collections.Generic.List[string]

Get-ChildItem -Path $semanticModelTables -Filter *.tmdl | ForEach-Object {
    $text = Get-Content -LiteralPath $_.FullName -Raw

    if ($text.Contains($oldExpression)) {
        $updated = $text.Replace($oldExpression, $newExpression)
        Set-Content -LiteralPath $_.FullName -Value $updated -NoNewline
        $changedFiles.Add($_.FullName)
    }
}

[pscustomobject]@{
    OldServer = $OldServer
    NewServer = $NewServer
    Database = $Database
    ChangedFiles = $changedFiles.Count
}

if ($changedFiles.Count -gt 0) {
    Write-Host ""
    Write-Host "Updated files:"
    $changedFiles | ForEach-Object { Write-Host " - $_" }
}
