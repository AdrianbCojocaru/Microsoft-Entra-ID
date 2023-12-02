<#PSScriptInfo

.VERSION 1.0

.DATE 02-Jul-2023

.AUTHOR adrian.cojocaru

#>

<#
  .SYNOPSIS
  Updates an the membership of destination (device) Azure AD device groups based of a membership of source (user) groups.

  .DESCRIPTION
  Name and AzureAD Object IDs for the device & user group are defined inside teh configuration file (JSON format). See Set-DeviceGroupsFromUserGroups.json
  The script will first check if the Id matches the name of each group (safeguard).
  Then the membership of the DeviceAzureADGroupId will be updated with the devices owned by users in UserAzureADGroupId.
  The scipt gets all tthe devices in the destination (devcies) group and all the devices owned by all users in the source (user) group.
  Then it updates the destination group with the difference.
  e.g if a user is added to the UserAzureADGroupId then the script will add their devices to the DeviceAzureADGroupId
  if a user is removed from the UserAzureADGroupId then the script will remove their devices from the DeviceAzureADGroupId
  App registration permissions:
  Microsoft Graph (3)	
    Device.Read.All
    GroupMember.ReadWrite.All
    User.Read.All 

  .INPUTS
  If your script accepts pipeline input, describe it here.

  .OUTPUTS
  output generated by your script. If any.

  .EXAMPLE
  .\Set-DeviceGroupsFromUserGroups.ps1

#>


#Region ----------------------------------------------------- [AzureAD Variables] ----------------------------------------------
[string]$ApplicationId = if ($env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) { Get-AutomationVariable -Name "DWC-EUD-Automation_AppId" } else { $env:MyCompanyAppClientId }
#[string]$ApplicationSecret = if ($env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) { Get-AutomationVariable -Name "DWC-EUD-Automation_AppSecret" } else { $env:MyCompanyDefenderAppSecret }
[string]$Thumbprint = if ($env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) { Get-AutomationVariable -Name "DWC-EUD-Automation_CertThumbprint" } else { $env:MyCompanyAppCertThumbprint }
[string]$TenantId = if ($env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) { Get-AutomationVariable -Name "TenantId" } else { $env:MyCompanyTenantId }
[string]$JsonPath = if ($env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) { Get-AutomationVariable -Name "AdvancedHuntingJsonSAS" } else { $env:AdvancedHuntingJsonSAS }
#EndRegion -------------------------------------------------- [AzureAD Variables] ----------------------------------------------
#Region ----------------------------------------------------- [Script Variables] ----------------------------------------------
[version]$ScriptVersion = [version]'1.0.0'
$Global:GraphTokenRefreshLimit = 24
$Global:GraphTokenRefreshCount = 0
$Global:GatewayTimeoutCountLimit = 24
$Global:GatewayTimeoutCount = 0
$Global:ExitCode = 0
$VerbosePreference = "SilentlyContinue"
$TimeStamp = get-date -Format yyyyMMddTHHmmss
#EndRegion -------------------------------------------------- [Script Variables] ----------------------------------------------
#Region ----------------------------------------------------- [Classes] ----------------------------------------------
class CustomException : Exception {
    <#

    .DESCRIPTION
    Used to throw exceptions.
    .EXAMPLE
    throw [CustomException]::new( "Get-ErrorOne", "This will cause the script to end with ExitCode 101")

#>
    [string] $additionalData

    CustomException($Message, $additionalData) : base($Message) {
        $this.additionalData = $additionalData
    }
}
class CustomQueryException : Exception {
    [string] $additionalData

    CustomQueryException($Message, $additionalData) : base($Message) {
        $this.additionalData = $additionalData
    }
}
#EndRegion ----------------------------------------------------- [Classes] ----------------------------------------------
#Region -------------------------------------------------------- [Functions] ----------------------------------------------
Function Write-LogRunbook {
    <#

    .DESCRIPTION
    Write messages to a log file defined by $LogPath and also display them in the console.
    Message format: [Date & Time] [CallerInfo] :: Message Text

#>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message string.
        [string]$Message,
        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateNotNull()]
        # Optional. Specifies the name of the message writter. Function, command or custom name. Defaults to FunctioName or unknown
        [string]$Caller = 'Unknown'
    )
    Begin {
        [string]$LogDate = (Get-Date -Format 'MM-dd-yyyy').ToString()
        [string]$LogTime = (Get-Date -Format 'HH\:mm\:ss.fff').ToString()
    }
    Process {
        "[$LogDate $LogTime] [${Caller}] :: $Message" | Write-Verbose -Verbose  
    }
    End {}
}

