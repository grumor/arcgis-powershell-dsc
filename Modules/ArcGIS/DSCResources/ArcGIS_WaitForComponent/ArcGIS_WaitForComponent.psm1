<#
    .SYNOPSIS
        Resource Implements application level to handle cross node dependencies specific to the ArcGIS Enterprise Stack
    .PARAMETER Component
        Name of the Component for which the present node needs to wait for. Values accepted - Server, Portal, ServerWA, PortalWA, DataStore, SpatioTemporal, TileCache, SQLServer
    .PARAMETER ComponentHostName
        HostName of the Component for which the present node needs to wait for.
    .PARAMETER ComponentContext
        Context of the Component for which the present node needs to wait for.
    .PARAMETER Ensure
        Take the values Present or Absent. 
        - "Present" ensures that machine waits for a target machine, for which the present node has a dependency on.
        - "Absent" - not implemented.
    .PARAMETER Credential
         A MSFT_Credential Object - Primary Site Adminstrator for the Component for which the present node needs to wait for.
    .PARAMETER RetryIntervalSec
        Time Interval after which the Resource will again check the status of the resource on the remote machine for which the node is waiting for.
    .PARAMETER RetryCount
        Number of Retries before the Resource is done trying to see if the resource on the target Machine is done.        
#>


function Get-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Collections.Hashtable])]
	param
	(
		[parameter(Mandatory = $true)]
        [ValidateSet("Server","Portal","ServerWA","PortalWA","DataStore","SpatioTemporal","TileCache","UnregisterPortal")]
		[System.String]
        $Component,

        [parameter(Mandatory = $true)]
        [ValidateSet("Server","Portal","WebAdaptor","DataStore","LoadBalancer","PortalUpgrade")]
		[System.String]
        $InvokingComponent,

               
        [parameter(Mandatory = $true)]
		[System.String]
        $ComponentHostName,
        
        [parameter(Mandatory = $true)]
		[System.String]
		$ComponentContext
	)

    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false
    
	$null
}

function Set-TargetResource
{
	[CmdletBinding()]
	param
	(
		[parameter(Mandatory = $true)]
        [ValidateSet("Server","Portal","ServerWA","PortalWA","DataStore","SpatioTemporal","TileCache","UnregisterPortal")]
		[System.String]
        $Component,

        [parameter(Mandatory = $true)]
        [ValidateSet("Server","Portal","WebAdaptor","DataStore","LoadBalancer","PortalUpgrade")]
		[System.String]
        $InvokingComponent,
        
        [parameter(Mandatory = $true)]
		[System.String]
        $ComponentHostName,
        
        [parameter(Mandatory = $true)]
		[System.String]
		$ComponentContext,

		[ValidateSet("Present","Absent")]
		[System.String]
		$Ensure,

        [parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]
		$Credential,

        [parameter(Mandatory = $false)]
		[uint32]
        $RetryIntervalSec  = 30,

        [parameter(Mandatory = $false)]
		[uint32]
        $RetryCount  = 10
    )   
    
    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false
    
    $Referer = 'http://localhost'
    $NumCount = 0
	$Done     = $false
	while ((-not $Done) -and ($NumCount++ -le $RetryCount)) 
	{
        Write-Verbose "Attempt $NumCount - $Component"
        try {
            if($Component -ieq "Server"){
                $token = Get-ServerToken -ServerEndPoint "http://$($ComponentHostName):6080" -ServerSiteName $ComponentContext -UserName $Credential.UserName `
                    -Password $Credential.GetNetworkCredential().Password -Referer $Referer
                Write-Verbose "Checking for site on '$ComponentHostName'"
                $Done = ($token.token -ne $null)
                if($Done){
                    Start-Sleep -Seconds 180
                }
            }elseif($Component -ieq "Portal"){
                Write-Verbose "Checking for Portal site on '$ComponentHostName'"
                $token = Get-PortalToken -PortalHostName $ComponentHostName -SiteName $ComponentContext -UserName $Credential.UserName  `
                            -Password $Credential.GetNetworkCredential().Password -Referer $Referer 
                $Done = ($token.token -ne $null)
            }elseif($Component -ieq "DataStore" -or $Component -ieq "SpatioTemporal" -or $Component -ieq "TileCache"){
                $token = Get-ServerToken -ServerEndPoint "http://$($ComponentHostName):6080" -ServerSiteName $ComponentContext -UserName $Credential.UserName `
                        -Password $Credential.GetNetworkCredential().Password -Referer $Referer
                Write-Verbose "Checking if all datastore types passed as Params are registered"
                if($Component -ieq "DataStore"){
                    $AdditionalParams = 'Relational'
                }elseif($Component -ieq "SpatioTemporal"){
                    $AdditionalParams = 'SpatioTemporal'
                }elseif($Component -ieq "TileCache"){
                    $AdditionalParams = 'TileCache'
                }
                $Done = Test-DataStoreRegistered -ServerURL "http://$($ComponentHostName):6080" -Token $token.token -Referer $Referer -Type $AdditionalParams
            }elseif($Component -ieq "PortalWA"){
                $token = Get-PortalToken -PortalHostName $ComponentHostName -SiteName $ComponentContext -port 443 -UserName $Credential.UserName  `
                        -Password $Credential.GetNetworkCredential().Password -Referer $Referer 
                $Done = ($token.token -ne $null)
                
            }elseif($Component -ieq "ServerWA"){
                $token = Get-ServerToken -ServerEndPoint "https://$($ComponentHostName)" -ServerSiteName $ComponentContext -UserName $Credential.UserName `
                        -Password $Credential.GetNetworkCredential().Password -Referer $Referer                      
                $Done = ($token.token -ne $null)   
            }elseif($Component -ieq "UnregisterPortal"){
                $Referer = 'http://localhost'
    
                $token = Get-PortalToken -PortalHostName $ComponentHostName -SiteName $ComponentContext -UserName $Credential.UserName  `
                            -Password $Credential.GetNetworkCredential().Password -Referer $Referer 
                
                $Machines = Invoke-ArcGISWebRequest -Url ("https://$($ComponentHostName):7443/arcgis/portaladmin/machines") -HttpFormParameters @{ f = 'json'; token = $token.token; } -Referer $Referer -HttpMethod 'GET'
                $Done = $true
                $StandbyMachine = Get-FQDN $env:COMPUTERNAME
                ForEach($m in $Machines.machines){
                    if($StandbyMachine -ieq $m.machineName){
                        $Done = $false
                        break;
                    }
                }
            }
        }catch {
            Write-Verbose "[WARNING]  The Resource is not available yet"
            Write-Verbose "[WARNING] Check returned error:- $_"
        }
        
        if(-not($Done)) {
            Write-Verbose "$Component on '$ComponentHostName' is not ready. Retrying after $RetryIntervalSec Seconds"
            Start-Sleep -Seconds $RetryIntervalSec
        }else {
            Write-Verbose "$Component on '$ComponentHostName' is ready"
        }
	}
}



