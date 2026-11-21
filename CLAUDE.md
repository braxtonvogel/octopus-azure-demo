# CLAUDE.md: octopus-azure-demo
Notes app (ASP.NET Razor Pages + EF Core) used to learn Octopus Deploy multi-environment releases on Azure.
GitHub Actions builds the image; Octopus deploys it to Azure Container Apps (Dev, Staging, Prod, and per-PR envs).

## Stack
.NET 11 (global.json), ASP.NET Razor Pages, EF Core 11 SqlServer, Docker, GHCR, GitHub Actions,
Octopus Deploy, Azure Container Apps, Azure SQL. The container listens on 8080.

## Commands
- Build: `dotnet build DemoApp`
- Run locally: `dotnet run --project DemoApp`
- New migration: `dotnet ef migrations add <Name> --project DemoApp`
- Image: `docker build .`
- Workflow lint: `actionlint .github/workflows/*.yml`

## Folder map
- `DemoApp/`: the app. `Program.cs` (startup, runs `Database.Migrate()`), `Data/` (DbContext), `Pages/`, `Migrations/`.
- `Dockerfile`: multi-stage build of DemoApp.
- `.github/workflows/build.yml`: push to main -> `ghcr.io/braxtonvogel/octopus-azure-demo:1.0.<run>`.
- `.github/workflows/pr-env.yml`: same-repo PRs -> `:1.0.0-pr.<N>.<run>.<attempt>` + Octopus release; cleanup on close.
- `docs/daily-runbook.md`: the daily run book (morning checklist + what the automated Octopus runbook "Daily health check" does).
- `octopus/`: Octopus scripts (`deploy-step.ps1`, PR env provision/deprovision runbooks, `runbook-provision-tenant.ps1`, `runbook-daily-health-check.ps1`). Production also has tenants (Tenant A, Tenant B): each has its own Container App `notes-app-<TenantSlug>` and free-tier DB `notes-<TenantSlug>`; `TenantSlug` is a per-tenant project template variable and must be unique per tenant.

## Conventions
- Build and release are separate: Actions builds and pushes images; Octopus creates releases and deploys.
- Deploys never use `latest`; versions are pinned (see the version check in `octopus/deploy-step.ps1`).
- Secrets only via Octopus Sensitive variables and Container Apps `secretref:`. Never in code, logs, or PR text.
- Migrations are committed with the model change that needs them.
- Feature flags are Octopus Feature Flags read through OpenFeature (`Program.cs`). `deploy-step.ps1` passes Octopus's client identifier to the app as secret `ff-client-id`; real deployments (Dev, Staging, Production, tenants, PR environments) log "Feature flag client identifier set", so Octopus does supply it, but which of the two variable names resolved is not known. The deploy script is also stored inline in the Octopus step, so keep the two copies in sync. Flags default to off. Current flag: `note-character-counter`.

## Definition of done
- `build` workflow green on the PR's changes; `actionlint` clean for workflow edits.
- No secrets in code or PR text; no logs or screenshots in PRs.
- Never `--no-verify` or force-push.
- No test project exists: say exactly what you verified by hand and what you couldn't.

## Known traps
- `Database.Migrate()` runs at startup: a paused serverless DB can outlast the Container App startup probe.
- `az` is a native command: `$ErrorActionPreference = 'Stop'` doesn't catch it; check `$LASTEXITCODE` after each call.
- Never use `pull_request_target` in workflows.
- `Database.Migrate()` needs DDL rights (db_ddladmin) for the app's DB user.

## End-of-run summary
Goal; files changed and why; commands run and results; what couldn't be verified; open questions.
