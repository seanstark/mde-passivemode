[CmdletBinding()]
param(
    [Parameter()]
    [uri] $ContentUri,

    [Parameter()]
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),

    [Parameter()]
    [uri] $PolicySkeletonUri = 'https://github.com/seanstark/defenderforservers-tools/raw/refs/heads/main/machineConfiguration/mde-defender-mode/output/MdeDefenderModeConfig.zip',

    [Parameter()]
    [string] $ConfigurePolicyOutputPath = (Join-Path $PSScriptRoot '..\..\configureMDEdevicetagging.json')
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script requires PowerShell 7. Run it with 'pwsh', not Windows PowerShell ('powershell.exe')."
}

if ($IsWindows -and
    [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne
        [System.Runtime.InteropServices.Architecture]::X64) {
    throw 'Windows DSC configuration compilation requires an x64 PowerShell 7 process.'
}

$configurationName = 'defenderdevicetagging'
$packageVersion = '1.0.2'
$guestConfigurationRoleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/088ab73d-1256-47ae-bea9-9de8e7131f31'
$configurationPath = Join-Path $PSScriptRoot 'defenderdevicetagging.ps1'
$modulePath = Join-Path $PSScriptRoot 'Modules'
$compiledPath = Join-Path $OutputPath 'compiled'
$packagePath = Join-Path $OutputPath "$configurationName.zip"
$policyPath = Join-Path $OutputPath 'policies'

$requiredModules = @(
    @{ Name = 'GuestConfiguration'; MinimumVersion = '3.4.2' }
    @{ Name = 'PSDesiredStateConfiguration'; RequiredVersion = '2.0.7' }
)

foreach ($requiredModule in $requiredModules) {
    $availableModule = Get-Module -ListAvailable -Name $requiredModule.Name |
        Where-Object {
            (-not $requiredModule.MinimumVersion -or $_.Version -ge [version] $requiredModule.MinimumVersion) -and
            (-not $requiredModule.RequiredVersion -or $_.Version -eq [version] $requiredModule.RequiredVersion)
        } |
        Select-Object -First 1

    if (-not $availableModule) {
        throw "Required module '$($requiredModule.Name)' is not available with the required version."
    }
}

New-Item -ItemType Directory -Path $compiledPath -Force | Out-Null
$env:PSModulePath = "$modulePath$([System.IO.Path]::PathSeparator)$env:PSModulePath"
Import-Module PSDesiredStateConfiguration -RequiredVersion 2.0.7
Import-Module GuestConfiguration
. $configurationPath
defenderdevicetagging -OutputPath $compiledPath

$compiledMof = Join-Path $compiledPath 'localhost.mof'
$namedMof = Join-Path $compiledPath "$configurationName.mof"
Move-Item -Path $compiledMof -Destination $namedMof -Force

New-GuestConfigurationPackage `
    -Name $configurationName `
    -Configuration $namedMof `
    -Version $packageVersion `
    -Path $OutputPath `
    -Type AuditAndSet `
    -Force | Out-Host
$packageHash = (Get-FileHash -Path $packagePath -Algorithm SHA256).Hash

if (-not $ContentUri) {
    Write-Host "Package created at '$packagePath'."
    Write-Host 'Publish it to an HTTPS location, then rerun this script with -ContentUri to generate the policies.'
    return
}

if (-not $ContentUri.IsAbsoluteUri -or $ContentUri.Scheme -ne 'https') {
    throw "ContentUri must be an absolute HTTPS URL. Received: '$ContentUri'."
}

Remove-Item -Path $policyPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $policyPath -Force | Out-Null

$policyParameter = @(
    @{
        Name                 = 'DeviceTag'
        DisplayName          = 'Microsoft Defender for Endpoint device tag'
        Description          = 'Value written to the Group registry value. The value must contain no more than 200 characters.'
        ResourceType         = 'MdeDeviceTagging'
        ResourceId           = 'defenderdevicetagging'
        ResourcePropertyName = 'DeviceTag'
        DefaultValue         = 'DefaultDeviceTag'
    }
)

$commonPolicyParameters = @{
    ContentUri    = $PolicySkeletonUri.AbsoluteUri
    Platform      = 'Windows'
    PolicyVersion = $packageVersion
    Parameter     = $policyParameter
}

New-GuestConfigurationPolicy @commonPolicyParameters `
    -PolicyId 'ff037a13-f60c-41c5-943f-1345f4f7c06b' `
    -DisplayName 'Audit Microsoft Defender for Endpoint device tagging on Windows machines' `
    -Description 'Audits the Group device tag registry value by using Azure Machine Configuration.' `
    -Path (Join-Path $policyPath 'audit') `
    -Mode Audit | Out-Host

New-GuestConfigurationPolicy @commonPolicyParameters `
    -PolicyId '29b0f2de-9fbb-4bb1-9929-04b80b15edac' `
    -DisplayName 'Configure Microsoft Defender for Endpoint device tagging on Windows machines' `
    -Description 'Configures and autocorrects the Group device tag registry value by using Azure Machine Configuration.' `
    -Path (Join-Path $policyPath 'configure') `
    -Mode ApplyAndAutoCorrect | Out-Host

function Update-PolicyValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Value
    )

    if ($Value -is [string]) {
        return $Value.
            Replace($PolicySkeletonUri.AbsoluteUri, $ContentUri.AbsoluteUri).
            Replace('MdeDefenderModeConfig', $configurationName).
            Replace($skeletonContentHash, $packageHash)
    }

    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            $property.Value = Update-PolicyValue -Value $property.Value
        }
        return $Value
    }

    if ($Value -is [System.Collections.IList]) {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            $Value[$index] = Update-PolicyValue -Value $Value[$index]
        }
    }

    return $Value
}