function Write-ErrorRunbook {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [AllowEmptyCollection()]
        # Optional. The errorr collection.
        [array]$ErrorRecord
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        If (-not $ErrorRecord) {
            If ($global:Error.Count -eq 0) {
                Return
            }
            Else {
                [array]$ErrorRecord = $global:Error[0]
            }
        }
    }
    Process {
        $ErrorRecord | ForEach-Object {
            $errNumber = $ErrorRecord.count - $( $ErrorRecord.IndexOf($_))
            $ErrorText = "[${CmdletName} Nr. $errNumber] :: $($($_.Exception).Message)`n" + `
                ">>> Line: $($($_.InvocationInfo).ScriptLineNumber) Char: $($($_.InvocationInfo).OffsetInLine) <<<`n" + `
                "$($($_.InvocationInfo).Line)" 
            $ErrorText | Write-Error
        }
    }
    End {}
}
function Get-Token {
    <#
  .DESCRIPTION
  Get Authentication token from Microsoft Graph (default) or Threat Protection.
  Authentication can be done with a Certificate  Thumbprint (default) or ApplicationId Id & ApplicationSecret.
  $Thumbprint variable needs to be initialized before calling the function
  For ApplicationId & ApplicationSecret the $ApplicationId & $ApplicationSecret variables need to be initialized before calling the function.
 .Example
   Get a token for Graph using certificate thumbprint (default behaviour)
   Get-Token
 .Example
   Get a token for Defender's ThreatProtection using certificate thumbprint
   Get-Token -ThreatProtection
 .Example
   Get a token for Defender's ThreatProtection using ApplicationId & ApplicationSecret
   For ApplicationId & ApplicationSecret the variables need to be defined before calling the function: $ApplicationId & $ApplicationSecret
   Get-Token -ThreatProtection -AppIdSecret
#>
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [switch]$ThreatProtection,
        [Parameter(Mandatory = $false, Position = 1)]
        [switch]$AppIdSecret
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        $PSBoundParameters.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Key) = $($_.Value)" | Write-LogRunbook -Caller $CmdletName }
    }
    End {
        try {
            $url = if ($ThreatProtection) { 'https://api.security.microsoft.com' } else { 'https://graph.microsoft.com' }
            Write-LogRunbook "url = $url" -Caller $CmdletName
            if ($AppIdSecret) {
                $body = [Ordered] @{
                    grant_type    = 'client_credentials'
                    client_id     = $ApplicationId
                    client_secret = $ApplicationSecret  
                }
                if ($ThreatProtection) {
                    $oAuthUrl = "https://login.windows.net/$TenantId/oauth2/token"
                    $body.Add('resource', $url)
                }
                else {
                    $oAuthUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" 
                    $body.Add('scope', $url + '/.default')
                }
                Write-LogRunbook "oAuthUrl = $oAuthUrl" -Caller $CmdletName
                [string]$Token = (Invoke-RestMethod -Method Post -Uri $oAuthUrl -Body $body -ErrorAction Stop).access_token
            }
            else {
                # certificate auth
                if (-not (Get-AzContext)) {
                    Write-LogRunbook "No AzContext. Running Connect-AzAccount" -Caller $CmdletName
                    Connect-AzAccount -CertificateThumbprint $Thumbprint -ApplicationId $ApplicationId -Tenant $TenantId -ServicePrincipal
                }
                [string]$Token = (Get-AzAccessToken -ResourceUrl $url).Token
            }
            $Token
        }
        catch {
            Write-ErrorRunbook
            throw [CustomException]::new( $CmdletName, "Error calling https://api.security.microsoft.com")
        }
    }
}
function Get-JsonContent {
    param (
        [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message string.
        [string]$JsonFilePath,
        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message string.
        [switch]$Web
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        $PSBoundParameters.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Key) = $($_.Value)" | Write-LogRunbook -Caller $CmdletName }
    }
    End {
        try {
            if ($Web) {
                Invoke-RestMethod $JsonFilePath -ErrorAction Stop
            }
            else {
                if (Test-Path $JsonPath) {
                    Get-Content $JsonPath -Raw | ConvertFrom-Json 
                }
                else { throw "File not found: $JsonPath" }
            }
        }
        catch {
            Write-ErrorRunbook
            throw [CustomException]::new( $CmdletName, "Error calling json url")
        }
    }
    
}

