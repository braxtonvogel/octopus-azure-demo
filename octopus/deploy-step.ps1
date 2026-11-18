# Octopus "Notes App" Azure Script step (Azure account set on the step; runs with az CLI logged in).
# One script for every environment: all per-env values come from scoped Octopus variables.
# No secrets pass through Octopus: each Container App holds its own DB connection as secret 'db-conn'.
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
} elseif ($isPrChannel -and $version -match '^1\.0\.0-pr\.\d+\.\d+$') {
    if ($appName -notlike 'notes-app-pr-*') { throw "PR image $version can only deploy to a notes-app-pr-* app, not '$appName'." }
} else {
    throw "notes-image version '$version' isn't allowed in channel '$channel' (main: 1.0.N; PR Environments: 1.0.N or 1.0.0-pr.N.R; never 'latest')."
}

$image = "ghcr.io/braxtonvogel/octopus-azure-demo:$version"
Write-Host "Deploying $image to $appName in $resourceGroup ($($OctopusParameters['Octopus.Environment.Name']))"

# 1) Roll a new revision on the pinned image, wiring the env var to the secret.
az containerapp update --name $appName --resource-group $resourceGroup `
    --image $image `
    --set-env-vars "ConnectionStrings__Default=secretref:db-conn" --output none
if ($LASTEXITCODE -ne 0) { throw "az containerapp update failed (exit $LASTEXITCODE)." }

# 2) Fail the step unless the new revision becomes ready (catches crash-looping revisions).
$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 15
    $state = az containerapp show --name $appName --resource-group $resourceGroup `
        --query "{latest:properties.latestRevisionName, ready:properties.latestReadyRevisionName, fqdn:properties.configuration.ingress.fqdn}" `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "az containerapp show failed (exit $LASTEXITCODE)." }
    if ($state.latest -and $state.latest -eq $state.ready) { break }
    Write-Host "Waiting for revision $($state.latest) to become ready (ready: $($state.ready))..."
} while ((Get-Date) -lt $deadline)

if (-not $state.latest -or $state.latest -ne $state.ready) {
    throw "Revision $($state.latest) did not become ready within 5 minutes; check its logs (a paused database can stall Migrate() at startup)."
}
if ([string]::IsNullOrWhiteSpace($state.fqdn)) { throw "Revision is ready but ingress FQDN is empty; check ingress settings." }
Write-Host "Done. Revision $($state.latest) is ready on $image. URL: https://$($state.fqdn)"
