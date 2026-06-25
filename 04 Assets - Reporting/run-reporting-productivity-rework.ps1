[CmdletBinding()]
param(
    [string]$Server = "vm-as-dbsql0011",
    [string]$Database = "KFX_REPORTING",
    [switch]$ApplyPatch,
    [switch]$UseSqlLogin,
    [string]$SqlUser,
    [securestring]$SqlPassword
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Join-Path $scriptDir "validation-output"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Get-PlainTextPassword {
    param([securestring]$Password)

    if (-not $Password) {
        return $null
    }

    $credential = [System.Net.NetworkCredential]::new("", $Password)
    return $credential.Password
}

function Get-SqlcmdBaseArgs {
    $args = @("-S", $Server, "-d", $Database, "-b", "-W", "-C")

    if ($UseSqlLogin) {
        if (-not $SqlUser) {
            throw "SqlUser is required when -UseSqlLogin is supplied."
        }

        $password = $SqlPassword

        if (-not $password) {
            $password = Read-Host "SQL password for $SqlUser" -AsSecureString
        }

        $args += @("-U", $SqlUser, "-P", (Get-PlainTextPassword $password))
    }
    else {
        $args += "-E"
    }

    return $args
}

function Invoke-SqlFile {
    param(
        [string]$Name,
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Missing SQL script: $Path"
    }

    $logPath = Join-Path $logDir "$timestamp-$Name.log"
    Write-Host "Running $Name ..."

    $args = Get-SqlcmdBaseArgs
    $args += @("-i", $Path, "-o", $logPath)

    & sqlcmd @args

    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed. See log: $logPath"
    }

    Write-Host "Saved log: $logPath"
    return $logPath
}

function Get-GateValueFromLog {
    param(
        [string]$LogPath,
        [string]$GateColumn
    )

    $lines = Get-Content -Path $LogPath

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match [regex]::Escape($GateColumn)) {
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                $line = $lines[$j].Trim()

                if (-not $line) {
                    continue
                }

                if ($line -match "^[-\s]+$") {
                    continue
                }

                return ($line -split "\s+")[0]
            }
        }
    }

    throw "Could not find $GateColumn in log: $LogPath"
}

$setupScript = Join-Path $scriptDir "create-reporting-productivity-work-events-v4.5.0.sql"
$validationScript = Join-Path $scriptDir "validate-reporting-productivity-v4.5.0.sql"
$patchScript = Join-Path $scriptDir "patch-reporting-productivity-views-v4.5.0.sql"
$postPatchValidationScript = Join-Path $scriptDir "validate-reporting-productivity-powerbi-patch-v4.5.0.sql"

Write-Host "Target SQL Server: $Server"
Write-Host "Target database:   $Database"
Write-Host "Apply patch:       $ApplyPatch"
Write-Host ""

Invoke-SqlFile -Name "01-create-work-events" -Path $setupScript | Out-Null
$validationLog = Invoke-SqlFile -Name "02-validate-work-events" -Path $validationScript
$promotionGate = Get-GateValueFromLog -LogPath $validationLog -GateColumn "DropInPatchPromotionGate"

Write-Host "DropInPatchPromotionGate: $promotionGate"

if ($promotionGate -ne "PASS") {
    Write-Host ""
    Write-Host "Stopping before patch. Review the validation log and fix the reported issue first."
    exit 1
}

if (-not $ApplyPatch) {
    Write-Host ""
    Write-Host "Setup and validation passed. Re-run with -ApplyPatch when you are ready to repoint the PBIX helper views."
    exit 0
}

Invoke-SqlFile -Name "03-patch-powerbi-helper-views" -Path $patchScript | Out-Null
$postPatchLog = Invoke-SqlFile -Name "04-validate-powerbi-patch" -Path $postPatchValidationScript
$powerBiGate = Get-GateValueFromLog -LogPath $postPatchLog -GateColumn "PowerBIPatchValidationGate"

Write-Host "PowerBIPatchValidationGate: $powerBiGate"

if ($powerBiGate -ne "PASS") {
    Write-Host ""
    Write-Host "Patch validation needs review. If Power BI refresh looks wrong, run rollback-reporting-productivity-views-v4.5.0.sql."
    exit 1
}

Write-Host ""
Write-Host "SQL productivity rework validated. Refresh Power BI Desktop and compare the Productivity by User / Port page."