function  Test-AADGroup {
    <#
  .DESCRIPTION
  Check if the AzureAD group exists and the Id matches the name.
  This is a safeguard in case of mistakes in the config file
 .Example
   Test-AADGroup -GroupId '0ed6c216-dde9-4a06-83fe-923f1e42c86a' -GroupName 'TestAADGroup1'
#>
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message string.
        [string]$GroupId,
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message string.
        [string]$GroupName
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        $PSBoundParameters.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Key) = $($_.Value)" | Write-LogRunbook -Caller $CmdletName }
    }
    End {
        try {
            $headers = @{ 'Authorization' = "Bearer $Token_Graph" }
            $url = "https://graph.microsoft.com/v1.0/groups/$GroupId"
            $response = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing -ErrorAction Stop
            $GroupInfo = $response.Content | ConvertFrom-Json
            #check this when the group will have a few members..
            if ($GroupInfo.displayName -eq $GroupName) {
                Write-LogRunbook 'Group Name & Id match.' -Caller $CmdletName
                return $true
            }
            else {
                Write-LogRunbook "The provided Group name: '$GroupName' doesn't match the actual Group display name: '$($GroupInfo.displayName)' for GroupId: '$GroupId'." -Caller $CmdletName
                return $false
            }
        }
        catch {
            switch ($_.Exception.Response.StatusCode) {
                'Unauthorized' {
                    if ($Global:GraphTokenRefreshCount -lt $Global:GraphTokenRefreshLimit) {
                        Write-LogRunbook "Token expired. Getting a new one. GraphTokenRefreshCount: '$Global:GraphTokenRefreshCount'" -Caller $CmdletName
                        $global:Token_Graph = Get-Token
                        $Global:GraphTokenRefreshCount++
                        Test-AADGroup @PSBoundParameters
                    }
                    else {
                        Write-ErrorRunbook
                        throw [CustomException]::new( $CmdletName, "GraphTokenRefreshLimit '$Global:GraphTokenRefreshCount' reached! ")
                    }
                }
                'NotFound' { 
                    Write-LogRunbook "AzureAD object not found." -Caller $CmdletName
                }
                Default {
                    Write-ErrorRunbook
                    throw [CustomException]::new( $CmdletName, "$($response.StatusCode) StatusCode calling '$url'")
                }
            }
        }
    } 
}

