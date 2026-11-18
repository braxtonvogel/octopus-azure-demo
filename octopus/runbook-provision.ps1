# Octopus runbook "Provision PR environment" (Azure Script step, octopus-deployer account, az CLI logged in).
# Runs automatically before the first deployment to an ephemeral environment such as pr-451.
# Creates: free-tier SQL DB notes-<env>, contained user notes_pr (random password), Container App notes-app-<env>
# on a placeholder image. The project's normal deploy step then rolls in the PR image.
# Needs: octopus-deployer set as the SQL server's Microsoft Entra admin, and "Allow Azure services" on the
# SQL server firewall so the dynamic worker and the Container App can reach it.
# Secrets passed on az command lines are visible in the worker's process list; acceptable on a
# throwaway dynamic worker. The password, token, and connection string are never written to the log.
$ErrorActionPreference = 'Stop'   # Doesn't stop on native commands: every az call checks $LASTEXITCODE.

$resourceGroup = 'rg-octopus-demo'
$sqlServer     = 'sql-braxtonvogel'
$sqlFqdn       = "$sqlServer.database.windows.net"
$managedEnv    = 'env-octopus-demo'
$dbUser        = 'notes_pr'
$maxPrApps     = 2
# Placeholder until the deploy step sets the PR image. Must listen on 8080 (.NET 8+ aspnet images do).
$placeholder   = if ($OctopusParameters['PlaceholderImage']) { $OctopusParameters['PlaceholderImage'] } else { 'mcr.microsoft.com/dotnet/samples:aspnetapp' }

function Get-SafeEnvName([string]$name) {
    # Lowercase [a-z0-9-], no doubled/edge dashes, <= 22 chars so "notes-app-" + env fits ACA's 32-char limit.
    $s = ($name.ToLowerInvariant() -replace '[^a-z0-9-]', '-' -replace '-{2,}', '-').Trim('-')
    if ($s.Length -gt 22) { $s = $s.Substring(0, 22).TrimEnd('-') }
    return $s
}
function Assert-Az([string]$what) { if ($LASTEXITCODE -ne 0) { throw "$what failed (az exit $LASTEXITCODE)." } }

$envName = Get-SafeEnvName $OctopusParameters['Octopus.Environment.Name']
if ($envName -notmatch '^pr-[a-z0-9-]*[a-z0-9]$') {
    throw "Environment '$($OctopusParameters['Octopus.Environment.Name'])' isn't a PR environment (pr-N); refusing to provision."
}
$appName = "notes-app-$envName"
$dbName  = "notes-$envName"
foreach ($pair in @(@('AppName', $appName), @('DbName', $dbName), @('ResourceGroup', $resourceGroup))) {
    $v = $OctopusParameters[$pair[0]]
    if ($v -and $v -ne $pair[1]) { throw "Octopus variable $($pair[0]) is '$v' but this runbook targets '$($pair[1])'; fix the variable scoping." }
}
Write-Host "Provisioning $envName -> app $appName, DB $dbName on $sqlServer ($resourceGroup)"

# 1) Cap: at most 2 PR apps, not counting this env's own app (so reruns are safe).
$prApps = @(az containerapp list --resource-group $resourceGroup --query "[?starts_with(name, 'notes-app-pr-')].name" --output tsv --only-show-errors)
Assert-Az 'az containerapp list'
$others = @($prApps | Where-Object { $_ -and $_.Trim() -ne $appName })
if ($others.Count -ge $maxPrApps) {
    throw "PR environment cap reached: $($others.Count) other PR apps exist ($($others -join ', ')). Close a PR or deprovision one first."
}
$appExists = @($prApps | Where-Object { $_ -and $_.Trim() -eq $appName }).Count -gt 0

# 2) Free-tier serverless DB (skip if it exists). AutoPause when the monthly free limit runs out.
$dbFound = az sql db list --resource-group $resourceGroup --server $sqlServer --query "[?name=='$dbName'].name" --output tsv --only-show-errors
Assert-Az 'az sql db list'
if ($dbFound) {
    Write-Host "Database $dbName already exists; keeping it."
} else {
    az sql db create --resource-group $resourceGroup --server $sqlServer --name $dbName `
        --edition GeneralPurpose --family Gen5 --capacity 2 --compute-model Serverless `
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
if (Get-Command Set-OctopusVariable -ErrorAction SilentlyContinue) {
    Set-OctopusVariable -name 'DbUserPassword' -value $password -sensitive   # registers it for log masking
}

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
if ($appExists) {
    Write-Host "Container App $appName already exists; rotating its db-conn secret."
    az containerapp secret set --name $appName --resource-group $resourceGroup --secrets "db-conn=$connString" --output none --only-show-errors
    Assert-Az 'az containerapp secret set'
    # Running replicas keep the old password until restarted.
    $rev = az containerapp show --name $appName --resource-group $resourceGroup --query properties.latestRevisionName --output tsv --only-show-errors
    Assert-Az 'az containerapp show'
    if ($rev) {
        az containerapp revision restart --name $appName --resource-group $resourceGroup --revision $rev --output none --only-show-errors
        Assert-Az 'az containerapp revision restart'
    }
} else {
    az containerapp create --name $appName --resource-group $resourceGroup --environment $managedEnv `
        --image $placeholder --cpu 0.25 --memory 0.5Gi --min-replicas 0 --max-replicas 1 `
        --ingress external --target-port 8080 `
        --secrets "db-conn=$connString" --env-vars "ConnectionStrings__Default=secretref:db-conn" `
        --output none --only-show-errors
    Assert-Az 'az containerapp create'
    Write-Host "Created Container App $appName on placeholder $placeholder."
}
$connString = $null; $password = $null

if ($OctopusParameters['GhcrUsername'] -and $OctopusParameters['GhcrToken']) {
    az containerapp registry set --name $appName --resource-group $resourceGroup --server ghcr.io `
        --username $OctopusParameters['GhcrUsername'] --password $OctopusParameters['GhcrToken'] --output none --only-show-errors
    Assert-Az 'az containerapp registry set'
}

# 5) Show the URL on the Ephemeral Environments page.
$fqdn = az containerapp show --name $appName --resource-group $resourceGroup --query properties.configuration.ingress.fqdn --output tsv --only-show-errors
Assert-Az 'az containerapp show'
if ([string]::IsNullOrWhiteSpace($fqdn)) { throw "Container App $appName has no ingress FQDN." }
if (Get-Command Set-EnvironmentUrl -ErrorAction SilentlyContinue) {
    Set-EnvironmentUrl -Key 'App' -Url "https://$fqdn"
} else {
    Write-Warning 'Set-EnvironmentUrl is not available on this Octopus version; URL not registered.'
}
Write-Host "Provisioned $envName. URL: https://$fqdn"