function Test-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Boolean])]
	param
	(
		[parameter(Mandatory = $true)]
        [ValidateSet("Server","Portal","ServerWA","PortalWA","DataStore","SpatioTemporal","TileCache","UnregisterPortal")]
		[System.String]
        $Component,

        [parameter(Mandatory = $true)]
        [ValidateSet("Server","Portal","WebAdaptor","DataStore","LoadBalancer","PortalUpgrade")]
		[System.String]
        $InvokingComponent,
                
        [parameter(Mandatory = $true)]
		[System.String]
        $ComponentHostName,
        
        [parameter(Mandatory = $true)]
		[System.String]
		$ComponentContext,

		[ValidateSet("Present","Absent")]
		[System.String]
		$Ensure,

        [parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]
		$Credential,

        [parameter(Mandatory = $false)]
        [uint32]
        $RetryIntervalSec  = 30,
        
        [parameter(Mandatory = $false)]
		[uint32]
        $RetryCount  = 10
	)
    
    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false

    $Referer = 'http://localhost'
    $result = $false
    [System.Reflection.Assembly]::LoadWithPartialName("System.Web") | Out-Null
    
    try {
        if($Component -ieq "Server"){
            Write-Verbose "Checking for Server site"
            $token = Get-ServerToken -ServerEndPoint "http://$($ComponentHostName):6080" -ServerSiteName $ComponentContext -UserName $Credential.UserName `
                        -Password $Credential.GetNetworkCredential().Password -Referer $Referer 
            $result = ($token.token -ne $null)
            if($result){
                Write-Verbose "Server Site Exists. Was able to retrieve token for PSA"
            }else{
                Write-Verbose "Unable to detect if Server Site Exists. Was NOT able to retrieve token for PSA"
            }
        }elseif($Component -ieq "Portal"){
            Write-Verbose "Checking for Portal site on '$ComponentHostName'"
            $token = Get-PortalToken -PortalHostName $ComponentHostName -SiteName $ComponentContext -UserName $Credential.UserName  `
                        -Password $Credential.GetNetworkCredential().Password -Referer $Referer 
            $result = ($token.token -ne $null)
            if($result){
                Write-Verbose "Portal Site Exists. Was able to retrieve token for PSA. Making a secondary check"
                $PortalHealthCheck = Invoke-ArcGISWebRequest -Url "https://$($ComponentHostName):7443/arcgis/portaladmin/healthCheck" -HttpFormParameters @{ f = 'json' } -Referer $Referer -LogResponse -HttpMethod 'GET'
                if($PortalHealthCheck.status -ieq "success"){
                    $result = $true
                }else{
                    $result = $False
                    $jsresponse = ConvertTo-Json $TestPortalResponse -Compress -Depth 5
                    Write-Verbose "Unable to detect if Portal Site Exists. [WARNING]:- $jsresponse "
                }
            }else{
                Write-Verbose "Unable to detect if Portal Site Exists. Was NOT able to retrieve token for PSA"
            }
        }elseif($Component -ieq "DataStore" -or $Component -ieq "SpatioTemporal" -or $Component -ieq "TileCache"){
            $token = Get-ServerToken -ServerEndPoint "http://$($ComponentHostName):6080" -ServerSiteName $ComponentContext -UserName $Credential.UserName `
                            -Password $Credential.GetNetworkCredential().Password -Referer $Referer
            
            Write-Verbose "Checking if data store is registered"
            if($Component -ieq "DataStore"){
                $AdditionalParams = 'Relational'
            }elseif($Component -ieq "SpatioTemporal"){
                $AdditionalParams = 'SpatioTemporal'
            }elseif($Component -ieq "TileCache"){
                $AdditionalParams = 'TileCache'
            }
            $result = Test-DataStoreRegistered -ServerURL "http://$($ComponentHostName):6080" -Token $token.token -Referer $Referer -Type $AdditionalParams
            if($result){
                Write-Verbose "All Types of DataStores are registered."
            }else{
                Write-Verbose "One or More Types of DataStore given as Parameter is not registered as Primary or Standby"
            }
        }elseif($Component -ieq "PortalWA"){
            Write-Verbose "Checking for Portal WebAdaptor"
            
            $token = Get-PortalToken -PortalHostName $ComponentHostName -SiteName $ComponentContext -port 443 -UserName $Credential.UserName  `
                        -Password $Credential.GetNetworkCredential().Password -Referer $Referer 
            $result = ($token.token -ne $null)
            if($result){
                Write-Verbose "Portal WebAdaptor Works. Was able to retrieve token for PSA"
            }else{
                Write-Verbose "Unable to detect if Portal WebAdaptor Works Correctly. Was NOT able to retrieve token for PSA"
            }
        }elseif($Component -ieq "ServerWA"){
            Write-Verbose "Checking for Server WebAdaptor"
            
            $token = Get-ServerToken -ServerEndPoint "https://$($ComponentHostName):443" -ServerSiteName $ComponentContext -UserName $Credential.UserName `
                    -Password $Credential.GetNetworkCredential().Password -Referer $Referer 
            $result = ($token.token -ne $null)
            if($result){
                Write-Verbose "Server WebAdaptor Works. Was able to retrieve token for PSA"
            }else{
                Write-Verbose "Unable to detect if Server WebAdaptor Works Correctly. Was NOT able to retrieve token for PSA"
            }
        }elseif($Component -ieq "UnregisterPortal"){
            $Referer = 'http://localhost'

            $token = Get-PortalToken -PortalHostName $ComponentHostName -SiteName $ComponentContext -UserName $Credential.UserName  `
                -Password $Credential.GetNetworkCredential().Password -Referer $Referer 
            
            $Machines = Invoke-ArcGISWebRequest -Url ("https://$($ComponentHostName):7443/arcgis/portaladmin/machines") -HttpFormParameters @{ f = 'json'; token = $token.token; } -Referer $Referer -HttpMethod 'GET'
            $result = $true
            $StandbyMachine = Get-FQDN $env:COMPUTERNAME
            ForEach($m in $Machines.machines){
                if($StandbyMachine -ieq $m.machineName){
                    $result = $false
                    break;
                }
            }
        }
    }catch {
        Write-Verbose "[WARNING] The Resource is not available yet!"
        #Write-Verbose "[WARNING]:- $($_)"
    }
    
    $result
    
}

