$registrySubKey = 'SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging'
$registryValueName = 'Group'

function Get-DeviceTag {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $baseKey = $null
    $registryKey = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $registryKey = $baseKey.OpenSubKey($registrySubKey)
        if ($null -eq $registryKey -or
            $registryKey.GetValueKind($registryValueName) -ne [Microsoft.Win32.RegistryValueKind]::String) {
            return ''
        }

        return [string] $registryKey.GetValue($registryValueName)
    }
    catch {
        return ''
    }
    finally {
        if ($null -ne $registryKey) {
            $registryKey.Dispose()
        }
        if ($null -ne $baseKey) {
            $baseKey.Dispose()
        }
    }
}

function Get-TargetResource {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $DeviceTag
    )

    return @{
        Name      = $Name
        DeviceTag = Get-DeviceTag
    }
}

function Test-TargetResource {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateLength(1, 200)]
        [string] $DeviceTag
    )

    return (Get-DeviceTag) -ceq $DeviceTag
}

function Set-TargetResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateLength(1, 200)]
        [string] $DeviceTag
    )

    $baseKey = $null
    $registryKey = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $registryKey = $baseKey.CreateSubKey($registrySubKey, $true)
        $registryKey.SetValue(
            $registryValueName,
            $DeviceTag,
            [Microsoft.Win32.RegistryValueKind]::String
        )
    }
    finally {
        if ($null -ne $registryKey) {
            $registryKey.Dispose()
        }
        if ($null -ne $baseKey) {
            $baseKey.Dispose()
        }
    }
}

Export-ModuleMember -Function Get-TargetResource, Test-TargetResource, Set-TargetResource