function Get-AADTransitiveGroupMembers {
    <#
.DESCRIPTION
  Returns a flat list of all nested users that are members of an AzureAD group.
  Either users or devices. The other types will probably also work but it is yet to be tested.

.PARAMETER MemberType
  The values for this parameetr can only be microsoft.graph.device or microsoft.graph.user
  The other types will probably also work but it is yet to be tested.

.Example
   Get-AADTransitiveGroupMembers -AADGroupObjectId 'wwwwwwwww' -MemberType 'microsoft.graph.device'

.Example
   Get-AADTransitiveGroupMembers -AADGroupObjectId 'wwwwwwwww' -MemberType 'microsoft.graph.user'
#>
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message Object id of the Azure AD group.
        [string]$AADGroupObjectId,
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $false)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message Object id of the Azure AD group.
        [string][ValidateSet('microsoft.graph.device', 'microsoft.graph.user')]$MemberType
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        #$AlreadyAddedList = [System.Collections.ArrayList]::new()
        $MembersList = @()
    }
    Process {
        try {
            $PSBoundParameters.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Key) = $($_.Value)" | Write-LogRunbook -Caller $CmdletName }
            $headers = @{
                Authorization  = "Bearer $Token_Graph"
                "Content-type" = "application/json"
            }
            #$url1 = "https://graph.microsoft.com/v1.0/groups/$AADGroupObjectId/transitiveMembers?`$filter=isof('microsoft.graph.user')"
            $url = "https://graph.microsoft.com/v1.0/groups/$AADGroupObjectId/transitiveMembers/$MemberType`?`$select=id"
            $responseGR = Invoke-RestMethod -Headers $headers -Uri $url -Method Get -ErrorAction Stop
            if ($responseGR.value) { $MembersList += $responseGR.value }
            while ($responseGR.'@odata.nextLink') {
                $responseGR = Invoke-RestMethod -Headers $headers -Uri $responseGR.'@odata.nextLink' -Method Get -ErrorAction Stop
                if ($responseGR.value) { $MembersList += $responseGR.value }
            }
            $MembersList.id
        }
        catch {
            switch ($_.Exception.Response.StatusCode) {
                'Unauthorized' {
                    if ($Global:GraphTokenRefreshCount -lt $Global:GraphTokenRefreshLimit) {
                        Write-LogRunbook "Token expired. Getting a new one. GraphTokenRefreshCount: '$Global:GraphTokenRefreshCount'" -Caller $CmdletName
                        $global:Token_Graph = Get-GraphToken
                        $Global:GraphTokenRefreshCount++
                        Get-AADTransitiveGroupMembers @PSBoundParameters
                    }
                    else {
                        Write-ErrorRunbook
                        throw [CustomException]::new( $CmdletName, "GraphTokenRefreshLimit '$Global:GraphTokenRefreshCount' reached! ")
                    }
                }
                'NotFound' { 
                    Write-LogRunbook "AzureAD object not found." -Caller $CmdletName
                }
                Default {
                    Write-ErrorRunbook
                    throw [CustomException]::new( $CmdletName, "$($response.StatusCode) StatusCode calling '$url'")
                }
            }
        }
    }
    End {
        # Write-Log "Ended" -Caller $CmdletName
    }
}
function Get-AADUserOwnedDevices {
    <#
  .DESCRIPTION
  Returns a flat list of all owned by an AzureAD user

 .Example
   Get-AADTransitiveGroupMembers -AADGroupId 'wwwwwwwww'
#>
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message Object id of the Azure AD group.
        [string]$AADUserObjectId,
        [Parameter(Mandatory = $false, Position = 1, ValueFromPipeline = $false)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message Object id of the Azure AD group.
        [string[]]$OSes,
        [Parameter(Mandatory = $false, Position = 2, ValueFromPipeline = $false)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message Object id of the Azure AD group.
        [string[]]$trustTypes,
        [Parameter(Mandatory = $false, Position = 3, ValueFromPipeline = $false)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message Object id of the Azure AD group.
        [string]$isCompliant = "Yes,No",
        [Parameter(Mandatory = $false, Position = 4, ValueFromPipeline = $false)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message Object id of the Azure AD group.
        [string]$accountEnabled = "Yes,No"
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        #$AlreadyAddedList = [System.Collections.ArrayList]::new()
    }
    Process {
        $MembersList = @()
        try {
            $PSBoundParameters.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Key) = $($_.Value)" | Write-LogRunbook -Caller $CmdletName }
            $headers = @{
                Authorization  = "Bearer $Token_Graph"
                "Content-type" = "application/json"
            }
            #$url1 = "https://graph.microsoft.com/v1.0/groups/$AADGroupId/transitiveMembers?`$filter=isof('microsoft.graph.user')"
            $url = "https://graph.microsoft.com/v1.0/users/$AADUserObjectId/ownedDevices?`$select=id,displayName,operatingSystem,deviceId,trustType,profileType,managementType,enrollmentType,isCompliant,accountEnabled"
            
            #"https://graph.microsoft.com/v1.0/users/$AADUserObjectId/ownedDevices?`$filter=operatingSystem eq 'Windows'"
            #The specified filter to the reference property query is currently not supported."
            $responseGR = Invoke-RestMethod -Headers $headers -Uri $url -Method Get -ErrorAction Stop
            if ($responseGR.value) {
                if ($OSes.count) {
                    $MembersList += $responseGR.value | Where-Object -Property operatingSystem -in -value $OSes
                }
                else {
                    $MembersList += $responseGR.value 
                }
                if (($trustTypes.count -eq 1) -or ($trustTypes.count -eq 2)) {
                    $MembersList = $MembersList | Where-Object -Property trustType -in -value $trustTypes
                }
                switch ($accountEnabled) {
                    'Yes' {
                        switch ($isCompliant) {
                            'Yes' { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'Yes' -and $_.isCompliant -eq 'Yes' } }
                            'No'  { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'Yes' -and $_.isCompliant -eq 'No' } }
                            default { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'Yes' } }
                        }
                    }
                    'No' {
                        switch ($isCompliant) {
                            'Yes' { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'No' -and $_.isCompliant -eq 'Yes' } }
                            'No'  { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'No' -and $_.isCompliant -eq 'No' } }
                            default { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'No' } }
                        }
                    }
                    default {
                        switch ($isCompliant) {
                            'Yes' { $MembersList = $MembersList | Where-Object { $_.isCompliant -eq 'Yes' } }
                            'No'  { $MembersList = $MembersList | Where-Object { $_.isCompliant -eq 'No' } }
                            default { }
                        }
                    }
                }
            }
            while ($responseGR.'@odata.nextLink') {
                Write-Output "Please check @odata.nextLink for user $AADUserObjectId"
                $responseGR = Invoke-RestMethod -Headers $headers -Uri $responseGR.'@odata.nextLink' -Method Get -ErrorAction Stop
                if ($responseGR.value) {
                    if ($OSes.count) {
                        $MembersList += $responseGR.value | Where-Object -Property operatingSystem -in -value $OSes
                    }
                    else {
                        $MembersList += $responseGR.value 
                    }
                    if (($trustTypes.count -eq 1) -or ($trustTypes.count -eq 2)) {
                        $MembersList = $MembersList | Where-Object -Property trustType -in -value $trustTypes
                    }
                    switch ($accountEnabled) {
                        'Yes' {
                            switch ($isCompliant) {
                                'Yes' { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'Yes' -and $_.isCompliant -eq 'Yes' } }
                                'No'  { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'Yes' -and $_.isCompliant -eq 'No' } }
                                default { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'Yes' } }
                            }
                        }
                        'No' {
                            switch ($isCompliant) {
                                'Yes' { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'No' -and $_.isCompliant -eq 'Yes' } }
                                'No'  { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'No' -and $_.isCompliant -eq 'No' } }
                                default { $MembersList = $MembersList | Where-Object { $_.accountEnabled -eq 'No' } }
                            }
                        }
                        default {
                            switch ($isCompliant) {
                                'Yes' { $MembersList = $MembersList | Where-Object { $_.isCompliant -eq 'Yes' } }
                                'No'  { $MembersList = $MembersList | Where-Object { $_.isCompliant -eq 'No' } }
                                default { }
                            }
                        }
                    }
                }
            }
            $MembersList
        }
        catch {
            switch ($_.Exception.Response.StatusCode) {
                'Unauthorized' {
                    if ($Global:GraphTokenRefreshCount -lt $Global:GraphTokenRefreshLimit) {
                        Write-LogRunbook "Token expired. Getting a new one. GraphTokenRefreshCount: '$Global:GraphTokenRefreshCount'" -Caller $CmdletName
                        $global:Token_Graph = Get-GraphToken
                        $Global:GraphTokenRefreshCount++
                        Get-AADUserOwnedDevices @PSBoundParameters
                    }
                    else {
                        Write-ErrorRunbook
                        throw [CustomException]::new( $CmdletName, "GraphTokenRefreshLimit '$Global:GraphTokenRefreshCount' reached! ")
                    }
                }
                'NotFound' { 
                    Write-LogRunbook "AzureAD object not found." -Caller $CmdletName
                }
                Default {
                    Write-ErrorRunbook
                    throw [CustomException]::new( $CmdletName, "$($response.StatusCode) StatusCode calling '$url'")
                }
            }
        }
    }
    End {
        # Write-Log "Ended" -Caller $CmdletName
    }
}
function  Add-AADGroupMembers {
    <#

.DESCRIPTION
  Adds one or more members to an AzureAD group.

.PARAMETER MemberType
  One or more AzureAD Object IDs that you want added.
  Careful what you put here :)
