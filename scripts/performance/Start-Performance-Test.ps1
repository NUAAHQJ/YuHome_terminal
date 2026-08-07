[CmdletBinding()]
param(
    [string]$Target = ''
)

$collector = Join-Path $PSScriptRoot 'Collect-Performance.ps1'
$summary = Join-Path $PSScriptRoot 'Summarize-Performance.ps1'

try {
    & $collector -Target $Target
} finally {
    Write-Host ''
    Write-Host 'Calculating the latest completed traces...' -ForegroundColor Cyan
    try {
        & $summary
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }
    Write-Host ''
    Read-Host 'Press Enter to close'
}
