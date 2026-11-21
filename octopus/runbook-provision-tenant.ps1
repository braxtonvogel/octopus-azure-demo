# Octopus runbook "Provision tenant" (Azure Script step, octopus-deployer account, az CLI logged in).
# Run once per tenant in Production (a tenanted runbook run for e.g. "Tenant A"). If that tenant's app already exists
# this is a no-op: it never rotates the DB password or restarts a live tenant. (That re-run path is untested.)
# Creates: free-tier SQL DB notes-<TenantSlug>, contained user notes_tenant (random password), Container App
# notes-app-<TenantSlug> on a placeholder image. The project's normal deploy step then rolls in the real image
# (octopus/deploy-step.ps1 picks notes-app-<TenantSlug> for tenanted deployments).
# Same prerequisites and tradeoffs as runbook-provision.ps1: octopus-deployer is the SQL server's Entra admin, "Allow
# Azure services" is on the SQL firewall, and secrets passed on az command lines are visible in the throwaway worker's
# process list. The password, token, and connection string are never written to the log.
# Free tier only: serverless DB with the free offer (AutoPause when the free limit runs out), Container App scales to 0.
$ErrorActionPreference = 'Stop'   # Doesn't stop on native commands: every az call checks $LASTEXITCODE.

$resourceGroup = 'rg-octopus-demo'
$sqlServer     = 'sql-braxtonvogel'
$sqlFqdn       = "$sqlServer.database.windows.net"
$managedEnv    = 'env-octopus-demo'
$dbUser        = 'notes_tenant'
$maxTenantApps = 4
# Placeholder until the deploy step sets the real image. Must listen on 8080 (.NET 8+ aspnet images do).
$placeholder   = if ($OctopusParameters['PlaceholderImage']) { $OctopusParameters['PlaceholderImage'] } else { 'mcr.microsoft.com/dotnet/samples:aspnetapp' }

function Assert-Az([string]$what) { if ($LASTEXITCODE -ne 0) { throw "$what failed (az exit $LASTEXITCODE)." } }

# Guards: Production only, and only for a tenant with a valid slug that can't collide with PR environments.
if ($OctopusParameters['Octopus.Environment.Name'] -ne 'Production') {
    throw "Refusing to provision a tenant in '$($OctopusParameters['Octopus.Environment.Name'])': Production only."
}
if ([string]::IsNullOrWhiteSpace($OctopusParameters['Octopus.Deployment.Tenant.Id'])) {
    throw 'This runbook must be run for a tenant (choose a tenant when running it).'
}
$slug = $OctopusParameters['TenantSlug']
# Case-sensitive match and \z (not $) so 'Tenant-A' or a trailing newline can't slip through.
# Azure Container App names also forbid two dashes in a row ('--'), so reject that before any DB is created.
if ($slug -cnotmatch '^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?\z' -or $slug -match '--' -or $slug -like 'pr-*') {
    throw "Tenant '$($OctopusParameters['Octopus.Deployment.Tenant.Name'])' has an invalid TenantSlug '$slug' (lowercase letters, digits, single dashes; max 20; not pr-*)."
}
$appName = "notes-app-$slug"
$dbName  = "notes-$slug"
# Never target the fixed apps/databases (for example a slug of 'dev' or 'staging').
if (@('notes-app', 'notes-app-dev', 'notes-app-staging') -contains $appName -or @('notes-dev', 'notes-staging', 'notesdb') -contains $dbName) {
    throw "TenantSlug '$slug' would collide with an existing fixed app or database ($appName / $dbName)."
}
# TenantSlug must be unique per tenant (two tenants with one slug would share one app and database); not checkable here.
Write-Host "Provisioning tenant $($OctopusParameters['Octopus.Deployment.Tenant.Name']) -> app $appName, DB $dbName on $sqlServer ($resourceGroup)"

