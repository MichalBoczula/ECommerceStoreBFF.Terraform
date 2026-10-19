# EcommerceStore BFF infrastructure

Deploy the existing .NET/YARP BFF to Azure Container Apps for a temporary
portfolio demo, verify it, capture the portfolio material, then destroy it.
Provisioning and destruction are manual. CI validates the configuration and
tests the published image; it never signs in to Azure or applies Terraform.

## What this stack owns

| Target | Ownership |
| --- | --- |
| `rg-ecommercestore-bff-dev` | Created here |
| `ca-ecommercestore-bff-dev` | Created here: Consumption, 0.25 vCPU / 0.5 GiB, single revision, maximum one replica |
| Existing Products ACA environment | Read only; owned by `ProductsCatalog.Terraform` |
| Existing Products app | Read only, with `read_secrets = false`; its actual HTTPS FQDN becomes the upstream |
| VNet, subnet, SQL, photos, Key Vault | Owned by Products; no changes from this stack |
| Standard Static Web App and optional BFF link | Owned by `ecommerce-store-web-terraform` |

The default plan creates **two managed resources**. No additional environment,
database, identity, registry, secret, public IP, or Log Analytics workspace is
needed for this public Docker Hub image and catalogue proxy. Shared environment
and network costs remain in the Products stack. `min_replicas = 0` permits scale
to zero; it does not stop charges for other provisioned infrastructure.

Terraform uses a separate blob in your existing state account:

```text
stecomtfstatemb261011 / tfstate / bff/development.terraform.tfstate
```

The backend storage is never created or destroyed here. Do not reuse the
Products, web, or old whole-store state keys. This stack reads Azure resources
directly instead of loading the Products state, which can contain SQL secrets.

## Runtime contract and current scope

Source: [ECommerceStoreBFF](https://github.com/MichalBoczula/ECommerceStoreBFF).
The example pins the published image from master commit
`3bbbe1c1eb7e76fc60b1bfeebeba613c9477ad7b` by its verified Docker Hub digest.
Only successfully published image digests are accepted; `latest` is rejected.
The public image needs no Docker Hub credentials in Azure.

The BFF listens on port **8080**. Startup, liveness, and readiness use its existing
**`/health`** endpoint. That check confirms the BFF process is healthy; it does
not check Products, SQL, migrations, or the other services. The BFF has no
database or migration switch of its own.

`config/bff-environment.json` configures production settings and additional YARP
routes through ordinary .NET environment configuration. The Products destination
is injected from the existing app lookup. Generated Kiota clients use
`http://localhost:8080` for their intended calls through the BFF itself.

| Request reaching BFF | Forwarded to Products |
| --- | --- |
| `/api/mobile-phones?amount=15` | `/mobile-phones?amount=15` |
| `/api/mobile-phones/<id>` | `/mobile-phones/<id>` |
| `/api/mobile-phones/filter?...` | `/mobile-phones/filter?...` |
| `/api/categories` | `/categories` |
| `/api/currencies` | `/currencies` |
| Existing `/mobile-phones`, `/categories`, `/currencies` | Existing paths preserved |
| Existing `/api/products/swagger/v1/swagger.json` | `/swagger/v1/swagger.json` |

Static Web Apps forwards the **whole `/api` path**. The extra YARP routes remove
that prefix before calling Products. Responses, including `mainPhoto` and
percent-encoded Blob URLs, pass through unchanged. The browser fetches anonymous
photos directly from Blob Storage; the BFF needs no Storage permissions.

This first deployment connects **Products only**. Users, orders, and payments
destinations explicitly use reserved `.invalid` hosts rather than container
localhost defaults. Those flows are unavailable until their services are
deployed and configured. Registration, checkout, and the complete storefront
are not acceptance criteria for this slice.

The Angular application's current `/backend` base path still needs to be changed
to same-origin `/api` in its own repository before the linked live catalogue
works. This infrastructure PR does not change Angular source or deploy it.
Entra sign-in, end-user authorization, and deployment automation remain later
steps.

## 1. Prerequisites and local files

Use PowerShell 7, Azure CLI with the `containerapp` extension, and Terraform
1.16.5. The committed lock file pins AzureRM **5.9.0**, including its Container
Apps deletion polling fix, with official Linux and Windows checksums.

First deploy the Products foundation **and Products Container App**. The two
apps must share the same ACA environment; a plan rejects a Products app in a
different one. Products may use internal ingress. Its SQL readiness and seeded
database must work before catalogue verification can succeed.

Your account needs access to the existing state container, read access to the
Products app/environment, and permission to create the BFF resource group and
app. If provider registration is restricted, have the subscription administrator
register `Microsoft.App` first.

```powershell
Set-Location D:\Programowanie\Apps\ECommerceStoreBFF.Terraform
$ErrorActionPreference = 'Stop'
$ecommerceTerraform = Join-Path $env:LOCALAPPDATA `
    'Programs\Terraform\1.16.5\terraform.exe'
if (-not (Test-Path -LiteralPath $ecommerceTerraform)) { throw 'Terraform executable not found' }

az login
if ($LASTEXITCODE -ne 0) { throw 'Azure login failed' }
az account set --subscription 'fcbf086b-8ce4-4ca5-a3d7-0c56489e25f6'
if ($LASTEXITCODE -ne 0) { throw 'Subscription selection failed' }

if (-not (Test-Path .\terraform.tfvars)) { Copy-Item .\terraform.tfvars.example .\terraform.tfvars }
if (-not (Test-Path .\backend.hcl)) { Copy-Item .\backend.hcl.example .\backend.hcl }
Get-Content .\backend.hcl
```

Review `terraform.tfvars` and `backend.hcl`. The examples already select your
subscription and state account. Defaults look up
`cae-ecommercestore-products-dev` and `ca-ecommercestore-products-dev` in
`rg-ecommercestore-products-dev`; set `shared_environment` / `products_app` only
if your actual names differ. Location comes from the existing environment.
For `test` or `prod`, also choose separate backend keys before initialization.

## 2. Initialize, check, and review the plan

```powershell
& $ecommerceTerraform init '-backend-config=backend.hcl'
if ($LASTEXITCODE -ne 0) { throw 'Initialization failed' }
& $ecommerceTerraform fmt '-check' '-recursive'
if ($LASTEXITCODE -ne 0) { throw 'Formatting check failed' }
& $ecommerceTerraform validate
if ($LASTEXITCODE -ne 0) { throw 'Validation failed' }
& $ecommerceTerraform test
if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }

# Keep one instance running for the first console/API verification.
# This ignored file overrides the example's scale-to-zero setting.
@{ min_replicas = 1; external_ingress_enabled = $false } |
    ConvertTo-Json | Set-Content .\bff-runtime.auto.tfvars.json -Encoding utf8

& $ecommerceTerraform plan '-input=false' '-out=bff-deploy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Deployment planning failed' }
```

Expect two additions and no managed changes to Products or its network. Read the
plan before applying. Missing shared resources mean Products must be deployed
first; do not import them into this state. If initialization reports a changed
backend, confirm the account/container/key first. Use `init -reconfigure` only
for reselecting the intended existing backend; moving state requires a deliberate
`-migrate-state` operation instead.

## 3. Apply and inspect the running revision

```powershell
& $ecommerceTerraform apply bff-deploy.tfplan
if ($LASTEXITCODE -ne 0) { throw 'BFF deployment failed; retain state and inspect the error' }

$deploymentJson = (& $ecommerceTerraform output -json bff_deployment) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'BFF output lookup failed' }
$deployment = $deploymentJson | ConvertFrom-Json
$deployment | Format-List

az containerapp show --subscription $deployment.subscription_id `
    --resource-group $deployment.resource_group_name --name $deployment.name `
    --query '{state:properties.provisioningState,revision:properties.latestReadyRevisionName,fqdn:properties.configuration.ingress.fqdn,external:properties.configuration.ingress.external,min:properties.template.scale.minReplicas,image:properties.template.containers[0].image}' `
    --output json
if ($LASTEXITCODE -ne 0) { throw 'BFF inspection failed' }

az containerapp revision list --subscription $deployment.subscription_id `
    --resource-group $deployment.resource_group_name --name $deployment.name `
    --output table
if ($LASTEXITCODE -ne 0) { throw 'Revision lookup failed' }

az containerapp logs show --subscription $deployment.subscription_id `
    --resource-group $deployment.resource_group_name --name $deployment.name `
    --type system --tail 100 --format json
if ($LASTEXITCODE -ne 0) { throw 'System log lookup failed' }

az containerapp logs show --subscription $deployment.subscription_id `
    --resource-group $deployment.resource_group_name --name $deployment.name `
    --type console --tail 100 --format text
if ($LASTEXITCODE -ne 0) { throw 'Console log lookup failed' }
```

