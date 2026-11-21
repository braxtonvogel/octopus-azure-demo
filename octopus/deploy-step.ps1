# Octopus "Notes App" Azure Script step (Azure account set on the step; runs with az CLI logged in).
# One script for every environment: all per-env values come from scoped Octopus variables.
# No Sensitive variables are used: each Container App holds its own DB connection as secret 'db-conn'.
# The one value Octopus supplies at deploy time is the feature flag client identifier, a built-in variable (not
# Sensitive, so Octopus won't mask it). It is stored as Container App secret 'ff-client-id' and never echoed, but it
# does appear on the az command line, the same tradeoff runbook-provision.ps1 documents (fine on a throwaway worker).
# Caveat: --set-env-vars only merges, so a later deploy without an identifier leaves the earlier env var in place.
$ErrorActionPreference = 'Stop'

$appName       = $OctopusParameters['AppName']
$resourceGroup = $OctopusParameters['ResourceGroup']
# Version of the referenced package "notes-image" (GHCR Docker feed) chosen when the release was created.
$version       = $OctopusParameters['Octopus.Action.Package[notes-image].PackageVersion']

foreach ($pair in @(@('AppName', $appName), @('ResourceGroup', $resourceGroup),
                    @('notes-image version', $version))) {
    if ([string]::IsNullOrWhiteSpace($pair[1])) { throw "Missing value: $($pair[0]) (check variable scoping for $($OctopusParameters['Octopus.Environment.Name']))." }
}
# Main channel: only pinned 1.0.N builds from main. PR Environments channel: also 1.0.0-pr.<PR>.<run> images,
# and only onto notes-app-pr-* apps, so a PR image can never reach Dev, Staging, or Prod.
$channel     = $OctopusParameters['Octopus.Release.Channel.Name']
$isPrChannel = $channel -eq 'PR Environments'
if ($version -match '^1\.0\.\d+$') {
    # pinned main build: allowed in every channel
} elseif ($isPrChannel -and $version -match '^1\.0\.0-pr\.\d+\.\d+\.\d+$') {
    if ($appName -notlike 'notes-app-pr-*') { throw "PR image $version can only deploy to a notes-app-pr-* app, not '$appName'." }
} else {
    throw "notes-image version '$version' isn't allowed in channel '$channel' (main: 1.0.N; PR Environments: 1.0.N or 1.0.0-pr.N.R; never 'latest')."
}

$image = "ghcr.io/braxtonvogel/octopus-azure-demo:$version"
Write-Host "Deploying $image to $appName in $resourceGroup ($($OctopusParameters['Octopus.Environment.Name']))"

# 1) Feature flags: Octopus documents a built-in client identifier variable (per project + environment, and
#    tenant when the deployment is for one). Its exact name is NOT yet confirmed in a real deployment log here,
#    so both known names are tried: FeatureFlags first, then the older FeatureToggles. If neither resolves, the
#    warning below fires and every flag stays off. Keep it in a Container App secret and never print it.
$flagClientId = $OctopusParameters['Octopus.FeatureFlags.ClientIdentifier']
if ([string]::IsNullOrWhiteSpace($flagClientId)) { $flagClientId = $OctopusParameters['Octopus.FeatureToggles.ClientIdentifier'] }
$envVars = @('ConnectionStrings__Default=secretref:db-conn')
if (-not [string]::IsNullOrWhiteSpace($flagClientId)) {
    az containerapp secret set --name $appName --resource-group $resourceGroup `
        --secrets "ff-client-id=$flagClientId" --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        # Flags are optional: never fail a deploy over them. The app just runs with its flag defaults (off).
        Write-Warning "Couldn't store the feature flag client identifier (az exit $LASTEXITCODE); deploying without it."
    } else {
        $envVars += 'Octopus__FeatureFlags__ClientIdentifier=secretref:ff-client-id'
        Write-Host 'Feature flag client identifier set for this deployment.'
    }
} else {
    Write-Warning 'No Octopus feature flag client identifier for this deployment; all flags will use their defaults (off).'
}
$flagClientId = $null

# 2) Roll a new revision on the pinned image, wiring the env vars to their secrets.
az containerapp update --name $appName --resource-group $resourceGroup `
    --image $image `
    --set-env-vars $envVars --output none --only-show-errors
if ($LASTEXITCODE -ne 0) { throw "az containerapp update failed (exit $LASTEXITCODE)." }

# 3) Fail the step unless the new revision becomes ready (catches crash-looping revisions).
$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 15
    $state = az containerapp show --name $appName --resource-group $resourceGroup `
        --query "{latest:properties.latestRevisionName, ready:properties.latestReadyRevisionName, fqdn:properties.configuration.ingress.fqdn}" `
        --output json --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "az containerapp show failed (exit $LASTEXITCODE)." }
    if ($state.latest -and $state.latest -eq $state.ready) { break }
    Write-Host "Waiting for revision $($state.latest) to become ready (ready: $($state.ready))..."
} while ((Get-Date) -lt $deadline)

if (-not $state.latest -or $state.latest -ne $state.ready) {
    throw "Revision $($state.latest) did not become ready within 5 minutes; check its logs (a paused database can stall Migrate() at startup)."
}
if ([string]::IsNullOrWhiteSpace($state.fqdn)) { throw "Revision is ready but ingress FQDN is empty; check ingress settings." }
Write-Host "Done. Revision $($state.latest) is ready on $image. URL: https://$($state.fqdn)"
