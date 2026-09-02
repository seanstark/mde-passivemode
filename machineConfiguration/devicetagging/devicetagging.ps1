Configuration devicetagging {
    Import-DscResource -ModuleName PSDscResources

    Node localhost {
        Registry devicetagging {
            Ensure    = 'Present'
            Key       = 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging'
            ValueName = 'Group'
            ValueData = 'DefaultDeviceTag'
            ValueType = 'String'
            Force     = $true
        }
    }
}