$generatedPolicies = @(Get-ChildItem -Path $policyPath -Filter '*.json' -Recurse)
$renamedPolicies = @()
foreach ($generatedPolicy in $generatedPolicies) {
    $policy = Get-Content -Raw $generatedPolicy.FullName | ConvertFrom-Json -Depth 100
    $skeletonContentHash = $policy.properties.metadata.guestConfiguration.contentHash
    $policy = Update-PolicyValue -Value $policy
    $properties = $policy.properties

    $properties.metadata.guestConfiguration.contentUri = $ContentUri.AbsoluteUri
    $properties.metadata.guestConfiguration.contentHash = $packageHash
    $properties.metadata.guestConfiguration |
        Add-Member -NotePropertyName version -NotePropertyValue $packageVersion -Force

    $properties.parameters | Add-Member -NotePropertyName tagName -NotePropertyValue ([ordered] @{
        type = 'string'
        metadata = [ordered] @{
            displayName = 'Optional Azure tag name'
            description = 'Name of the Azure resource tag used to filter machines. Leave blank to include all eligible Windows machines.'
        }
        defaultValue = ''
    })
    $properties.parameters | Add-Member -NotePropertyName tagValue -NotePropertyValue ([ordered] @{
        type = 'string'
        metadata = [ordered] @{
            displayName = 'Optional Azure tag value'
            description = 'Required value for the Azure resource tag. Used only when a tag name is provided.'
        }
        defaultValue = ''
    })

    foreach ($parameterName in 'IncludeArcMachines', 'EnableAutoRemediation') {
        if ($properties.parameters.PSObject.Properties[$parameterName]) {
            $properties.parameters.$parameterName.defaultValue = 'true'
        }
    }

    foreach ($parameter in $properties.parameters.PSObject.Properties) {
        $parameterMetadata = $parameter.Value.metadata
        if ($parameterMetadata -is [System.Collections.IDictionary]) {
            $parameterMetadata['portalReview'] = 'true'
        }
        else {
            $parameterMetadata |
                Add-Member -NotePropertyName portalReview -NotePropertyValue 'true' -Force
        }
    }

    $machineEligibility = [ordered] @{
        anyOf = @(
            [ordered] @{
                allOf = @(
                    [ordered] @{
                        anyOf = @(
                            [ordered] @{ field = 'type'; equals = 'Microsoft.Compute/virtualMachines' },
                            [ordered] @{ field = 'type'; equals = 'Microsoft.Compute/virtualMachineScaleSets' }
                        )
                    },
                    [ordered] @{ field = "tags['aks-managed-orchestrator']"; exists = 'false' },
                    [ordered] @{ field = "tags['aks-managed-poolName']"; exists = 'false' },
                    [ordered] @{
                        anyOf = @(
                            [ordered] @{ field = 'Microsoft.Compute/virtualMachines/osProfile.windowsConfiguration'; exists = $true },
                            [ordered] @{ field = 'Microsoft.Compute/virtualMachines/storageProfile.osDisk.osType'; like = 'Windows*' },
                            [ordered] @{ field = 'Microsoft.Compute/VirtualMachineScaleSets/osProfile.windowsConfiguration'; exists = $true },
                            [ordered] @{ field = 'Microsoft.Compute/virtualMachineScaleSets/virtualMachineProfile.storageProfile.osDisk.osType'; like = 'Windows*' }
                        )
                    }
                )
            },
            [ordered] @{
                allOf = @(
                    [ordered] @{ value = "[parameters('IncludeArcMachines')]"; equals = 'true' },
                    [ordered] @{
                        anyOf = @(
                            [ordered] @{
                                allOf = @(
                                    [ordered] @{ field = 'type'; equals = 'Microsoft.HybridCompute/machines' },
                                    [ordered] @{ field = 'Microsoft.HybridCompute/machines/osType'; like = 'windows*' }
                                )
                            },
                            [ordered] @{
                                allOf = @(
                                    [ordered] @{ field = 'type'; equals = 'Microsoft.ConnectedVMwarevSphere/virtualMachines' },
                                    [ordered] @{ field = 'Microsoft.ConnectedVMwarevSphere/virtualMachines/osProfile.osType'; like = 'windows*' }
                                )
                            }
                        )
                    }
                )
            }
        )
    }
    $properties.policyRule.if = [ordered] @{
        allOf = @(
            [ordered] @{
                value = "[length(parameters('DeviceTag'))]"
                lessOrEquals = 200
            },
            $machineEligibility,
            [ordered] @{
                anyOf = @(
                    [ordered] @{
                        value = "[empty(parameters('tagName'))]"
                        equals = $true
                    },
                    [ordered] @{
                        field = "[concat('tags[', parameters('tagName'), ']')]"
                        equals = "[parameters('tagValue')]"
                    }
                )
            }
        )
    }

    $properties.metadata.requiredProviders = @($properties.metadata.requiredProviders)
    if ($properties.policyRule.then.effect -ne 'auditIfNotExists') {
        $properties.policyRule.then.details.roleDefinitionIds = @($guestConfigurationRoleDefinitionId)
    }

    $roleDefinitionIds = @($properties.policyRule.then.details.roleDefinitionIds | Where-Object { $_ })
    if ($roleDefinitionIds.Count -gt 0 -and
        @($roleDefinitionIds | Where-Object { $_ -notmatch '^/providers/Microsoft\.Authorization/roleDefinitions/[0-9a-fA-F-]{36}$' }).Count -gt 0) {
        throw "Generated policy contains an invalid roleDefinitionIds value: $($roleDefinitionIds -join ', ')."
    }
    foreach ($resource in @($properties.policyRule.then.details.deployment.properties.template.resources)) {
        $guestConfiguration = $resource.properties.guestConfiguration
        if ($null -eq $guestConfiguration) {
            continue
        }
        $guestConfiguration |
            Add-Member -NotePropertyName version -NotePropertyValue $packageVersion -Force
        if ($guestConfiguration.configurationParameter) {
            $guestConfiguration.configurationParameter = @($guestConfiguration.configurationParameter)
        }
    }

    $renamedPolicyPath = Join-Path $generatedPolicy.DirectoryName $generatedPolicy.Name.Replace('MdeDefenderModeConfig', $configurationName)
    $policy | ConvertTo-Json -Depth 100 | Set-Content -Path $renamedPolicyPath -Encoding utf8
    if ($renamedPolicyPath -ne $generatedPolicy.FullName) {
        Remove-Item -Path $generatedPolicy.FullName
    }
    $renamedPolicies += Get-Item $renamedPolicyPath
}

$configurePolicy = $renamedPolicies |
    Where-Object { $_.Name -like '*_DeployIfNotExists.json' } |
    Select-Object -First 1
if (-not $configurePolicy) {
    throw 'The generated ApplyAndAutoCorrect policy definition was not found.'
}

$generatedProperties = (Get-Content -Raw $configurePolicy.FullName | ConvertFrom-Json -Depth 100).properties
$portalPolicy = [ordered] @{
    mode       = $generatedProperties.mode
    metadata   = $generatedProperties.metadata
    parameters = $generatedProperties.parameters
    policyRule = $generatedProperties.policyRule
}
$portalPolicy | ConvertTo-Json -Depth 100 | Set-Content -Path $ConfigurePolicyOutputPath -Encoding utf8
Write-Host "Policy definitions created under '$policyPath'."
Write-Host "Portal-ready configure policy written to '$ConfigurePolicyOutputPath'."