System logs require **JSON** format. Console logs support text. Without an
existing Log Analytics workspace these are live/recent logs, not durable log
history. A ready BFF revision can coexist with a Products SQL error: inspect the
Products revision and logs separately when catalogue calls fail.

## 4. Verify internal connectivity before opening ingress

The default BFF URL is internal to the ACA environment. Opening it from your
laptop can return Azure's **404 / stopped or does not exist** page even when the
app is healthy. A healthy app at zero replicas is also expected with the default
minimum of zero. Keep the temporary minimum of one while using the console.

Open a shell **inside the BFF container**:

```powershell
az containerapp exec --subscription $deployment.subscription_id `
    --resource-group $deployment.resource_group_name --name $deployment.name `
    --container bff --command /bin/bash
if ($LASTEXITCODE -ne 0) { throw 'BFF console session failed' }
```

Run these Bash commands in that container shell. They use Bash TCP support, so
you do not need to install curl in the non-root runtime image:

```bash
exec 3<>/dev/tcp/127.0.0.1/8080
printf 'GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
cat <&3
exec 3>&-

exec 3<>/dev/tcp/127.0.0.1/8080
printf 'GET /api/mobile-phones?amount=15 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
cat <&3
exec 3>&-
exit
```

Expect HTTP 200 and `Healthy` from the first request. After Products is ready,
the second should return the seeded phones with `mainPhoto` URLs. A 502 suggests
an upstream routing/connectivity problem; a Products 500 can indicate SQL or
migration failure. Changing the BFF health probe will not fix SQL access.

## 5. Link the BFF to the existing web hosting

