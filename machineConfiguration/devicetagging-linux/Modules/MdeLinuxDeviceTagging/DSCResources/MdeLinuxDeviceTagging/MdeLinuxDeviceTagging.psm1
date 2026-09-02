$managedDirectory = '/etc/opt/microsoft/mdatp/managed'
$managedFilePath = Join-Path $managedDirectory 'mdatp_managed.json'

function Read-ManagedDocument {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch] $ThrowOnInvalid
    )

    if (-not (Test-Path -LiteralPath $managedFilePath -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $managedFilePath -Raw | ConvertFrom-Json -Depth 100
    }
    catch {
        if ($ThrowOnInvalid) {
            throw "The existing MDE managed configuration at '$managedFilePath' is not valid JSON. Merge mode will not replace it. $($_.Exception.Message)"
        }
        return $null
    }
}

function Get-GroupTags {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Document
    )

    if ($null -eq $Document -or $null -eq $Document.edr -or $null -eq $Document.edr.tags) {
        return @()
    }

    return @($Document.edr.tags | Where-Object { $_.key -ceq 'GROUP' })
}

function Test-OverwriteDocument {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Document,

        [Parameter(Mandatory)]
        [string] $DeviceTag
    )

    if ($null -eq $Document) {
        return $false
    }

    $rootProperties = @($Document.PSObject.Properties.Name)
    $edrProperties = @($Document.edr.PSObject.Properties.Name)
    $tags = @(Get-GroupTags -Document $Document)

    return $rootProperties.Count -eq 1 -and
        $rootProperties[0] -eq 'edr' -and
        $edrProperties.Count -eq 1 -and
        $edrProperties[0] -eq 'tags' -and
        @($Document.edr.tags).Count -eq 1 -and
        $tags.Count -eq 1 -and
        [string] $tags[0].value -ceq $DeviceTag
}

function Get-TargetResource {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $DeviceTag,

        [Parameter(Mandatory)]
        [ValidateSet('Merge', 'Overwrite')]
        [string] $FileMode
    )

    $document = Read-ManagedDocument
    $groupTag = @(Get-GroupTags -Document $document) | Select-Object -First 1

    return @{
        Name      = $Name
        DeviceTag = if ($groupTag) { [string] $groupTag.value } else { '' }
        FileMode  = $FileMode
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
        [string] $DeviceTag,

        [Parameter(Mandatory)]
        [ValidateSet('Merge', 'Overwrite')]
        [string] $FileMode
    )

    $document = Read-ManagedDocument
    if ($FileMode -eq 'Overwrite') {
        return Test-OverwriteDocument -Document $document -DeviceTag $DeviceTag
    }

    $groupTags = @(Get-GroupTags -Document $document)
    return $groupTags.Count -eq 1 -and [string] $groupTags[0].value -ceq $DeviceTag
}

function Set-TargetResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateLength(1, 200)]
        [string] $DeviceTag,

        [Parameter(Mandatory)]
        [ValidateSet('Merge', 'Overwrite')]
        [string] $FileMode
    )

    if ($FileMode -eq 'Overwrite') {
        $document = [ordered] @{
            edr = [ordered] @{
                tags = @(
                    [ordered] @{
                        key   = 'GROUP'
                        value = $DeviceTag
                    }
                )
            }
        }
    }
    else {
        $document = Read-ManagedDocument -ThrowOnInvalid
        if ($null -eq $document) {
            $document = [pscustomobject] @{}
        }
        if ($null -eq $document.edr) {
            $document | Add-Member -NotePropertyName edr -NotePropertyValue ([pscustomobject] @{}) -Force
        }

        $tags = if ($null -eq $document.edr.tags) { @() } else { @($document.edr.tags) }
        $tags = @($tags | Where-Object { $_.key -cne 'GROUP' })
        $tags += [pscustomobject] @{
            key   = 'GROUP'
            value = $DeviceTag
        }
        $document.edr | Add-Member -NotePropertyName tags -NotePropertyValue $tags -Force
    }

    New-Item -ItemType Directory -Path $managedDirectory -Force | Out-Null
    $temporaryPath = Join-Path $managedDirectory ".mdatp_managed.$([guid]::NewGuid()).tmp"

    try {
        $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
        Move-Item -LiteralPath $temporaryPath -Destination $managedFilePath -Force
        & chmod 640 $managedFilePath
        if ($LASTEXITCODE -ne 0) {
            throw "chmod failed with exit code $LASTEXITCODE."
        }
        & chown root:root $managedFilePath
        if ($LASTEXITCODE -ne 0) {
            throw "chown failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-TargetResource, Test-TargetResource, Set-TargetResource
