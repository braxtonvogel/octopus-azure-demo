# Daily run book: Notes App on Octopus + Azure

One page for the person on duty. The routine checks are automated by an Octopus runbook, **Daily health check**, which
fails (goes red) when something is wrong. The checklist below is what a human adds on top. About 5 minutes.

## What runs by itself
- **Octopus runbook "Daily health check"** (Notes App project, Runbooks; script in
  `octopus/runbook-daily-health-check.ps1`, kept identical to the copy inside the Octopus step).
- **Schedule:** scheduled trigger "Daily 13:00 UTC: health check" (attached to the runbook; target environment
  Production, every day). 13:00 UTC is 7:00 AM Central in winter and 8:00 AM Central in summer. (The trigger form's
  time zone list showed US zones as "Unknown", so UTC was used.) It can also be run by hand: Runbooks > Daily health
  check > Run... > Production.
- **What it checks (read-only):** every Container App in `rg-octopus-demo` (shared Production, Dev, Staging, Tenant A,
  Tenant B, and any open PR environment) is provisioned with its latest revision ready; the three core apps
  (`notes-app`, `notes-app-dev`, `notes-app-staging`) exist; it prints the running image; it counts the SQL databases on
  `sql-braxtonvogel` and prints each one's status. Any problem fails the step.
