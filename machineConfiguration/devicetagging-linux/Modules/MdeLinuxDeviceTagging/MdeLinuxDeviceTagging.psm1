class MdeLinuxDeviceTaggingReason {
    [DscProperty()]
    [string] $Code

    [DscProperty()]
    [string] $Phrase
}

[DscResource()]
class MdeLinuxDeviceTagging {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [ValidateLength(1, 200)]
    [string] $DeviceTag

    [DscProperty(Mandatory)]
    [ValidateSet('Merge', 'Overwrite')]
    [string] $FileMode

    [DscProperty(NotConfigurable)]
    [MdeLinuxDeviceTaggingReason[]] $Reasons

    [MdeLinuxDeviceTagging] Get() {
        $current = [MdeLinuxDeviceTagging]::new()
        $current.Name = $this.Name
        $current.DeviceTag = $this.DeviceTag
        $current.FileMode = $this.FileMode
        $path = '/etc/opt/microsoft/mdatp/managed/mdatp_managed.json'

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $current.Reasons = @([MdeLinuxDeviceTaggingReason] @{
                Code = 'MdeLinuxDeviceTagging:FileMissing'
                Phrase = "Managed configuration '$path' does not exist. Expected GROUP tag '$($this.DeviceTag)' in $($this.FileMode) mode."
            })
            return $current
        }

        try {
            $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        }
        catch {
            $current.Reasons = @([MdeLinuxDeviceTaggingReason] @{
                Code = 'MdeLinuxDeviceTagging:ReadError'
                Phrase = "Managed configuration '$path' could not be read. Expected GROUP tag '$($this.DeviceTag)' in $($this.FileMode) mode. $($_.Exception.Message)"
            })
            return $current
        }

        try {
            $document = $content | ConvertFrom-Json -Depth 100 -ErrorAction Stop
            if ($null -eq $document) { throw 'The JSON document is null.' }
        }
        catch {
            $current.Reasons = @([MdeLinuxDeviceTaggingReason] @{
                Code = 'MdeLinuxDeviceTagging:InvalidJson'
                Phrase = "Managed configuration '$path' is not valid JSON. Expected GROUP tag '$($this.DeviceTag)' in $($this.FileMode) mode. $($_.Exception.Message)"
            })
            return $current
        }

        if ($null -eq $document.edr) {
            $code = 'MdeLinuxDeviceTagging:EdrMissing'
            $phrase = "Managed configuration '$path' has no edr object. Expected GROUP tag '$($this.DeviceTag)' in $($this.FileMode) mode."
        }
        elseif ($null -eq $document.edr.tags) {
            $code = 'MdeLinuxDeviceTagging:TagsMissing'
            $phrase = "Managed configuration '$path' has no edr.tags collection. Expected GROUP tag '$($this.DeviceTag)' in $($this.FileMode) mode."
        }
        else {
            $groupTags = @($document.edr.tags | Where-Object { $_.key -ceq 'GROUP' })
            if ($groupTags.Count -eq 0) {
                $code = 'MdeLinuxDeviceTagging:GroupTagMissing'
                $phrase = "Managed configuration '$path' has no GROUP tag. Expected '$($this.DeviceTag)' in $($this.FileMode) mode."
            }
            elseif ($groupTags.Count -gt 1) {
                $code = 'MdeLinuxDeviceTagging:DuplicateGroupTags'
                $phrase = "Managed configuration '$path' has $($groupTags.Count) GROUP tags. Expected exactly one with value '$($this.DeviceTag)' in $($this.FileMode) mode."
            }
            elseif ([string] $groupTags[0].value -cne $this.DeviceTag) {
                $code = 'MdeLinuxDeviceTagging:GroupTagMismatch'
                $phrase = "Managed configuration '$path' has GROUP tag '$([string] $groupTags[0].value)'. Expected '$($this.DeviceTag)' in $($this.FileMode) mode."
            }
            elseif ($this.FileMode -eq 'Overwrite') {
                $rootProperties = @($document.PSObject.Properties.Name)
                $edrProperties = @($document.edr.PSObject.Properties.Name)
                if ($rootProperties.Count -ne 1 -or $rootProperties[0] -ne 'edr' -or
                    $edrProperties.Count -ne 1 -or $edrProperties[0] -ne 'tags' -or
                    @($document.edr.tags).Count -ne 1) {
                    $code = 'MdeLinuxDeviceTagging:UnexpectedContent'
                    $phrase = "Managed configuration '$path' contains content other than the single expected GROUP tag '$($this.DeviceTag)'. Overwrite mode requires an exact document match."
                }
                else {
                    $code = 'MdeLinuxDeviceTagging:Compliant'
                    $phrase = "Managed configuration '$path' contains the expected GROUP tag '$($this.DeviceTag)' and is compliant in Overwrite mode."
                }
            }
            else {
                $code = 'MdeLinuxDeviceTagging:Compliant'
                $phrase = "Managed configuration '$path' contains the expected GROUP tag '$($this.DeviceTag)' and is compliant in Merge mode."
            }
        }

        $current.Reasons = @([MdeLinuxDeviceTaggingReason] @{ Code = $code; Phrase = $phrase })
        return $current
    }

    [bool] Test() {
        $current = $this.Get()
        return $current.Reasons.Count -eq 1 -and $current.Reasons[0].Code -eq 'MdeLinuxDeviceTagging:Compliant'
    }

    [void] Set() {
        $managedDirectory = '/etc/opt/microsoft/mdatp/managed'
        $managedFilePath = '/etc/opt/microsoft/mdatp/managed/mdatp_managed.json'

        if ($this.FileMode -eq 'Overwrite') {
            $document = [ordered] @{
                edr = [ordered] @{
                    tags = @([ordered] @{ key = 'GROUP'; value = $this.DeviceTag })
                }
            }
        }
        else {
            if (Test-Path -LiteralPath $managedFilePath -PathType Leaf) {
                try {
                    $content = Get-Content -LiteralPath $managedFilePath -Raw -ErrorAction Stop
                    $document = $content | ConvertFrom-Json -Depth 100 -ErrorAction Stop
                    if ($null -eq $document) { throw 'The JSON document is null.' }
                }
                catch {
                    throw "The existing MDE managed configuration at '$managedFilePath' cannot be merged. $($_.Exception.Message)"
                }
            }
            else {
                $document = [pscustomobject] @{}
            }

            if ($null -eq $document.edr) {
                $document | Add-Member -NotePropertyName edr -NotePropertyValue ([pscustomobject] @{}) -Force
            }
            $tags = if ($null -eq $document.edr.tags) { @() } else { @($document.edr.tags) }
            $tags = @($tags | Where-Object { $_.key -cne 'GROUP' })
            $tags += [pscustomobject] @{ key = 'GROUP'; value = $this.DeviceTag }
            $document.edr | Add-Member -NotePropertyName tags -NotePropertyValue $tags -Force
        }

        New-Item -ItemType Directory -Path $managedDirectory -Force | Out-Null
        $temporaryPath = Join-Path $managedDirectory ".mdatp_managed.$([guid]::NewGuid()).tmp"
        try {
            $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
            Move-Item -LiteralPath $temporaryPath -Destination $managedFilePath -Force
            & chmod 640 $managedFilePath
            if ($LASTEXITCODE -ne 0) { throw "chmod failed with exit code $LASTEXITCODE." }
            & chown root:root $managedFilePath
            if ($LASTEXITCODE -ne 0) { throw "chown failed with exit code $LASTEXITCODE." }
        }
        finally {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}