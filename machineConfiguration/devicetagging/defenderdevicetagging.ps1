Configuration defenderdevicetagging {
    Import-DscResource -ModuleName MdeDeviceTagging -ModuleVersion '1.0.1'

    Node localhost {
        MdeDeviceTagging defenderdevicetagging {
            Name      = 'Group'
            DeviceTag = 'DefaultDeviceTag'
        }
    }
}