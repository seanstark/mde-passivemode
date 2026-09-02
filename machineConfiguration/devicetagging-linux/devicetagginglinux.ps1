Configuration devicetagginglinux {
    Import-DscResource -ModuleName MdeLinuxDeviceTagging -ModuleVersion '1.0.0'

    Node localhost {
        MdeLinuxDeviceTagging devicetagginglinux {
            Name      = 'mdatp_managed.json'
            DeviceTag = 'DefaultDeviceTag'
            FileMode  = 'Merge'
        }
    }
}
