# Octopus runbook "Deprovision PR environment" (Azure Script step, octopus-deployer account, az CLI logged in).
# Runs when an ephemeral environment such as pr-451 is deprovisioned (PR closed, or 7 days inactive).
# Deletes Container App notes-app-<env> and SQL DB notes-<env>. Missing resources count as success.
$ErrorActionPreference = 'Stop'   # Doesn't stop on native commands: every az call checks $LASTEXITCODE.

$resourceGroup = 'rg-octopus-demo'
$sqlServer     = 'sql-braxtonvogel'

function Get-SafeEnvName([string]$name) {
    # Same rule as runbook-provision.ps1: lowercase [a-z0-9-], no doubled/edge dashes, <= 22 chars.
    $s = ($name.ToLowerInvariant() -replace '[^a-z0-9-]', '-' -replace '-{2,}', '-').Trim('-')
    if ($s.Length -gt 22) { $s = $s.Substring(0, 22).TrimEnd('-') }
    return $s
}
function Assert-Az([string]$what) { if ($LASTEXITCODE -ne 0) { throw "$what failed (az exit $LASTEXITCODE)." } }

$envName = Get-SafeEnvName $OctopusParameters['Octopus.Environment.Name']
$appName = "notes-app-$envName"
$dbName  = "notes-$envName"
# Safety guard: this runbook can only ever delete PR resources, never Dev/Staging/Prod.
if ($envName -notmatch '^pr-[a-z0-9-]*[a-z0-9]$' -or -not $appName.StartsWith('notes-app-pr-') -or -not $dbName.StartsWith('notes-pr-')) {
    throw "Refusing to deprovision '$($OctopusParameters['Octopus.Environment.Name'])': only pr-N environments (notes-app-pr-*, notes-pr-*) can be deleted."
}
Write-Host "Deprovisioning $envName -> app $appName, DB $dbName ($resourceGroup)"

$app = az containerapp list --resource-group $resourceGroup --query "[?name=='$appName'].name" --output tsv --only-show-errors
Assert-Az 'az containerapp list'
if ($app) {
    az containerapp delete --name $appName --resource-group $resourceGroup --yes --output none --only-show-errors
    Assert-Az 'az containerapp delete'
    Write-Host "Deleted Container App $appName."
} else {
    Write-Host "Container App $appName not found; nothing to delete."
}

$db = az sql db list --resource-group $resourceGroup --server $sqlServer --query "[?name=='$dbName'].name" --output tsv --only-show-errors
Assert-Az 'az sql db list'
if ($db) {
    az sql db delete --name $dbName --resource-group $resourceGroup --server $sqlServer --yes --output none --only-show-errors
    Assert-Az 'az sql db delete'
    Write-Host "Deleted database $dbName."
} else {
    Write-Host "Database $dbName not found; nothing to delete."
}
Write-Host "Deprovisioned $envName."