The [web Terraform stack](https://github.com/MichalBoczula/ecommerce-store-web-terraform)
owns the SWA link. SWA requires external BFF ingress and a publicly reachable
ACA environment. Enabling external ingress alone permits direct unauthenticated
requests to the current BFF, so perform this step when ready to apply the link
immediately. The link configures `Azure Static Web Apps (Linked)` authentication
to restrict backend access to the linked site. This is not end-user Entra
authentication or authorization for future write/checkout flows.

In the **BFF Terraform directory**, enable external ingress and review/apply:

```powershell
$runtime = Get-Content .\bff-runtime.auto.tfvars.json -Raw -Encoding utf8 |
    ConvertFrom-Json -AsHashtable
$runtime.external_ingress_enabled = $true
$runtime | ConvertTo-Json | Set-Content .\bff-runtime.auto.tfvars.json -Encoding utf8

& $ecommerceTerraform plan '-input=false' '-out=bff-link-access.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'BFF ingress planning failed' }
& $ecommerceTerraform apply bff-link-access.tfplan
if ($LASTEXITCODE -ne 0) { throw 'BFF ingress update failed' }

$deploymentJson = (& $ecommerceTerraform output -json bff_deployment) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'BFF output lookup failed' }
$deployment = $deploymentJson | ConvertFrom-Json

$webTerraformRoot = 'D:\Programowanie\Apps\ecommerce-store-web-terraform'
@{ bff_backend = @{ resource_id = $deployment.id; region = $deployment.location } } |
    ConvertTo-Json -Depth 4 |
    Set-Content (Join-Path $webTerraformRoot 'bff-link.auto.tfvars.json') -Encoding utf8

# The web root must already have its own initialized backend and local inputs.
& $ecommerceTerraform "-chdir=$webTerraformRoot" plan '-input=false' '-out=web-bff-link.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Web BFF link planning failed' }
& $ecommerceTerraform "-chdir=$webTerraformRoot" apply web-bff-link.tfplan
if ($LASTEXITCODE -ne 0) { throw 'Web BFF link failed; restore BFF internal ingress with a new plan/apply, then inspect the error' }
```

Review both plans before their respective applies. This root does not manage
`authConfigs/current`, so subsequent BFF plans do not reset the SWA-managed
provider. Unlinking does **not** automatically remove that authentication.
Do not disable it to make the raw ACA URL work; test through SWA instead.
After a BFF replacement, recreate the web link to establish authentication on
the new app before treating the new deployment as linked.

Verify routing independently of Angular source changes:

```powershell
$webJson = (& $ecommerceTerraform "-chdir=$webTerraformRoot" output -json web_deployment) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Web output lookup failed' }
$web = $webJson | ConvertFrom-Json
$phones = @(Invoke-RestMethod "$($web.base_url)/api/mobile-phones?amount=15" -TimeoutSec 45)
if ($phones.Count -ne 15 -or @($phones | Where-Object { [string]::IsNullOrWhiteSpace($_.mainPhoto) }).Count -gt 0) {
    throw 'Expected 15 seeded phones with mainPhoto URLs'
}
$photo = Invoke-WebRequest $phones[0].mainPhoto -Method Head -TimeoutSec 30
if ($photo.StatusCode -ne 200 -or [string]$photo.Headers['Content-Type'] -notlike 'image/*') {
    throw 'Anonymous photo access failed; verify the Products storage setting and photo import'
}
```

The photo check sends no SAS or Authorization header. SQL auto-resume and ACA
cold starts can need a retry. SWA's backend request timeout remains 45 seconds.
Use the temporary replica minimum during the demo and check Products separately
if its SQL start exceeds that timeout. Complete the Angular `/api` change and
upload a production build before verifying the actual storefront layout.

After verification, restore `min_replicas` to zero in
`bff-runtime.auto.tfvars.json`, review a **new** plan, and apply it. Keep external
ingress enabled while SWA is linked. Do not reuse an older saved plan.

## 6. Destroy after the portfolio session

Destroy or unlink the **web stack first**, then destroy **BFF**, then destroy
**Products** and its shared environment/network. The web link references BFF;
BFF references the Products environment. Destroying BFF alone leaves the shared
network, SQL, photos, and web hosting provisioned and potentially billable.
Keep the independent state storage account.

In the BFF root, retain all local input files and the backend configuration:

```powershell
$deploymentJson = (& $ecommerceTerraform output -json bff_deployment) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Capture BFF identifiers before destroying' }
$deployment = $deploymentJson | ConvertFrom-Json

& $ecommerceTerraform plan '-destroy' '-input=false' '-out=bff-destroy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Destroy planning failed; no resources were deleted' }
# Review: only the BFF app and BFF resource group should be deleted.
& $ecommerceTerraform apply bff-destroy.tfplan
if ($LASTEXITCODE -ne 0) { throw 'Destroy failed; retain state and inputs before retrying' }

& $ecommerceTerraform state list
if ($LASTEXITCODE -ne 0) { throw 'State verification failed' }
az group exists --subscription $deployment.subscription_id `
    --name $deployment.resource_group_name --output tsv
if ($LASTEXITCODE -ne 0) { throw 'BFF resource group verification failed' }
```

No **managed** BFF resources should remain in state, and the resource group
check should return `false`. Read-only `data.*` entries may remain and do not
represent resources owned here. Do not delete the state blob, use `state rm`, or
delete the shared Products resource group to fix a BFF destroy error.

If Azure accepted a deletion but Terraform reports a polling error, inspect
`az containerapp list` for the BFF resource group and retry a newly reviewed
destroy plan after deletion completes. This root pins AzureRM 5.9.0 rather than
the 5.8.0 version from the earlier polling failures. Keep the shared environment
and Products app until BFF destruction completes: the read-only lookups still
need those dependencies during normal planning. If they were deleted out of
order, retain the BFF state and inspect the remaining Azure resources before
choosing a recovery plan.

## Checks without Azure provisioning

```powershell
& $ecommerceTerraform init '-backend=false' '-input=false' '-lockfile=readonly'
if ($LASTEXITCODE -ne 0) { throw 'Offline initialization failed' }
& $ecommerceTerraform fmt '-check' '-recursive'
if ($LASTEXITCODE -ne 0) { throw 'Formatting check failed' }
& $ecommerceTerraform validate
if ($LASTEXITCODE -ne 0) { throw 'Validation failed' }
& $ecommerceTerraform test
if ($LASTEXITCODE -ne 0) { throw 'Mocked tests failed' }
```

Run those backend-disabled checks in a separate checkout so your initialized
deployment backend stays intact. CI also runs `python tests/test_published_image.py`
on Linux with Docker. It starts the exact published BFF image using the same
static configuration file as Terraform and a local Products HTTP stand-in,
checks `/health`, exercises list/detail/filter/category/currency/documentation
routes, and checks preservation of an encoded photo URL. No Azure credentials
or real database are involved. These checks do not replace live Azure/SWA/SQL
verification.

References: [ACA communication](https://learn.microsoft.com/en-us/azure/container-apps/connect-apps),
[SWA Container Apps linking](https://learn.microsoft.com/en-us/azure/static-web-apps/apis-container-apps),
[AzureRM 5.9.0](https://github.com/hashicorp/terraform-provider-azurerm/releases/tag/v5.9.0).
