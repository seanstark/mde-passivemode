[CmdletBinding()]
param(
    [Parameter()]
    [string] $OutputPath = (Join-Path $PSScriptRoot 'azuredeploy.json')
)

$ErrorActionPreference = 'Stop'

function ConvertTo-ArmLiteral {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object] $Value
    )

    if ($Value -is [string]) {
        if ($Value.StartsWith('[')) {
            return "[$Value"
        }

        return $Value
    }

    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $result = [ordered] @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-ArmLiteral -Value $property.Value
        }

        return $result
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { ConvertTo-ArmLiteral -Value $_ })
        Write-Output -NoEnumerate $items
        return
    }

    return $Value
}

$policy = Get-Content -Raw (Join-Path $PSScriptRoot 'configureMDEMode.json') |
    ConvertFrom-Json -Depth 100
$workbook = Get-Content -Raw (Join-Path $PSScriptRoot 'workbook.json') |
    ConvertFrom-Json -Depth 100
$dcrTemplate = Get-Content -Raw (Join-Path $PSScriptRoot 'dcr_ChangeTracking.json') |
    ConvertFrom-Json -Depth 100

$policyParameters = ConvertTo-ArmLiteral -Value $policy.parameters
$policyMetadata = ConvertTo-ArmLiteral -Value $policy.metadata
$policyRule = ConvertTo-ArmLiteral -Value $policy.policyRule
$roleDefinitionIds = @($policy.policyRule.then.details.roleDefinitionIds)
if ($roleDefinitionIds.Count -eq 0) {
    throw "The policy doesn't contain any roleDefinitionIds."
}

$escapedRoleDefinitionIds = $roleDefinitionIds |
    ForEach-Object { "'$($_ -replace "'", "''")'" }
$policyRule.then.details.roleDefinitionIds = "[createArray($($escapedRoleDefinitionIds -join ', '))]"
$workspaceParameter = $workbook.items |
    Where-Object { $_.type -eq 9 } |
    ForEach-Object { $_.content.parameters } |
    Where-Object { $_.name -eq 'Workspace' } |
    Select-Object -First 1

if (-not $workspaceParameter) {
    throw "The workbook doesn't contain the expected 'Workspace' parameter."
}

$workspaceParameter.value = "[parameters('logAnalyticsWorkspaceResourceId')]"
$dcrProperties = $dcrTemplate.resources[0].properties
$dcrProperties.destinations.logAnalytics[0].workspaceResourceId = "[parameters('logAnalyticsWorkspaceResourceId')]"

$resourceGroupTemplate = [ordered] @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    parameters = [ordered] @{
        location = [ordered] @{
            type = 'string'
        }
        dataCollectionRuleName = [ordered] @{
            type = 'string'
        }
        logAnalyticsWorkspaceResourceId = [ordered] @{
            type = 'string'
        }
        workbookName = [ordered] @{
            type = 'string'
        }
        workbookDisplayName = [ordered] @{
            type = 'string'
        }
    }
    variables = [ordered] @{
        workbookData = $workbook
    }
    resources = @(
        [ordered] @{
            type = 'Microsoft.Insights/dataCollectionRules'
            apiVersion = '2024-03-11'
            name = "[parameters('dataCollectionRuleName')]"
            location = "[parameters('location')]"
            properties = $dcrProperties
        },
        [ordered] @{
            type = 'Microsoft.Insights/workbooks'
            apiVersion = '2023-06-01'
            name = "[parameters('workbookName')]"
            location = "[parameters('location')]"
            kind = 'shared'
            properties = [ordered] @{
                displayName = "[parameters('workbookDisplayName')]"
                serializedData = "[string(variables('workbookData'))]"
                version = '1.0'
                sourceId = "[parameters('logAnalyticsWorkspaceResourceId')]"
                category = 'workbook'
            }
        }
    )
}

