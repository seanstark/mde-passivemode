# Microsoft Defender for Endpoint mode

This Machine Configuration package audits or configures this Windows registry value:

- Key: `HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection`
- Value: `ForceDefenderPassiveMode`
- Type: `REG_DWORD`
- `Active`: `0`
- `Passive`: `1`

The custom Machine Configuration policy supports two behaviors:

- **Audit** reports the actual guest registry state without changing it.
- **Configure** applies the selected mode and autocorrects drift.

The included subscription-scope ARM template deploys:

- The custom Machine Configuration policy definition.
- The custom **Configure Azure Benefits for Windows Arc Machines** policy definition.
- The custom **Configure ChangeTracking for Defender Passive Mode Auditing** policy initiative.
- A Change Tracking data collection rule (DCR) for `ForceDefenderPassiveMode`.
- An Azure Monitor workbook for current mode and registry change history.

## Table of contents

- [Deploy to Azure](#deploy-to-azure)
	- [Azure CLI](#azure-cli)
	- [Azure PowerShell](#azure-powershell)
- [Post-deployment](#post-deployment)
	- [1. Assign required policies and initiatives](#1-assign-required-policies-and-initiatives)
	- [2. Configure the custom policy assignment](#2-configure-the-custom-policy-assignment)
	- [3. Configure Azure Benefits for Windows Arc](#3-configure-azure-benefits-for-windows-arc)
	- [4. Create remediation tasks](#4-create-remediation-tasks)
	- [5. Verify the workbook](#5-verify-the-workbook)
	- [6. Verify policy compliance](#6-verify-policy-compliance)
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

### 1. Assign required policies and initiatives

The template creates two custom policy definitions, the custom Change Tracking initiative, and the DCR, but it doesn't create policy assignments. Assign the applicable definitions at the management group, subscription, or resource-group scope containing the target Windows machines.

| Policy or initiative | Requirement | Why it is needed |
| --- | --- | --- |
| **Configure Microsoft Defender for Endpoint mode on Windows machines** | Required | Assigns the custom Machine Configuration package that audits or configures `ForceDefenderPassiveMode`. This definition is deployed by this template. |
| **Configure ChangeTracking for Defender Passive Mode Auditing** | Required to track registry changes over time in more detail | Configures the identities, Guest Configuration extension, Azure Monitor Agent, Change Tracking extensions, and DCR associations for Windows Azure VMs, Arc-enabled servers, and VM scale sets. This custom initiative replaces the separate built-in Change Tracking initiatives previously required for each machine type. |
| **Configure Azure Benefits for Windows Arc Machines** | Required only for eligible Windows Arc machines using Azure benefits | Records the Software Assurance or subscription-license attestation used to enable Azure benefits. Eligible Windows Server licenses can include Azure Change Tracking and Inventory at no additional fee. Assigning this policy is an explicit licensing attestation and must be limited to machines covered by qualifying licenses. |

Retrieve the resource ID of the DCR created by this template:

```powershell
az monitor data-collection rule show `
	--resource-group '<resource-group-name>' `
	--name 'DefenderPassiveMode-ChangeTracking-dcr' `
	--query id `
	--output tsv
```

In **Azure Policy > Definitions**, locate **Configure ChangeTracking for Defender Passive Mode Auditing**, select **Assign**, and set its **Data Collection Rule** parameter to that resource ID. Enable a managed identity and grant the roles shown on the portal's **Remediation** tab so its `DeployIfNotExists` policies can deploy the required resources.

Use the same assignment scope as the Defender mode policy. The custom initiative covers Windows Azure VMs, Arc-enabled servers, and VM scale sets; its individual policies apply only to matching resource types.

### 2. Configure the custom policy assignment

In **Azure Policy > Definitions**, locate **Configure Microsoft Defender for Endpoint mode on Windows machines**, select **Assign**, and configure:

- `DefenderMode`: `Active` writes DWORD `0`; `Passive` writes DWORD `1`.
- `IncludeArcMachines`: include supported Arc-connected Windows machines when required.
- `EnableAutoRemediation`: enable enforcement and drift correction, or disable it for audit-only rollout.
- `contentUri`: retain the default unless the identical package is hosted at another reachable HTTPS URL.

Create a remediation task during assignment for existing machines. The policy assignment needs a managed identity and the role shown by the portal for the `DeployIfNotExists` effect. New or updated machines are evaluated automatically; existing machines require the remediation task to receive the guest assignment promptly.

Target machines must have Azure Monitor Agent and the Change Tracking and Inventory extension/configuration required for AMA-based Change Tracking. Confirm that `ConfigurationChange` records reach the selected Log Analytics workspace before relying on the workbook.

Arc-enabled servers include Machine Configuration in the Connected Machine agent. Include Arc machines in the custom policy assignment only after reviewing the applicable Azure Arc charges.

### 3. Configure Azure Benefits for Windows Arc

Assign **Configure Azure Benefits for Windows Arc Machines** only after confirming that the targeted Arc-connected Windows servers have qualifying Windows Server licenses with active Software Assurance or active subscription licenses. The assignment attests that the organization is entitled to these Azure benefits; the policy doesn't validate license purchase records.

Choose the policy effect according to the rollout stage:

- `AuditIfNotExists` reports machines where the applicable Azure benefits aren't enabled without changing them.
- `DeployIfNotExists` enables the applicable license profile settings and requires a managed identity with the role shown on the assignment's **Remediation** tab.
- `Disabled` turns off evaluation.

Start with `AuditIfNotExists` to review the affected Arc machines. Change the effect to `DeployIfNotExists` and create remediation only after the licensing and scope have been approved.

### 4. Create remediation tasks

After Azure Policy completes its initial compliance evaluation, use `create-remediationtasks.ps1` to create one remediation task for each noncompliant `DeployIfNotExists` or `Modify` policy in the custom initiative. The script skips non-remediable policy effects and any reference that already has an active remediation task.

Install the required Azure PowerShell modules and sign in:

```powershell
Install-Module Az.Resources, Az.PolicyInsights -Scope CurrentUser
Connect-AzAccount
Set-AzContext -Subscription '<subscription-id>'
```

Copy the full resource ID of the custom initiative assignment from **Azure Policy > Assignments**. Preview the tasks first:

```powershell
./create-remediationtasks.ps1 `
	-PolicyAssignmentId '/subscriptions/<subscription-id>/providers/Microsoft.Authorization/policyAssignments/<assignment-name>' `
	-WhatIf
```

Remove `-WhatIf` to create the remediation tasks:

```powershell
./create-remediationtasks.ps1 `
	-PolicyAssignmentId '/subscriptions/<subscription-id>/providers/Microsoft.Authorization/policyAssignments/<assignment-name>'
```

The script is intended for policy initiative assignments. Create remediation for the standalone Defender mode policy from its assignment in the Azure portal. Policy compliance data must exist before the script can identify noncompliant initiative references.

### 5. Verify the workbook

Open **Azure Monitor > Workbooks > Defender for Endpoint Passive Mode Monitor**. The deployed workspace is selected by default. Verify that:

- Computers appear in the workbook filter.
- `ConfigurationChange` contains records where `ValueName == "ForceDefenderPassiveMode"`.
- Current mode and change-history visuals return data after Change Tracking completes its first collection cycle.

### 6. Verify policy compliance

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