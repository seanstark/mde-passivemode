# Microsoft Defender for Endpoint mode

This Machine Configuration package audits or configures this Windows registry value:

- Key: `HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection`
- Value: `ForceDefenderPassiveMode`
- Type: `REG_DWORD`
- `Active`: `0`
- `Passive`: `1`

The build generates two Azure Policy definitions:

- **Audit** reports the actual guest registry state without changing it.
- **Configure** applies the selected mode and autocorrects drift.

The included subscription-scope ARM template deploys:

- The custom Machine Configuration policy definition.
- A Change Tracking data collection rule (DCR) for `ForceDefenderPassiveMode`.
- An Azure Monitor workbook for current mode and registry change history.

## Table of contents

- [Deploy to Azure](#deploy-to-azure)
	- [Azure CLI](#azure-cli)
	- [Azure PowerShell](#azure-powershell)
- [Post-deployment](#post-deployment)
	- [1. Enable Machine Configuration prerequisites](#1-enable-machine-configuration-prerequisites)
	- [2. Assign the custom policy](#2-assign-the-custom-policy)
	- [3. Associate the DCR with machines](#3-associate-the-dcr-with-machines)
	- [4. Verify the workbook](#4-verify-the-workbook)
	- [5. Verify policy compliance](#5-verify-policy-compliance)
- [Package availability and updates](#package-availability-and-updates)
- [Package authoring prerequisites](#package-authoring-prerequisites)
- [Build and publish](#build-and-publish)
- [References](#references)

## Deploy to Azure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fseanstark%2Fmde-passivemode%2Fmain%2Fazuredeploy.json)

The template deploys at subscription scope. Before deploying, confirm that:

- The target resource group already exists.
- The Log Analytics workspace already exists.
- You have permission to create policy definitions at subscription scope and DCR/workbook resources in the target resource group. `Resource Policy Contributor` plus `Monitoring Contributor` is sufficient for the template resources.
- The `Microsoft.GuestConfiguration` and `Microsoft.Insights` resource providers are registered in the subscription.

The only required template parameters are:

| Parameter | Description |
| --- | --- |
| `resourceGroupName` | Existing resource group where the DCR and workbook are deployed. |
| `logAnalyticsWorkspaceResourceId` | Full resource ID of the Log Analytics workspace used by Change Tracking and the workbook. |

### Azure CLI

```powershell
az login
az account set --subscription '<subscription-id>'
az provider register --namespace Microsoft.GuestConfiguration
az provider register --namespace Microsoft.Insights

az deployment sub create `
	--name deploy-mde-passive-mode `
	--location westus2 `
	--template-file ./azuredeploy.json `
	--parameters `
		resourceGroupName='<resource-group-name>' `
		logAnalyticsWorkspaceResourceId='/subscriptions/<subscription-id>/resourceGroups/<workspace-resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'
```

### Azure PowerShell

```powershell
Connect-AzAccount
Set-AzContext -Subscription '<subscription-id>'

Register-AzResourceProvider -ProviderNamespace Microsoft.GuestConfiguration
Register-AzResourceProvider -ProviderNamespace Microsoft.Insights

New-AzSubscriptionDeployment `
	-Name 'deploy-mde-passive-mode' `
	-Location 'westus2' `
	-TemplateFile './azuredeploy.json' `
	-resourceGroupName '<resource-group-name>' `
	-logAnalyticsWorkspaceResourceId '/subscriptions/<subscription-id>/resourceGroups/<workspace-resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'
```

To rebuild `azuredeploy.json` after changing any source artifact:

```powershell
pwsh ./Build-DeploymentTemplate.ps1
```

## Post-deployment

### 1. Enable Machine Configuration prerequisites

Assign the built-in initiative **Deploy prerequisites to enable Guest Configuration policies on virtual machines** at the management group, subscription, or resource-group scope containing the target Azure VMs. It enables the system-assigned managed identity and Machine Configuration extension required by the custom policy.

Arc-enabled servers include Machine Configuration in the Connected Machine agent. Include Arc machines in the custom policy assignment only after reviewing the applicable Azure Arc charges.

### 2. Assign the custom policy

The template creates the policy definition but doesn't assign it. In **Azure Policy > Definitions**, locate **Configure Microsoft Defender for Endpoint mode on Windows machines**, select **Assign**, and configure:

- `DefenderMode`: `Active` writes DWORD `0`; `Passive` writes DWORD `1`.
- `IncludeArcMachines`: include supported Arc-connected Windows machines when required.
- `EnableAutoRemediation`: enable enforcement and drift correction, or disable it for audit-only rollout.
- `contentUri`: retain the default unless the identical package is hosted at another reachable HTTPS URL.

Create a remediation task during assignment for existing machines. The policy assignment needs a managed identity and the role shown by the portal for the `DeployIfNotExists` effect. New or updated machines are evaluated automatically; existing machines require the remediation task to receive the guest assignment promptly.

### 3. Associate the DCR with machines

Deploying the DCR alone doesn't connect it to machines. Create a data collection rule association for each target Azure VM or Arc-enabled server, or use Azure Policy to create those associations at scale.

Target machines must have Azure Monitor Agent and the Change Tracking and Inventory extension/configuration required for AMA-based Change Tracking. Confirm that `ConfigurationChange` records reach the selected Log Analytics workspace before relying on the workbook.

### 4. Verify the workbook

Open **Azure Monitor > Workbooks > Defender for Endpoint Passive Mode Monitor**. The deployed workspace is selected by default. Verify that:

- Computers appear in the workbook filter.
- `ConfigurationChange` contains records where `ValueName == "ForceDefenderPassiveMode"`.
- Current mode and change-history visuals return data after Change Tracking completes its first collection cycle.

### 5. Verify policy compliance

Open **Azure Policy > Compliance**, select the policy assignment, and review per-resource Machine Configuration details. Initial assignment, package download, and guest evaluation aren't immediate; allow at least one Machine Configuration evaluation cycle before troubleshooting a pending result.

## Package availability and updates

The Machine Configuration ZIP must remain reachable by every target machine at the policy's `contentUri`. The package bytes must match the `contentHash` embedded in the policy definition.

When changing the package:

1. Build and test a new ZIP.
2. Publish it at a versioned HTTPS URL.
3. Regenerate `configureMDEMode.json` so its URI and hash match the new package.
4. Regenerate `azuredeploy.json` with `Build-DeploymentTemplate.ps1`.
5. Redeploy the template and remediate the policy assignment as needed.

## Package authoring prerequisites

Use an **x64 PowerShell 7** process on Windows and install the official authoring modules. ARM64 PowerShell can't compile Windows DSC configurations, even when Windows x64 emulation is available.

```powershell
Install-Module GuestConfiguration -Scope CurrentUser
Install-Module PSDesiredStateConfiguration -RequiredVersion 2.0.7 -Scope CurrentUser
```

Run the build from that same x64 PowerShell 7 process:

```powershell
pwsh -NoProfile -File ./Build-MdeDefenderMode.ps1
```

If module discovery fails, verify the host and module path from the same terminal:

```powershell
$PSVersionTable
[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
Get-Module -ListAvailable GuestConfiguration, PSDesiredStateConfiguration |
	Select-Object Name, Version, Path
$env:PSModulePath -split [System.IO.Path]::PathSeparator
```

## Build and publish

Create the `AuditAndSet` package:

```powershell
pwsh ./Build-MdeDefenderMode.ps1
```

Test the package from an elevated PowerShell 7 session:

```powershell
Get-GuestConfigurationPackageComplianceStatus -Path ./output/MdeDefenderModeConfig.zip
```

Publish `output/MdeDefenderModeConfig.zip` to an HTTPS location accessible by the managed machines. Azure Blob Storage is recommended. Then generate the audit and enforcement definitions with the exact published URI:

```powershell
pwsh ./Build-MdeDefenderMode.ps1 -ContentUri 'https://<account>.blob.core.windows.net/<container>/MdeDefenderModeConfig.zip?<sas>'
```

The generated JSON files are written below `output/policies`. The authoring cmdlet calculates and embeds the package content hash, so regenerate both definitions whenever the package changes.

Do not commit a long-lived SAS token. For private Blob Storage, use a managed-identity package access design instead of embedding credentials in source control.

## References

- [Azure Machine Configuration overview](https://learn.microsoft.com/azure/governance/machine-configuration/overview/01-overview-concepts)
- [Create a custom package](https://learn.microsoft.com/azure/governance/machine-configuration/how-to/develop-custom-package/2-create-package)
- [Create a custom policy definition](https://learn.microsoft.com/azure/governance/machine-configuration/how-to/create-policy-definition)