function Test-DataStoreRegistered
{
    [CmdletBinding()]
    param(
        [System.String]$ServerURL, 
        [System.String]$Token, 
        [System.String]$Referer, 
        [System.String]$Type
    )
    
    $DBTypes = $Type -split ','
    $DsTypes = ""
    if($DBTypes -icontains 'Relational') {
        $DsTypes += 'egdb'
    }
    if($DBTypes -icontains 'TileCache' -or $DBTypes -icontains 'SpatioTemporal'){
        if($DsTypes -ne ""){
            $DsTypes += ","
        }
        $DsTypes += 'nosql'
    }

    Write-Verbose $DsTypes
    
    $DataItemsUrl = $ServerURL.TrimEnd('/') + '/arcgis/admin/data/findItems' 

    Write-Verbose $DataItemsUrl
    $response = Invoke-ArcGISWebRequest -Url $DataItemsUrl -HttpFormParameters  @{ f = 'json'; token = $Token; types = $DsTypes } -Referer $Referer 
    $result = $true
    $items = ($response.items | Where-Object { $_.provider -ieq 'ArcGIS Data Store' })
    Write-Verbose ($items | ConvertTo-Json -Depth 4)
    foreach($type in $DBTypes){
        Write-Verbose $type
        if($result){
            if($type -ieq 'Relational') {
                $result = $($items | Where-Object { ($_.type -ieq "egdb") } | Measure-Object).Count -gt 0
            }elseif($type -ieq 'TileCache'){
                $result = $($items | Where-Object { ($_.type -ieq "nosql") -and ($_.info.dsFeature -ieq "tileCache") } | Measure-Object).Count -gt 0
            }elseif($type -ieq 'SpatioTemporal'){
                $result = $($items | Where-Object { ($_.type -ieq "nosql") -and ($_.info.dsFeature -ieq "spatioTemporal") } | Measure-Object).Count -gt 0
            }
            if(-not($result)){
                break
            }
        }
    }
    $result
}

Export-ModuleMember -Function *-TargetResource