# 1) Cap: at most $maxTenantApps tenant apps, not counting this tenant's own app (so reruns are safe).
#    Tenant apps are every notes-app-* except the fixed ones and PR apps.
$fixedApps = @('notes-app', 'notes-app-dev', 'notes-app-staging')
$allApps = @(az containerapp list --resource-group $resourceGroup --query "[?starts_with(name, 'notes-app-')].name" --output tsv --only-show-errors)
Assert-Az 'az containerapp list'
$tenantApps = @($allApps | Where-Object { $_ -and $fixedApps -notcontains $_.Trim() -and -not $_.Trim().StartsWith('notes-app-pr-') })
$others = @($tenantApps | Where-Object { $_.Trim() -ne $appName })
if ($others.Count -ge $maxTenantApps) {
    throw "Tenant app cap reached: $($others.Count) other tenant apps exist ($($others -join ', ')). Remove one first."
}
if (@($tenantApps | Where-Object { $_.Trim() -eq $appName }).Count -gt 0) {
    # Already provisioned: do nothing, so a re-run can never rotate the DB password or restart a live tenant.
    $fqdn = az containerapp show --name $appName --resource-group $resourceGroup --query properties.configuration.ingress.fqdn --output tsv --only-show-errors
    Assert-Az 'az containerapp show'
    Write-Host "Tenant app $appName already exists; nothing to do. URL: https://$fqdn"
    exit 0
}

# 2) Free-tier serverless DB (skip if it exists). AutoPause when the monthly free limit runs out.
$dbFound = az sql db list --resource-group $resourceGroup --server $sqlServer --query "[?name=='$dbName'].name" --output tsv --only-show-errors
Assert-Az 'az sql db list'
if ($dbFound) {
    Write-Host "Database $dbName already exists; keeping it."
} else {
    # Two limits matter (both are per subscription; here they are counted per server, so this is a lower bound):
    #   - the free offer allows 10 free databases;
    #   - the subscription's vCore quota is 10 TOTAL max vCores. This once blocked a PR environment: five 2-vCore databases = 10.
    # New databases are created with 1 max vCore, so check there is room for one more.
    $dbsJson = az sql db list --resource-group $resourceGroup --server $sqlServer --output json --only-show-errors
    Assert-Az 'az sql db list (limits)'
    # Windows PowerShell 5.1 returns a JSON array from ConvertFrom-Json as ONE object, so unroll it.
    $allDbs = @(ConvertFrom-Json ($dbsJson -join "`n") | ForEach-Object { $_ } | Where-Object { $_.name -ne 'master' })
    $dbCount = $allDbs.Count
    $vcoresUsed = 0
    foreach ($d in $allDbs) { $vcoresUsed += [int]$d.sku.capacity }
    if ($dbCount -ge 10) { throw "Refusing to create ${dbName}: $dbCount databases already exist on $sqlServer (free offer allows 10 per subscription)." }
    # Keep 2 vCores free for PR environments (the PR script allows 2 PR apps, 1 vCore each) so tenants can't starve them.
    $prReserve = 2
    if ($vcoresUsed + 1 -gt 10 - $prReserve) { throw "Refusing to create ${dbName}: databases on $sqlServer already use $vcoresUsed of the subscription's 10 vCores, and $prReserve are kept free for PR environments." }
    az sql db create --resource-group $resourceGroup --server $sqlServer --name $dbName `
        --edition GeneralPurpose --family Gen5 --capacity 1 --compute-model Serverless `
        --use-free-limit --free-limit-exhaustion-behavior AutoPause --output none --only-show-errors
    Assert-Az 'az sql db create'
    Write-Host "Created database $dbName (free offer, AutoPause)."
}

# 3) Contained user with a fresh random password, created over an Entra token (no admin password involved).
$alphabet = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
do {
    $chars = foreach ($i in 1..32) {
        $b = [byte[]]::new(1)
        do { $rng.GetBytes($b) } while ($b[0] -ge (256 - (256 % $alphabet.Length)))   # no modulo bias
        $alphabet[$b[0] % $alphabet.Length]
    }
    $password = -join $chars
} until ($password -cmatch '[A-Z]' -and $password -cmatch '[a-z]' -and $password -match '[0-9]')
$rng.Dispose()
# CREATE/ALTER USER can't take parameters, so the values are validated to a safe alphabet before use.
if ($password -notmatch '^[A-Za-z0-9]{32}$' -or $dbUser -notmatch '^[a-z_]+$' -or $dbName -notmatch '^[a-z0-9-]+$') {
    throw 'Generated SQL identifiers or password failed validation.'
}
# The password is never printed or saved as an output variable; it only goes to SQL and the app's secret.