- **It does not open the sites.** Opening a site wakes its scale-to-zero app and its serverless database. A free-offer
  database has a monthly free allowance (100,000 vCore seconds per Microsoft's free offer page), and a database that runs
  out is paused until the next month, so a daily wake-up is avoided on purpose. The script has an optional
  `WakeSites` switch (an Octopus variable set to `True`) for a deliberate manual check; it is not set up by default.
- **Limits it watches:** the free-offer limit of 10 databases and, separately, a **vCore quota of 10 in total** (Azure's
  error message says the subscription would exceed "the allowed vCore quota of 10"). The quota is the one that bites
  first: every database has a max-vCores setting and the sum must stay within 10. On 2026-11-20 five databases at 2
  vCores used all 10, and a PR environment failed to create its database (`SubscriptionVcoreQuotaExceeded`). Since then
  new databases are created with 1 max vCore, and the Dev, Staging, Tenant A and Tenant B databases were lowered from
  2 to 1 (the main Production database stays at 2). The script reads one server, so its numbers are lower bounds.
- **The vCore budget, in numbers:** 6 of 10 are in use today (Production 2, four others 1 each). PR environments are
  capped at 2 apps, each with a 1-vCore database, so they need 2 more (8 of 10, which also triggers the "8 or more"
  warning while they exist). The tenant provisioning script keeps those 2 free: it refuses a new tenant database once
  the total would go above 8, so only two more tenants fit.
- **Verified (2026-11-20 CT):** the second manual run (task `ServerTasks-223`, after fixing a PowerShell 5.1 array-count
  bug that the first run, `ServerTasks-222`, exposed) printed `OK` for all 5 apps on image `1.0.5` and "All checks
  passed: 5 apps healthy, 5 databases"; Staging's database showed `Paused`, so nothing was woken.
- Octopus's Free tier page says a Cloud Free instance needs at least one deployment or runbook run every 60 days; this
  daily run should satisfy that (not independently confirmed).

## Morning checklist
1. **Octopus > Tasks:** open the latest "Run Daily health check". Green with "All checks passed" is normal.
   If it is red, read the lines starting `FAIL` (see below).
2. **Octopus > Tasks, filter state = Failed:** nothing unexpected in the last 24 hours.
3. **Notes App dashboard:** Development, Staging and Production show the versions you expect.
4. **Ephemeral environments:** a closed PR should have no `pr-N` environment. The PR provisioning script
   (`octopus/runbook-provision.ps1`) allows at most 2 PR apps at once.
5. **Free limits, no money:** database count well under 10 and max vCores in use well under 10 (the daily output lists
   both); the Azure free-trial credit page shows no charges. Never click "Upgrade" in Azure. Octopus stays on the Free tier.
6. **Tenants:** Tenant A and Tenant B each have a recent Production deployment. Open their sites occasionally by hand.
7. **Feature flags:** Notes App > Feature Flags > Note Character Counter. The state set on 2026-11-20 CT (checked in the
   Octopus flag page, and by loading the live sites): on in Development, and on in Production for Tenant B only (rule
   "Tenant B only"); everything else off. Trust the Octopus page over this sentence if they differ.

## If something fails
| What the health check prints | What it usually means | What to do |
|---|---|---|
| `FAIL <app>  ...  latest revision <name> is not ready` | The newest deployment did not start. The old revision may still be serving | Open the app in Azure (Container App > Log stream, Revisions) and read the error. Redeploy the previous release if needed. |
| `FAIL <app>  ...  provisioning state is <x>` | Azure is still changing or failed to change the app | Wait a few minutes and re-run; if it persists, check Azure > Activity log. |
| `FAIL  <app> is missing` | One of the three core apps is gone | Do not redeploy blindly: find out who removed it (Azure Activity log). |
| `still on the placeholder image` (warning) | A tenant app was provisioned but never deployed | Deploy the current release to that tenant (see rules below). |
| Database count 8 or more (warning) / 10 (failure) | Near the free-offer limit of 10 databases | Remove unused PR or test databases before creating tenants. |
| `Max vCores in use ... 8 of 10` or more (warning) | Near the subscription vCore quota; a new PR environment or tenant database may be refused | Lower another database's max vCores in the Azure portal (SQL database > Compute + storage; keep the free offer applied), or remove an unused database. |
| A provisioning run fails with `SubscriptionVcoreQuotaExceeded` | The vCore quota (10) is used up | Same as the row above, then re-run the provisioning runbook. |
| Octopus says a tenant is not authorized to use the Azure account | The account's tenant scope was reset | Infrastructure > Accounts > Azure Demo > Scope: "Both tenanted and untenanted", Tenant A and Tenant B only. |
| A site shows "Error." in the browser | The app started but the home page fails (a bad build, or a missing database user) | Read the app's log stream; redeploy the previous release. |

## Not verified yet (as of 2026-11-20 CT)
- **The schedule has not fired yet.** The trigger exists and is enabled (checked in Octopus), but no scheduled run has
  been observed. After the first 13:00 UTC, confirm a "Run Daily health check" task appears.
- **PR-environment deployment with the current `octopus/deploy-step.ps1`** (tenant branch included): Dev and Staging
  deployments with it passed; a PR environment with it had not been run when this was written.
- **Untested script paths:** `runbook-provision-tenant.ps1` when the tenant app already exists (it should do nothing and
  exit 0), and its refusal paths (10 databases on the server, vCore total above 8, tenant app cap of 4, bad or reserved
  slug). The slug check was tested only as a regex; the vCore summing was tested on sample JSON and, via the daily
  check, on real output, but the tenant script's new guard has not run for real.
- **Creating a database at 1 vCore with the CLI:** lowering existing databases in the Azure portal was verified, but
  `az sql db create ... --capacity 1 --use-free-limit` (used by the PR and tenant runbooks) has not yet been run, so
  that it succeeds and keeps the free offer is expected, not confirmed. The same goes for a PR environment at 1 vCore.
- **Startup speed at 1 vCore:** whether 1 max vCore slows `Database.Migrate()` enough to hurt app startup after a
  database resumes (see "Known traps" in CLAUDE.md) has not been measured.
- **The exact Octopus variable name for the feature-flag client identifier.** A real deployment sets the identifier
  (logs say "Feature flag client identifier set") but which of the two names the script tries is not known.
- **Site checks** (the `WakeSites` switch) were not run.

## Rules of the road
- Production releases need the "Approve Production" click in Octopus (assign it to yourself, then Proceed).
- Deploy tenants one at a time. Read the first lines of the deploy step before moving on: it should say
  "Tenant deployment: Tenant A -> notes-app-tenant-a". If it says it is deploying to `notes-app`, stop.
- **A release snapshots the deployment process when it is created.** After changing the deploy script in Octopus, create a
  **new release** before deploying; an older release keeps the old script.
- Keep `octopus/deploy-step.ps1` in this repo and the script inside the Octopus step identical (see CLAUDE.md), and the
  same for the runbook scripts in `octopus/`.
- No secrets in code, logs or pull requests.
