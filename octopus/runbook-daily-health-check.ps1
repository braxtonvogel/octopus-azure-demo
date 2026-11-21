# Octopus runbook "Daily health check" (Azure Script step, Azure Demo account, az CLI logged in).
# By default it only READS Azure state (az containerapp list, az sql db list); it creates, changes, and deletes nothing, and
# it does NOT open the sites, so it does not wake any scale-to-zero app or serverless database. That is deliberate: a daily
# wake-up of a free-offer database can use a large share of its monthly free allowance (100,000 vCore seconds), and a
# database that runs out is paused until the next month.
# Optional, for manual runs only: set an Octopus variable WakeSites to True to also request each site (HTTP 200 and the Notes
# page). That wakes the apps and their databases, and an app applies any pending database migration at startup, like any visitor.
# Checks: every Container App provisioned and its latest revision ready; the required apps exist; the running image;
# the SQL database count on the server (the free-offer limit of 10 is per subscription, so this is only a lower bound).
# Any problem fails the step so it shows up red in Octopus.
# Windows PowerShell 5.1 on the worker: az queries stay free of parentheses and ! (it passes them to az.cmd unquoted).
$ErrorActionPreference = 'Stop'   # Doesn't stop on native commands: every az call checks $LASTEXITCODE.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$resourceGroup = 'rg-octopus-demo'
$sqlServer     = 'sql-braxtonvogel'
$requiredApps  = @('notes-app', 'notes-app-dev', 'notes-app-staging')
$maxFreeDbs    = 10
$warnAtDbs     = 8
$wakeSites     = ("$($OctopusParameters['WakeSites'])" -eq 'True')
$failures = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Assert-Az([string]$what) { if ($LASTEXITCODE -ne 0) { throw "$what failed (az exit $LASTEXITCODE)." } }

Write-Host "=== Daily health check $(Get-Date -Format 'yyyy-MM-dd HH:mm') (WakeSites: $wakeSites) ==="

# 1) Container Apps: every app in the group (shared Production, Dev, Staging, tenant apps, and any open PR apps).
$appsJson = az containerapp list --resource-group $resourceGroup --output json --only-show-errors
Assert-Az 'az containerapp list'
# Windows PowerShell 5.1 returns a JSON array from ConvertFrom-Json as ONE object, so unroll it or the counts are wrong.
$apps = @(ConvertFrom-Json ($appsJson -join "`n") | ForEach-Object { $_ })
if ($apps.Count -eq 0) { throw "No Container Apps found in $resourceGroup (wrong resource group, or no permission to list them)." }
Write-Host "Container Apps found: $($apps.Count)"
foreach ($need in $requiredApps) {
    if (-not ($apps | Where-Object { $_.name -eq $need })) { $failures.Add("Required app $need is missing") ; Write-Host "FAIL  $need is missing" }
}
foreach ($app in ($apps | Sort-Object name)) {
    $p       = $app.properties
    $fqdn    = $p.configuration.ingress.fqdn
    $image   = $p.template.containers[0].image
    $short   = if ($image) { ($image -split '/')[-1] } else { 'unknown' }
    $isPlaceholder = ($image -like '*aspnetapp*')
    $problems = New-Object System.Collections.Generic.List[string]
    if ($p.provisioningState -ne 'Succeeded') { $problems.Add("provisioning state is $($p.provisioningState)") }
    if ($p.latestRevisionName -ne $p.latestReadyRevisionName) { $problems.Add("latest revision $($p.latestRevisionName) is not ready (ready: $($p.latestReadyRevisionName))") }

    if ($wakeSites) {
        if ([string]::IsNullOrWhiteSpace($fqdn)) { $problems.Add('no ingress address') }
        else {
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $resp = Invoke-WebRequest -Uri "https://$fqdn/" -UseBasicParsing -TimeoutSec 120   # first request wakes app and DB
                $sw.Stop()
                if ($resp.StatusCode -ne 200) { $problems.Add("HTTP $($resp.StatusCode)") }
                elseif (-not $isPlaceholder -and $resp.Content -notmatch 'Notes') { $problems.Add('page has no Notes content') }
                else { Write-Host "      site answered in $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" }
            } catch {
                # PowerShell 5.1 throws on HTTP 4xx/5xx and on timeouts; the message says which.
                $problems.Add("request failed: $($_.Exception.Message)")
            }
        }
    }

    if ($problems.Count -gt 0) {
        foreach ($x in $problems) { $failures.Add("$($app.name): $x") }
        Write-Host "FAIL  $($app.name)  $short  $($problems -join '; ')"
    } else {
        $note = if ($isPlaceholder) { '  (still on the placeholder image)' } else { '' }
        if ($isPlaceholder) { $warnings.Add("$($app.name): running the placeholder image") }
        Write-Host "OK    $($app.name)  $short  revision $($p.latestRevisionName) ready$note"
    }
}

# 2) SQL databases on this server. The free-offer limit (10) is per SUBSCRIPTION, so this count is a lower bound.
$dbsJson = az sql db list --resource-group $resourceGroup --server $sqlServer --output json --only-show-errors
Assert-Az 'az sql db list'
$dbs = @(ConvertFrom-Json ($dbsJson -join "`n") | ForEach-Object { $_ } | Where-Object { $_.name -ne 'master' })
Write-Host "SQL databases on ${sqlServer}: $($dbs.Count) (free offer allows 10 per subscription)"
foreach ($db in ($dbs | Sort-Object name)) { Write-Host "      $($db.name)  status: $($db.status)" }
if ($dbs.Count -ge $maxFreeDbs) { $failures.Add("Database count $($dbs.Count) has reached the free-offer limit of $maxFreeDbs") }
elseif ($dbs.Count -ge $warnAtDbs) { $warnings.Add("Database count $($dbs.Count) is close to the free-offer limit of $maxFreeDbs") }

# 3) Summary.
foreach ($w in $warnings) { Write-Warning $w }
if ($failures.Count -gt 0) {
    Write-Host "=== $($failures.Count) problem(s) ==="
    foreach ($f in $failures) { Write-Host " - $f" }
    throw "Daily health check found $($failures.Count) problem(s); see the lines above."
}
Write-Host "=== All checks passed: $($apps.Count) apps healthy, $($dbs.Count) databases. ==="