$token = az account get-access-token --resource https://database.windows.net/ --query accessToken --output tsv --only-show-errors
Assert-Az 'az account get-access-token'
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Empty Entra token for Azure SQL.' }

# System.Data.SqlClient supports .AccessToken in both editions: Windows PowerShell 5.1 gets it from .NET Framework
# (System.Data.dll), and pwsh 7 ships System.Data.SqlClient.dll. Microsoft.Data.SqlClient is used if already loaded.
$sqlType = 'System.Data.SqlClient.SqlConnection' -as [type]
if (-not $sqlType) { $sqlType = 'Microsoft.Data.SqlClient.SqlConnection' -as [type] }
if (-not $sqlType) { throw 'No SqlClient available on this worker (need System.Data.SqlClient or Microsoft.Data.SqlClient).' }

$conn = $sqlType::new("Server=tcp:$sqlFqdn,1433;Database=$dbName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;")
$conn.AccessToken = $token
try {
    # A new serverless DB can be resuming; retry the open a few times.
    for ($try = 1; ; $try++) {
        try { $conn.Open(); break } catch { if ($try -ge 5) { throw "Couldn't connect to $dbName as Entra admin: $($_.Exception.Message)" }; Start-Sleep -Seconds 15 }
    }
    $sql = @"
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$dbUser')
    ALTER USER [$dbUser] WITH PASSWORD = N'$password';
ELSE
    CREATE USER [$dbUser] WITH PASSWORD = N'$password';
IF IS_ROLEMEMBER(N'db_datareader', N'$dbUser') = 0 ALTER ROLE db_datareader ADD MEMBER [$dbUser];
IF IS_ROLEMEMBER(N'db_datawriter', N'$dbUser') = 0 ALTER ROLE db_datawriter ADD MEMBER [$dbUser];
IF IS_ROLEMEMBER(N'db_ddladmin',  N'$dbUser') = 0 ALTER ROLE db_ddladmin  ADD MEMBER [$dbUser];
"@
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    [void]$cmd.ExecuteNonQuery()
    Write-Host "Contained user $dbUser is set on $dbName (db_datareader, db_datawriter, db_ddladmin)."
} finally {
    $conn.Dispose()
    $token = $null; $sql = $null
}

$connString = "Server=tcp:$sqlFqdn,1433;Initial Catalog=$dbName;User ID=$dbUser;Password=$password;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"

# 4) Container App. GHCR pulls need the package to be public, or registry creds (GhcrUsername + Sensitive GhcrToken).
az containerapp create --name $appName --resource-group $resourceGroup --environment $managedEnv `
    --image $placeholder --cpu 0.25 --memory 0.5Gi --min-replicas 0 --max-replicas 1 `
    --ingress external --target-port 8080 `
    --secrets "db-conn=$connString" --env-vars "ConnectionStrings__Default=secretref:db-conn" `
    --output none --only-show-errors
Assert-Az 'az containerapp create'
Write-Host "Created Container App $appName on placeholder $placeholder."
$connString = $null; $password = $null

if ($OctopusParameters['GhcrUsername'] -and $OctopusParameters['GhcrToken']) {
    az containerapp registry set --name $appName --resource-group $resourceGroup --server ghcr.io `
        --username $OctopusParameters['GhcrUsername'] --password $OctopusParameters['GhcrToken'] --output none --only-show-errors
    Assert-Az 'az containerapp registry set'
}

# 5) Report the URL (deploy to this tenant next to roll in the real image).
$fqdn = az containerapp show --name $appName --resource-group $resourceGroup --query properties.configuration.ingress.fqdn --output tsv --only-show-errors
Assert-Az 'az containerapp show'
if ([string]::IsNullOrWhiteSpace($fqdn)) { throw "Container App $appName has no ingress FQDN." }
Write-Host "Provisioned tenant $slug. URL: https://$fqdn"
