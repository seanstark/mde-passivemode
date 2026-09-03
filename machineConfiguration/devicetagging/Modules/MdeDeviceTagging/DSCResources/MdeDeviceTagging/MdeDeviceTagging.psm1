$registrySubKey = 'SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging'
$registryValueName = 'Group'

function Get-DeviceTagState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $baseKey = $null
    $registryKey = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        $registryKey = $baseKey.OpenSubKey($registrySubKey)
        if ($null -eq $registryKey) {
            return @{ Status = 'KeyNotPresent'; Value = ''; Type = '' }
        }

        $valueNames = @($registryKey.GetValueNames())
        if ($registryValueName -notin $valueNames) {
            return @{ Status = 'ValueNotPresent'; Value = ''; Type = '' }
        }

        $valueType = $registryKey.GetValueKind($registryValueName).ToString()
        $value = [string] $registryKey.GetValue($registryValueName)
        if ($valueType -ne [Microsoft.Win32.RegistryValueKind]::String.ToString()) {
            return @{ Status = 'WrongType'; Value = $value; Type = $valueType }
        }

        return @{ Status = 'Present'; Value = $value; Type = $valueType }
    }
    catch {
        return @{ Status = 'ReadError'; Value = ''; Type = ''; Error = $_.Exception.Message }
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

    $state = Get-DeviceTagState
    $reason = switch ($state.Status) {
        'KeyNotPresent' {
            @{
                Code = 'MdeDeviceTagging:MdeDeviceTagging:KeyNotPresent'
                Phrase = "Registry key HKEY_LOCAL_MACHINE\$registrySubKey is not present. Expected REG_SZ $registryValueName='$DeviceTag'."
            }
        }
        'ValueNotPresent' {
            @{
                Code = 'MdeDeviceTagging:MdeDeviceTagging:ValueNotPresent'
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName is not present. Expected REG_SZ value '$DeviceTag'."
            }
        }
        'WrongType' {
            @{
                Code = 'MdeDeviceTagging:MdeDeviceTagging:WrongType'
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName has type '$($state.Type)' and value '$($state.Value)'. Expected REG_SZ value '$DeviceTag'."
            }
        }
        'ReadError' {
            @{
                Code = 'MdeDeviceTagging:MdeDeviceTagging:ReadError'
                Phrase = "Unable to read HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName. $($state.Error)"
            }
        }
        default {
            $identifier = if ($state.Value -ceq $DeviceTag) { 'Compliant' } else { 'ValueMismatch' }
            @{
                Code = "MdeDeviceTagging:MdeDeviceTagging:$identifier"
                Phrase = "Registry value HKEY_LOCAL_MACHINE\$registrySubKey\$registryValueName is REG_SZ '$($state.Value)'. Expected '$DeviceTag'."
            }
        }
    }

    return @{
        Reasons = @($reason)
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

    $state = Get-DeviceTagState
    return $state.Status -eq 'Present' -and $state.Value -ceq $DeviceTag
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
