[CmdletBinding()]
param(
    [Parameter()]
    [uri] $ContentUri,

    [Parameter()]
    [string] $OutputPath = (Join-Path $PSScriptRoot 'output'),

    [Parameter()]
    [uri] $PolicySkeletonUri = 'https://github.com/seanstark/defenderforservers-tools/raw/refs/heads/main/machineConfiguration/mde-defender-mode/output/MdeDefenderModeConfig.zip',

    [Parameter()]
    [string] $ConfigurePolicyOutputPath = (Join-Path $PSScriptRoot '..\..\devicetagging.json')
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

$configurationName = 'devicetagging'
$configurationPath = Join-Path $PSScriptRoot 'devicetagging.ps1'
$compiledPath = Join-Path $OutputPath 'compiled'
$packagePath = Join-Path $OutputPath "$configurationName.zip"
$policyPath = Join-Path $OutputPath 'policies'

$requiredModules = @(
    @{ Name = 'GuestConfiguration'; MinimumVersion = '3.4.2' }
    @{ Name = 'PSDscResources'; MinimumVersion = '2.12.0' }
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
Import-Module GuestConfiguration
. $configurationPath
devicetagging -OutputPath $compiledPath

$compiledMof = Join-Path $compiledPath 'localhost.mof'
$namedMof = Join-Path $compiledPath "$configurationName.mof"
Move-Item -Path $compiledMof -Destination $namedMof -Force

New-GuestConfigurationPackage `
    -Name $configurationName `
    -Configuration $namedMof `
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
        ResourceType         = 'Registry'
        ResourceId           = 'devicetagging'
        ResourcePropertyName = 'ValueData'
        DefaultValue         = 'DefaultDeviceTag'
    }
)

$commonPolicyParameters = @{
    ContentUri    = $PolicySkeletonUri.AbsoluteUri
    Platform      = 'Windows'
    PolicyVersion = '1.0.0'
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

    $machineEligibility = $properties.policyRule.if
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

Copy-Item -Path $configurePolicy.FullName -Destination $ConfigurePolicyOutputPath -Force
Write-Host "Policy definitions created under '$policyPath'."
Write-Host "Configure policy copied to '$ConfigurePolicyOutputPath'."
