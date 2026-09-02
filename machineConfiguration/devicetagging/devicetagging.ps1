Configuration devicetagging {
    Import-DscResource -ModuleName MdeDeviceTagging -ModuleVersion '1.0.0'

    Node localhost {
        MdeDeviceTagging devicetagging {
            Name      = 'Group'
            DeviceTag = 'DefaultDeviceTag'
        }
    }
}