#>
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $false)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message string.
        [string]$AADGroupObjectId,
        [Parameter(Mandatory = $true, Position = 1, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. One or more AzureAD Object IDs that you want added.
        [string[]]$AADObjectIds
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        $PSBoundParameters.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Key) = $($_.Value)" | Write-LogRunbook -Caller $CmdletName }
        #$urlref = "https://graph.microsoft.com/v1.0/groups/$AADGroupObjectId/members/`$ref"
        $urlMultiObj = "https://graph.microsoft.com/v1.0/groups/$AADGroupObjectId"
        $headers = @{
            Authorization  = "Bearer $Token_Graph"
            "Content-type" = "application/json"
        }
    }
    Process {
        #Write-LogRunbook "Next batch of ObjectIds:" -Caller $CmdletName # comment this later on
        #$ObjectIds | Out-String | Write-LogRunbook -Caller $CmdletName # comment this later on
    }
    End {
        try {
            #Note that up to 20 members can be added in a single request
            # https://learn.microsoft.com/en-us/graph/api/group-post-members?view=graph-rest-1.0&tabs=http
            $CurrentCount = 0
            $ObjIdsToBeAdded = New-Object System.Collections.Generic.List[System.Object]
            $AADObjectIds | ForEach-Object { $ObjIdsToBeAdded.Add("https://graph.microsoft.com/v1.0/directoryObjects/$_") }
            while ($CurrentCount -lt $AADObjectIds.count) {
                $body = @{}
                # A maximum of 20 objects can be added in a single request
                $NewCount = $CurrentCount + 19
                Write-LogRunbook "Batch of objects to be added:" -Caller $CmdletName
                $ObjIdsToBeAdded[$CurrentCount..$NewCount] | Out-String | Write-LogRunbook -Caller $CmdletName   
                $body.Add("members@odata.bind", $ObjIdsToBeAdded[$CurrentCount..$NewCount])
                $bodyJSON = $body | ConvertTo-Json
                $response = Invoke-RestMethod -Headers $headers -Uri $urlMultiObj -Method Patch -Body $bodyJSON -ErrorAction Stop
                #Write-LogRunbook "$($AADObjectIds.count) objects added. StatusCode = $($response.StatusCode)" -Caller $CmdletName
                Write-LogRunbook "Objects successfully added." -Caller $CmdletName
                $CurrentCount = $NewCount + 1
            }
        }
        catch {
            switch ($_.Exception.Response.StatusCode) {
                'Unauthorized' {
                    if ($Global:GraphTokenRefreshCount -lt $Global:GraphTokenRefreshLimit) {
                        Write-LogRunbook "Token expired. Getting a new one. GraphTokenRefreshCount: '$Global:GraphTokenRefreshCount'" -Caller $CmdletName
                        $global:Token_Graph = Get-Token
                        $Global:GraphTokenRefreshCount++
                        Add-AADGroupMembers @PSBoundParameters
                    }
                    else {
                        Write-ErrorRunbook
                        throw [CustomException]::new( $CmdletName, "GraphTokenRefreshLimit '$Global:GraphTokenRefreshCount' reached! ")
                    }
                }
                'NotFound' { 
                    Write-LogRunbook "AzureAD object not found." -Caller $CmdletName
                }
                Default {
                    Write-ErrorRunbook
                    throw [CustomException]::new( $CmdletName, "$($response.StatusCode) StatusCode calling '$url'")
                }
            }
        }
    }
}
function  Remove-AADDirectGroupMember {
    <#

.DESCRIPTION
  Removes a member direct from an AzureAD group.
  e.g. If Objects are part of a group that is member of our group, they can't be removed individually

#>
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $false)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message string.
        [string]$AADGroupObjectId,
        [Parameter(Mandatory = $true, Position = 1, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message string.
        [string]$ObjectId
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        #$urlref = "https://graph.microsoft.com/v1.0/groups/$AADGroupObjectId/members/`$ref"
        $headers = @{
            Authorization  = "Bearer $Token_Graph"
            "Content-type" = "application/json"
        }
    }
    Process {
        try {
            $PSBoundParameters.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Key) = $($_.Value)" | Write-LogRunbook -Caller $CmdletName }
            $url = "https://graph.microsoft.com/v1.0/groups/$AADGroupObjectId/members/$ObjectId/`$ref"
            Write-LogRunbook "Removing $url" -Caller $CmdletName
            $response = Invoke-RestMethod -Headers $headers -Uri $url -Method Delete -ErrorAction Stop
        }
        catch {
            switch ($_.Exception.Response.StatusCode) {
                'Unauthorized' {
                    if ($Global:GraphTokenRefreshCount -lt $Global:GraphTokenRefreshLimit) {
                        Write-LogRunbook "Token expired. Getting a new one. GraphTokenRefreshCount: '$Global:GraphTokenRefreshCount'" -Caller $CmdletName
                        $global:Token_Graph = Get-Token
                        $Global:GraphTokenRefreshCount++
                        Remove-AADDirectGroupMember @PSBoundParameters
                    }
                    else {
                        Write-ErrorRunbook
                        throw [CustomException]::new( $CmdletName, "GraphTokenRefreshLimit '$Global:GraphTokenRefreshCount' reached! ")
                    }
                }
                'NotFound' { 
                    Write-LogRunbook "AzureAD object not found." -Caller $CmdletName
                }
                Default {
                    Write-ErrorRunbook
                    throw [CustomException]::new( $CmdletName, "$($response.StatusCode) StatusCode calling '$url'")
                }
            }
        }
    }
    End {
    }
}
#EndRegion -------------------------------------------------- [Functions] ----------------------------------------------
#Region -------------------------------------------------------- [Main] ----------------------------------------------
try {
   
    "====================================================================" | Write-LogRunbook -Caller 'Info-Start'
    "======================= ScriptVersion: $Scriptversion =======================" | Write-LogRunbook -Caller 'Info-Start'
    $PSBoundParameters.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Key) = $($_.Value)" |  Write-LogRunbook -Caller 'Info-Start' }
    $CurrentJsonObject = 1
    $JsonObjects = Get-JsonContent -JsonFilePath $JsonPath -Web
    $Token_Graph = Get-Token

    $JsonObjects | ForEach-Object {
        Write-LogRunbook "--------------------------------------------------------------------------------" -Caller "JsonEntry $CurrentJsonObject"
        #        Write-LogRunbook "Processing AzureAD Group: '$($_.AzureADGroupName)' Id: '$($_.AzureADGroupId)'" -Caller "JsonEntry $CurrentJsonObject"
        if ((Test-AADGroup -GroupId $_.UserAzureADGroupId -GroupName $_.UserAzureADGroupName) -and
            (Test-AADGroup -GroupId $_.DeviceAzureADGroupId -GroupName $_.DeviceAzureADGroupName)) {
            #validating if OS list consist valid OS
            $PossibleOsList = "Windows", "MacOS", "IPhone", "IPad", "Android"
            $OSlist = if ([string]::IsNullOrEmpty(( $_.OSList))) {$PossibleOsList} else { $_.OSList -split ','}
            #validating if TrustType list consist valid TrustTypes (it is called Join type in the UI)
            $PossibleTrustTypeList = "AzureAd", "ServerAd", "Workplace"
            $TrustTypeList = if ([string]::IsNullOrEmpty(( $_.TrustTypeList))) {$PossibleTrustTypeList} else { $_.TrustTypeList -split ','}
            # isCompliant can be True or False. Empty $_.isCompliant means $_.isCompliant =  both possible values 
            # same for accountEnabled
            # if (($_.isCompliant -split ',').Count -eq 1) {[bool]$isCompliant = $_.isCompliant}
            if (-not (Compare-Object -ReferenceObject $PossibleOsList -DifferenceObject $OSList | Where-Object { $_.SideIndicator -eq '=>' })) {
                if (-not (Compare-Object -ReferenceObject $PossibleTrustTypeList -DifferenceObject $TrustTypeList | Where-Object { $_.SideIndicator -eq '=>' })) {
                    $HashArguments = [ordered]@{
                        OSes = $OSlist
                        trustTypes = $TrustTypeList
                      }
                    if (($_.isCompliant -eq 'Yes') -or ($_.isCompliant -eq 'No')) {
                        $HashArguments["isCompliant"] = $_.isCompliant
                    }
                    if (($_.accountEnabled -eq 'Yes') -or ($_.accountEnabled -eq 'No')) {
                        $HashArguments["accountEnabled"] = $_.accountEnabled
                    }
                    $UserAssignedDevices = Get-AADTransitiveGroupMembers -AADGroupObjectId $_.UserAzureADGroupId -MemberType 'microsoft.graph.user' | Get-AADUserOwnedDevices @HashArguments
                    if ($UserAssignedDevices) {
                        $UniqueDevicesToBeAdded = ($UserAssignedDevices | Group-Object -Property id).Name
                        $DestinationGroupExistingDevices = Get-AADTransitiveGroupMembers -AADGroupObjectId $_.DeviceAzureADGroupId -MemberType 'microsoft.graph.device'
                        # adding devices to group
                        if ($DestinationGroupExistingDevices.Count -eq 0) {
                            Add-AADGroupMembers -AADObjectIds $UniqueDevicesToBeAdded -AADGroupObjectId "$($_.DeviceAzureADGroupId)"
                            #$UniqueDevicesToBeAdded | Out-String | Write-Output
                            Write-Output "Added $($UniqueDevicesToBeAdded.count) devices to group '$($_.DeviceAzureADGroupName)'. Source group: '$($_.UserAzureADGroupName)'"
                        }
                        else {
                            # difference between two groups, to remove/add elements
                            $Differences = Compare-Object -ReferenceObject $DestinationGroupExistingDevices -DifferenceObject $UniqueDevicesToBeAdded
                            $ObjToBeAdded = ($Differences | Where-Object { $_.SideIndicator -eq '=>' }).InputObject
                            $ObjToBeRemoved = ($Differences | Where-Object { $_.SideIndicator -eq '<=' }).InputObject
                            if ($ObjToBeRemoved) {
                                $ObjToBeRemoved | Remove-AADDirectGroupMember -AADGroupObjectId $_.DeviceAzureADGroupId
                            }
                            if ($ObjToBeAdded) {
                                Add-AADGroupMembers -AADObjectIds $ObjToBeAdded -AADGroupObjectId $_.DeviceAzureADGroupId
                            }
                            #$ObjToBeAdded | Out-String | Write-Output
                            Write-Output "Added $($ObjToBeAdded.count) objects to group '$($_.DeviceAzureADGroupName)'. Source group: '$($_.UserAzureADGroupName)'"
                            #$ObjToBeRemoved | Out-String | Write-Output
                        }
                    }
                    else {
                        # if source group is empy or its users have 0 devices, still remove the existing devices from the destination group
                        Write-Output "No eligible devices found for members of source group: '$($_.UserAzureADGroupName)'."
                        Write-LogRunbook "No eligible devices found for members of source group: '$($_.UserAzureADGroupId)'." -Caller "Test-AADSourceGroupMembers"
                        $ObjToBeRemoved = Get-AADTransitiveGroupMembers -AADGroupObjectId $_.DeviceAzureADGroupId -MemberType 'microsoft.graph.device'
                        #adding devices to group
                        if ($ObjToBeRemoved.Count -ne 0) {
                            $ObjToBeRemoved | Remove-AADDirectGroupMember -AADGroupObjectId $_.DeviceAzureADGroupId
                            #Write-Output "Removed $($DestinationGroupExistingDevices.count) objects from group '$($_.DeviceAzureADGroupName)'. Source group: '$($_.UserAzureADGroupName)'"
                        }
                    }
                    Write-Output "Removed $($ObjToBeRemoved.count) objects from group '$($_.DeviceAzureADGroupName)'. Source group: '$($_.UserAzureADGroupName)'"
                }
                else {
                    Write-LogRunbook 'This entry contains at least one unsupported Trust Type (it is called Join type in the UI).' -Caller "Test-OSList"
                }
            }
            else {
                Write-LogRunbook 'This entry contains at least one unsupported OS.' -Caller "Test-OSList"
            }

        }
        $CurrentJsonObject++
    }
}
catch {
    switch ($_.Exception.Message) {
        'Get-GraphToken' { $Global:ExitCode = 101 }
        'Get-JsonContent' { $Global:ExitCode = 102 }
        'Test-AADGroup' { $Global:ExitCode = 103 }
        'Get-AADTransitiveGroupMembers' { $Global:ExitCode = 104 }
        'Get-AADUserOwnedDevices' { $Global:ExitCode = 105 }
        'Add-AADGroupMembers' { $Global:ExitCode = 106 }
        'Remove-AADDirectGroupMember' { $Global:ExitCode = 106 }
        Default { $Global:ExitCode = 300 }
    }
    Write-ErrorRunbook
    Write-LogRunbook "Execution completed with exit code: $Global:ExitCode" -Caller 'Info-End'
}
finally {
    if ($Global:ExitCode -ne 0) { throw $_ }
    Write-LogRunbook "Execution completed with exit code: $Global:ExitCode" -Caller 'Info-End'
}
#EndRegion ----------------------------------------------------- [Main] ----------------------------------------------