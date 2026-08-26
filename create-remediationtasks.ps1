<#
.SYNOPSIS
Creates remediation tasks for noncompliant, remediable policies in an initiative assignment.

.DESCRIPTION
Finds noncompliant policy definition references for one initiative assignment and creates one
remediation task per DeployIfNotExists or Modify reference. Active duplicate tasks are skipped.

.EXAMPLE
./create-remmidationtasks.ps1 -PolicyAssignmentId '/subscriptions/<subscription-id>/providers/Microsoft.Authorization/policyAssignments/<assignment-name>' -WhatIf

.EXAMPLE
./create-remmidationtasks.ps1 -PolicyAssignmentId '/subscriptions/<subscription-id>/providers/Microsoft.Authorization/policyAssignments/<assignment-name>'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
	[Parameter(Mandatory)]
	[ValidatePattern('/providers/Microsoft\.Authorization/policyAssignments/')]
	[string] $PolicyAssignmentId,

	[ValidateRange(1, 100)]
	[int] $ParallelDeployments = 10,

	[ValidateRange(1, 50000)]
	[int] $ResourceCount = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredModules = @('Az.Resources', 'Az.PolicyInsights')
$missingModules = @($requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($missingModules.Count -gt 0) {
	throw "Required Azure PowerShell modules are missing: $($missingModules -join ', '). Install them with: Install-Module Az -Scope CurrentUser"
}

if (-not (Get-AzContext)) {
	throw 'No Azure context is available. Run Connect-AzAccount first.'
}

$assignment = Get-AzPolicyAssignment -Id $PolicyAssignmentId
$definition = Get-AzPolicySetDefinition -Id $assignment.PolicyDefinitionId
if (-not $definition) {
	throw "The assignment '$PolicyAssignmentId' does not reference a policy initiative."
}

$assignmentScope = $assignment.Scope
if (-not $assignmentScope) {
	$assignmentScope = $PolicyAssignmentId -replace '/providers/Microsoft\.Authorization/policyAssignments/[^/]+$', ''
}

$stateParameters = @{
	All    = $true
	Filter = "PolicyAssignmentId eq '$PolicyAssignmentId' and ComplianceState eq 'NonCompliant'"
}

switch -Regex ($assignmentScope) {
	'^/providers/Microsoft\.Management/managementGroups/([^/]+)$' {
		$stateParameters.ManagementGroupName = $Matches[1]
		break
	}
	'^/subscriptions/([^/]+)/resourceGroups/([^/]+)$' {
		$stateParameters.SubscriptionId = $Matches[1]
		$stateParameters.ResourceGroupName = $Matches[2]
		break
	}
	'^/subscriptions/([^/]+)$' {
		$stateParameters.SubscriptionId = $Matches[1]
		break
	}
	default {
		$stateParameters.ResourceId = $assignmentScope
	}
}

$nonCompliantStates = @(Get-AzPolicyState @stateParameters)
$nonCompliantReferenceIds = @(
	$nonCompliantStates |
		Where-Object PolicyDefinitionReferenceId |
		Select-Object -ExpandProperty PolicyDefinitionReferenceId -Unique
)

if ($nonCompliantReferenceIds.Count -eq 0) {
	Write-Host "No noncompliant policy definitions were found for '$($assignment.Name)'."
	return
}

$results = foreach ($referenceId in $nonCompliantReferenceIds) {
	$resolvedActions = @(
		$nonCompliantStates |
			Where-Object PolicyDefinitionReferenceId -eq $referenceId |
			Select-Object -ExpandProperty PolicyDefinitionAction -Unique
	)
	$isRemediable = $resolvedActions -contains 'deployIfNotExists' -or $resolvedActions -contains 'modify'
	if (-not $isRemediable) {
		$actionList = ($resolvedActions | Sort-Object) -join ', '
		Write-Warning "Skipping '$referenceId' because its resolved action ('$actionList') is not DeployIfNotExists or Modify."
		continue
	}

	$safeReferenceId = ($referenceId -replace '[^a-zA-Z0-9-]', '-').Trim('-')
	$timestamp = Get-Date -Format 'yyyyMMddHHmmss'
	$maximumReferenceLength = 64 - 'remediate--'.Length - $timestamp.Length
	if ($safeReferenceId.Length -gt $maximumReferenceLength) {
		$safeReferenceId = $safeReferenceId.Substring(0, $maximumReferenceLength).TrimEnd('-')
	}
	$remediationName = "remediate-$safeReferenceId-$timestamp"

	$existing = Get-AzPolicyRemediation -Scope $assignmentScope |
		Where-Object {
			$_.PolicyAssignmentId -eq $PolicyAssignmentId -and
			$_.PolicyDefinitionReferenceId -eq $referenceId -and
			$_.ProvisioningState -in @('Accepted', 'Evaluating', 'Running')
		} |
		Select-Object -First 1

	if ($existing) {
		Write-Warning "Skipping '$referenceId' because remediation '$($existing.Name)' is already active."
		continue
	}

	if ($PSCmdlet.ShouldProcess($referenceId, "Create remediation task '$remediationName'")) {
		Start-AzPolicyRemediation `
			-Name $remediationName `
			-Scope $assignmentScope `
			-PolicyAssignmentId $PolicyAssignmentId `
			-PolicyDefinitionReferenceId $referenceId `
			-ResourceCount $ResourceCount `
			-ParallelDeploymentCount $ParallelDeployments `
			-NoWait
	}
}

$results
