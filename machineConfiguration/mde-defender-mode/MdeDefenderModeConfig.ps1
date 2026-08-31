Configuration MdeDefenderModeConfig {
    Import-DscResource -ModuleName MdeDefenderMode -ModuleVersion '1.0.1'

    MdeDefenderMode DefenderForEndpointMode {
        Name = 'ForceDefenderPassiveMode'
        Mode = 'Active'
    }
}