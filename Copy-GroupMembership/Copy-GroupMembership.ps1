<#PSScriptInfo

.VERSION 1.0

.DATE 24-Nov-2023

.AUTHOR adrian.cojocaru

#>

<#
  .SYNOPSIS
  Copy the group membership from one or more Azure Active Directory (Entra ID) groups to a single destination group.

  .DESCRIPTION
  The new members will always be added to the destionation group (if they don't already exists).
  Members will never be removed from the destination group even if they are removed from the source group(s).
  Uses a JSON configuration file stored on blob storage that defines the source & target groups.  
  When new groups are added, only this file will change. 
  Initially developed for Intune's EPM component removal
  App registration permissions:
  Microsoft Graph (2)
    GroupMember.ReadWrite.All
    User.Read.All 

  .INPUTS
  If your script accepts pipeline input, describe it here.

  .OUTPUTS
  output generated by your script. If any.

  .EXAMPLE
  .\Copy-GroupMembership.ps1

#>


#Region ----------------------------------------------------- [AzureAD Variables] ----------------------------------------------
[string]$ApplicationId = if ($env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) { Get-AutomationVariable -Name "DWC-EUD-Automation_AppId" } else { $env:MyCompanyDefenderAppClientId }
#[string]$ApplicationSecret = if ($env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) { Get-AutomationVariable -Name "DWC-EUD-Automation_AppSecret" } else { $env:MyCompanyDefenderAppSecret }
[string]$Thumbprint = if ($env:AZUREPS_HOST_ENVIRONMENT -or $PSPrivateMetadata.JobId) { Get-AutomationVariable -Name "DWC-EUD-Automation_CertThumbprint" } else { $env:MyCompanyDefenderAppCertThumbprint }
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

function  Get-AllAADGroupMembers {
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNull()]
        [AllowEmptyString()]
        # Mandatory. Specifies the message string.
        [string]$GroupId
    )
    Begin {
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        $PSBoundParameters.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Key) = $($_.Value)" | Write-LogRunbook -Caller $CmdletName }
        $GroupMembersList = @()
        $count = 0
    }
    End {
        try {
            $headers = @{ 'Authorization' = "Bearer $Token_Graph" }
            $url = "https://graph.microsoft.com/v1.0/groups/$GroupId/members"
            $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -UseBasicParsing -ErrorAction Stop
            #$response.Content | ConvertFrom-Json
            #check this when the group will have a few members..
            $response.value | Select-Object -Property '@odata.type', 'id', 'deviceId', 'displayName' | Out-String | Write-LogRunbook -Caller $CmdletName
            if ($response.value) { $GroupMembersList += $response.value }
            while ($response.'@odata.nextLink') {
                $count++
                Write-LogRunbook "Current @odata.nextLink: $count" -Caller $CmdletName
                #Start-Sleep -Seconds 1
                $response = Invoke-RestMethod -Headers $headers -Uri $response.'@odata.nextLink' -Method Get -ErrorAction Stop
                if ($response.value) { 
                    $response.value | Select-Object -Property '@odata.type', 'id', 'deviceId', 'displayName' | Out-String | Write-LogRunbook -Caller $CmdletName
                    $GroupMembersList += $response.value 
                }
            }
            $GroupMembersList
        }
        catch {
            switch ($_.Exception.Response.StatusCode) {
                'Unauthorized' {
                    if ($Global:GraphTokenRefreshCount -lt $Global:GraphTokenRefreshLimit) {
                        Write-LogRunbook "Token expired. Getting a new one. GraphTokenRefreshCount: '$Global:GraphTokenRefreshCount'" -Caller $CmdletName
                        $global:Token_Graph = Get-Token
                        $Global:GraphTokenRefreshCount++
                        Get-AllAADGroupMembers @PSBoundParameters
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

#EndRegion -------------------------------------------------- [Functions] ----------------------------------------------
#Region -------------------------------------------------------- [Main] ----------------------------------------------
try {
   
    "====================================================================" | Write-LogRunbook -Caller 'Info-Start'
    "======================= ScriptVersion: $Scriptversion =======================" | Write-LogRunbook -Caller 'Info-Start'
    $PSBoundParameters.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Key) = $($_.Value)" |  Write-LogRunbook -Caller 'Info-Start' }
    [int]$CurrentJsonObject = 0
    $JsonObjects = Get-JsonContent -JsonFilePath $JsonPath -Web
    $Token_Graph = Get-Token
    
    $JsonObjects | ForEach-Object {
		$DateTimeBefore = Get-Date						  
        $CurrentJsonObjectplusone = $CurrentJsonObject + 1
        Write-LogRunbook "--------------------------------------------------------------------------------" -Caller "JsonEntry $CurrentJsonObjectplusone"
        $SourceAzureADGroupIds = $JsonObjects[$CurrentJsonObject].SourceAzureADGroupIds.split(',')
        $SourceAzureADGroupNames = $JsonObjects[$CurrentJsonObject].SourceAzureADGroupNames.split(',')
        if (Test-AADGroup -GroupId $_.DestinationAzureADGroupId -GroupName $_.DestinationAzureADGroupName) {
            for ($i = 0; $i -lt $SourceAzureADGroupIds.count; $i++) {
                $iplusone = $i+1
                Write-Output "JsonEntry $CurrentJsonObjectplusone SourceGroup $iplusone"
                Write-LogRunbook "JsonEntry $CurrentJsonObjectplusone SourceGroup $iplusone" -Caller 'Info-Main'
                if (Test-AADGroup -GroupId $SourceAzureADGroupIds[$i] -GroupName $SourceAzureADGroupNames[$i]) {
                    $GroupDataSource = Get-AllAADGroupMembers -GroupId $SourceAzureADGroupIds[$i]
                    $GroupDataDestination = Get-AllAADGroupMembers -GroupId $_.DestinationAzureADGroupId
                    Write-Output "Before. Source group: '$($SourceAzureADGroupNames[$i])'. Meember count: [$($GroupDataSource.count)] Destination group: '$($_.DestinationAzureADGroupName)' Member count: [$($GroupDataDestination.count)]"
                    Write-LogRunbook "Before. Source group: '$($SourceAzureADGroupNames[$i])'. Meember count: [$($GroupDataSource.count)] Destination group: '$($_.DestinationAzureADGroupName)' Member count: [$($GroupDataDestination.count)]" -Caller 'Info-Main'
                    $Differences = Compare-Object -ReferenceObject @($GroupDataSource.id | Select-Object) -DifferenceObject @($GroupDataDestination.id | Select-Object)
                    $ObjToBeAdded = ($Differences | Where-Object { $_.SideIndicator -eq '<=' }).InputObject
                    if ($ObjToBeAdded) {
                        Add-AADGroupMembers -AADObjectIds $ObjToBeAdded -AADGroupObjectId $_.DestinationAzureADGroupId
                    }
                    Write-Output "Added [$($ObjToBeAdded.count)] objects. Source group: '$($SourceAzureADGroupNames[$i])'. Destination group: '$($_.DestinationAzureADGroupName)'"
                    Write-LogRunbook "Added [$($ObjToBeAdded.count)] objects. Source group: '$($SourceAzureADGroupNames[$i])'. Destination group: '$($_.DestinationAzureADGroupName)'" -Caller 'Info-Main'
                } else {
                    Write-Output "The provided Group ID '$($SourceAzureADGroupIds[$i])' does not match the provided group name '$($SourceAzureADGroupNames[$i])' in AAD. Check the log file for more details."
                }
            }
        } else {
            Write-Output "The provided Group id '$($_.DestinationAzureADGroupId)' does not match the provided group name '$($_.DestinationAzureADGroupName)' in AAD. Check the log file for more details."
        }
        $CurrentJsonObject++
        $ElapsedTime = New-TimeSpan -Start $DateTimeBefore -End (Get-Date)
        Write-Output "Elapsed time (seconds): $($ElapsedTime.TotalSeconds)"																		  
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