$template = [ordered] @{
    '$schema' = 'https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    metadata = [ordered] @{
        description = 'Deploys the Microsoft Defender for Endpoint mode policy definition, Change Tracking data collection rule, and Azure Monitor workbook.'
    }
    parameters = [ordered] @{
        policyDefinitionName = [ordered] @{
            type = 'string'
            defaultValue = 'configure-mde-mode'
            metadata = [ordered] @{
                description = 'Name of the custom Azure Policy definition.'
            }
        }
        policyDefinitionDisplayName = [ordered] @{
            type = 'string'
            defaultValue = 'Configure Microsoft Defender for Endpoint mode on Windows machines'
            metadata = [ordered] @{
                description = 'Display name of the custom Azure Policy definition.'
            }
        }
        resourceGroupName = [ordered] @{
            type = 'string'
            metadata = [ordered] @{
                description = 'Existing resource group where the DCR and workbook are deployed.'
            }
        }
        location = [ordered] @{
            type = 'string'
            defaultValue = "[deployment().location]"
            metadata = [ordered] @{
                description = 'Azure region for the DCR and workbook.'
            }
        }
        dataCollectionRuleName = [ordered] @{
            type = 'string'
            defaultValue = 'DefenderPassiveMode-ChangeTracking-dcr'
        }
        logAnalyticsWorkspaceResourceId = [ordered] @{
            type = 'string'
            metadata = [ordered] @{
                description = 'Resource ID of the Log Analytics workspace used by Change Tracking and the workbook.'
            }
        }
        workbookName = [ordered] @{
            type = 'string'
            defaultValue = "[guid(subscription().subscriptionId, parameters('resourceGroupName'), 'mde-passive-mode-workbook')]"
            metadata = [ordered] @{
                description = 'Resource name of the workbook. Must be a GUID.'
            }
        }
        workbookDisplayName = [ordered] @{
            type = 'string'
            defaultValue = 'Defender for Endpoint Passive Mode Monitor'
        }
    }
    variables = [ordered] @{
        policyDefinitionId = "[subscriptionResourceId('Microsoft.Authorization/policyDefinitions', parameters('policyDefinitionName'))]"
    }
    resources = @(
        [ordered] @{
            type = 'Microsoft.Authorization/policyDefinitions'
            apiVersion = '2023-04-01'
            name = "[parameters('policyDefinitionName')]"
            properties = [ordered] @{
                policyType = 'Custom'
                mode = $policy.mode
                displayName = "[parameters('policyDefinitionDisplayName')]"
                description = 'Configures and autocorrects ForceDefenderPassiveMode in the Windows registry by using Azure Machine Configuration.'
                metadata = $policyMetadata
                parameters = $policyParameters
                policyRule = $policyRule
            }
        },
        [ordered] @{
            type = 'Microsoft.Resources/deployments'
            apiVersion = '2022-09-01'
            name = 'deploy-mde-passive-mode-monitoring'
            resourceGroup = "[parameters('resourceGroupName')]"
            properties = [ordered] @{
                mode = 'Incremental'
                expressionEvaluationOptions = [ordered] @{
                    scope = 'inner'
                }
                parameters = [ordered] @{
                    location = [ordered] @{
                        value = "[parameters('location')]"
                    }
                    dataCollectionRuleName = [ordered] @{
                        value = "[parameters('dataCollectionRuleName')]"
                    }
                    logAnalyticsWorkspaceResourceId = [ordered] @{
                        value = "[parameters('logAnalyticsWorkspaceResourceId')]"
                    }
                    workbookName = [ordered] @{
                        value = "[parameters('workbookName')]"
                    }
                    workbookDisplayName = [ordered] @{
                        value = "[parameters('workbookDisplayName')]"
                    }
                }
                template = $resourceGroupTemplate
            }
        }
    )
}

$template | ConvertTo-Json -Depth 100 | Set-Content -Path $OutputPath -Encoding utf8
Write-Host "Deployment template created at '$OutputPath'."