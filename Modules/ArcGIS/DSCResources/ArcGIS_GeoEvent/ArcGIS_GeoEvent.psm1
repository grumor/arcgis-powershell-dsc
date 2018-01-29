<#
    .SYNOPSIS
        Makes a request to the installed Server to create a New Server Site or Join it to an existing Server Site
    .PARAMETER Ensure
        Indicates to make sure GeoEvents Server is Configured Correcly. Take the values Present or Absent. 
        - "Present" ensures that GeoEvents Server is Configured Correcly, if not Configured created.
        - "Absent" ensures that GeoEvents Server is unconfigured, i.e. if present (not implemented).
    .PARAMETER Name
        Name of the Geoevent Server Resource
    .PARAMETER SiteAdministrator
        A MSFT_Credential Object - Primary Site Adminstrator for the Server
    .PARAMETER WebSocketContextUrl
        WebSocket Url for GeoEvent Server
    .PARAMETER SiteAdminUrl
        Server Site Admin URL 

#>
function Get-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Collections.Hashtable])]
	param
	(
		[parameter(Mandatory = $true)]
		[System.String]
		$Name
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
		[System.String]
		$Name,

        [parameter(Mandatory = $true)]
		[System.Management.Automation.PSCredential]
		$SiteAdministrator,

        [parameter(Mandatory = $true)]
		[System.String]
		$WebSocketContextUrl,

        [parameter(Mandatory = $false)]
		[System.String]
		$SiteAdminUrl,

		[ValidateSet("Present","Absent")]
		[System.String]
		$Ensure
	)

    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false

    [System.Reflection.Assembly]::LoadWithPartialName("System.Web") | Out-Null

	$ServiceName = 'ArcGISGeoEvent'
    if($Ensure -ieq 'Present') {   
		 		
        Write-Verbose "Stopping the service '$ServiceName'"    
		Stop-Service -Name $ServiceName -ErrorAction Ignore       
		Wait-ForServiceToReachDesiredState -ServiceName $ServiceName -DesiredState 'Stopped'

        Write-Verbose "Installing Windows Feature: IIS-WebSockets as a PreReq for GeoEvents Server"
        if (Get-Command "Get-WindowsOptionalFeature" -errorAction SilentlyContinue)
        {
            if(-not((Get-WindowsOptionalFeature -FeatureName IIS-WebSockets -online).State -ieq "Enabled")){
                Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebSockets -All
            }
        }else{
            Write-Verbose "Unable to Install Window Feature - IIS-WebSockets"
        }

		$FQDN = Get-FQDN $env:ComputerName
		$ServerUrl = "http://$($FQDN):6080"   
		$Referer = $ServerUrl
		Wait-ForUrl -Url "$ServerUrl/arcgis/admin" -MaxWaitTimeInSeconds 90 -SleepTimeInSeconds 5
		$token = Get-ServerToken -ServerEndPoint $ServerUrl -ServerSiteName 'arcgis' -UserName $SiteAdministrator.UserName `
								 -Password $SiteAdministrator.GetNetworkCredential().Password -Referer $Referer 

        $ConfigStoreProps = Get-ArcGISAdminConfigStore -ServerHostName $FQDN -SiteName 'arcgis' -Token $token.token -Referer $Referer
        $LocalRepositoryPath = $ConfigStoreProps.localRepositoryPath
        Write-Verbose "Local Repository Path is $($LocalRepositoryPath)"
        if(-not($LocalRepositoryPath)) {
            $LocalRepositoryPath = Join-Path $env:SystemDrive 'arcgisserver\local\zookeeper'
            Write-Verbose "Using default path $LocalRepositoryPath"
        }        

        #-->Check with Nikhil
        $ZooKeeperFolder = Join-Path $LocalRepositoryPath 'zookeeper'
        if(Test-Path $ZooKeeperFolder) {
            Write-Verbose "Deleting ZooKeeper folder $ZooKeeperFolder"
            Remove-Item -Path $ZooKeeperFolder -Recurse -Force 
        }

        if($SiteAdminUrl) {
            $machineProps = Get-ArcGISMachineProperties -ServerHostName $FQDN -MachineName $FQDN -SiteName 'arcgis' -Token $token.token -Referer $Referer 
            if($machineProps.adminURL -ine $SiteAdminUrl) {
                Write-Verbose "Configured AdminUrl '$($machineProps.adminURL)' does not match expected value of '$SiteAdminUrl'. Updating it"
                $machineProps.adminURL = $SiteAdminUrl
                try{ 
                    Set-ArcGISMachineProperties -ServerHostName $FQDN -MachineName $FQDN -SiteName 'arcgis' -Token $token.token -Referer $Referer -MachineProperties $machineProps
                }catch {
                    Write-Verbose "[WARNING]:- Set-ArcGISMachineProperties applied. Operation typically causes a restart and does not return a response"
                }
                Write-Verbose "Updated the AdminUrl. Wait for Server to return (if it restarts)"
                Wait-ForUrl -Url "$ServerUrl/arcgis/admin" -MaxWaitTimeInSeconds 90 -SleepTimeInSeconds 5
            }
        }

        $platformServices = Get-ArcGISPlatformServices -ServerHostName $FQDN -SiteName 'arcgis'  -Referer $Referer -Token $token.token        
        $messageBus = $platformServices.platformservices | Where-Object { $_.type -ieq 'MESSAGE_BUS' }
        if(-not($messageBus)){ 
            throw "No Message Bus found in platform service" 
        }
        $messageBusId = $messageBus.id
        Write-Verbose "ID of Message Bus is $messageBusId"

        if(-not($messageBusId)){ 
            throw "No Message Bus found in platform service" 
        }
        $messageBusService = Get-ArcGISPlatformServiceStatus -ServerHostName $FQDN -SiteName 'arcgis' -Token $token.token -PlatformServiceId $messageBusId -Referer $Referer 
        Write-Verbose "Status of Message Bus is $($messageBusService.configuredState)"
        if($messageBusService.configuredState -ine 'STARTED') {
            Write-Verbose "Starting Message Bus Service"
            Start-ArcGISPlatformService -ServerHostName $FQDN -SiteName 'arcgis' -Token $token.token -PlatformServiceId $messageBusId -Referer $Referer
            Write-Verbose "Started Message Bus Service"
        }
        else {
            Write-Verbose "Message Bus Service is already started"
        }

        $syncService = $platformServices.platformservices | Where-Object { $_.type -ieq 'SYNCHRONIZATION_SERVICE' }
        if(-not($syncService)){ 
            throw "No Synchronization Service found in platform service" 
        }
        $syncServiceId = $syncService.id
        Write-Verbose "ID of Synchronization Service is $syncServiceId"

        if(-not($syncServiceId)){ 
            throw "No Synchronization Service found in platform service" 
        }
        $synchronizationService = Get-ArcGISPlatformServiceStatus -ServerHostName $FQDN -SiteName 'arcgis' -Token $token.token -PlatformServiceId $syncServiceId -Referer $Referer 
        Write-Verbose "Status of Message Bus is $($synchronizationService.configuredState)"
        if($synchronizationService.configuredState -ine 'STARTED') {
            Write-Verbose "Synchronization Service is not started. Starting it"
            Start-ArcGISPlatformService -ServerHostName $FQDN -SiteName 'arcgis' -Token $token.token -PlatformServiceId $syncServiceId -Referer $Referer         
        }else {
            Write-Verbose "Synchronization Service is already started"
        }

        Write-Verbose "Checking if WebSocketContextURL in sys props is $WebSocketContextUrl"
        $sysProps = Get-ArcGISAdminSystemProperties -ServerHostName $FQDN -SiteName 'arcgis' -Referer $Referer -Token $token.token
        if($sysProps.WebSocketContextURL -ine $WebSocketContextUrl) {
            Write-Verbose "Current Value of WebSocketContextURL in sys props is '$($sysProps.WebSocketContextURL)' and does not match '$WebSocketContextUrl'. Setting it"
            if(-not($sysProps)) { $sysProps = @{} }
			if(-not($sysProps.WebSocketContextURL)) {
				Add-Member -InputObject $sysProps -MemberType NoteProperty -Name 'WebSocketContextURL' -Value $WebSocketContextUrl
			}else {
                $sysProps.WebSocketContextURL = $WebSocketContextUrl
            }
            $setResponse = Set-ArcGISAdminSystemProperties -ServerHostName $FQDN -SiteName 'arcgis' -Token $token.token -Referer $Referer -Properties $sysProps
            Write-Verbose "Response from Set Properties:- $setResponse"
        }
       
        Write-Verbose "Starting the service '$ServiceName'"    
		Start-Service -Name $ServiceName -ErrorAction Ignore       
		Wait-ForServiceToReachDesiredState -ServiceName $ServiceName -DesiredState 'Running'

    }else{
        Write-Warning 'Absent not implemented'
    }
}


function Test-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Boolean])]
	param
	(
		[parameter(Mandatory = $true)]
		[System.String]
		$Name,

        [parameter(Mandatory = $true)]
		[System.Management.Automation.PSCredential]
		$SiteAdministrator,

        [parameter(Mandatory = $true)]
		[System.String]
		$WebSocketContextUrl,

        [parameter(Mandatory = $false)]
		[System.String]
		$SiteAdminUrl,

		[ValidateSet("Present","Absent")]
		[System.String]
		$Ensure
    )
    
    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false

    [System.Reflection.Assembly]::LoadWithPartialName("System.Web") | Out-Null

	$ServiceName = 'ArcGISGeoEvent'
    $result = $true    
    $result = (Get-Service -Name $ServiceName -ErrorAction Ignore).Status -ieq 'Running'
    
    if($result) {
        $FQDN = Get-FQDN $env:ComputerName
		$ServerUrl = "http://$($FQDN):6080"   
		$Referer = $ServerUrl
		Wait-ForUrl -Url "$ServerUrl/arcgis/admin" -MaxWaitTimeInSeconds 90 -SleepTimeInSeconds 5
		$token = Get-ServerToken -ServerEndPoint $ServerUrl -ServerSiteName 'arcgis' -UserName $SiteAdministrator.UserName `
								 -Password $SiteAdministrator.GetNetworkCredential().Password -Referer $Referer 

        Write-Verbose "Checking if WebSocketContextURL in sys props is $WebSocketContextUrl"
        $sysProps = Get-ArcGISAdminSystemProperties -ServerHostName $FQDN -SiteName 'arcgis' -Referer $Referer -Token $token.token
        if($sysProps.WebSocketContextURL -ine $WebSocketContextUrl) {
            Write-Verbose "Current Value of WebSocketContextURL in sys props is '$($sysProps.WebSocketContextURL)'"
            $result = $false
        }

        if($result -and $SiteAdminUrl) {
            $machineProps = Get-ArcGISMachineProperties -ServerHostName $FQDN -MachineName $FQDN -SiteName 'arcgis' -Token $token.token -Referer $Referer 
            if($machineProps.adminURL -ine $SiteAdminUrl) {
                Write-Verbose "Configured AdminUrl '$($machineProps.adminURL)' does not match expected value of '$SiteAdminUrl'"
                $result = $false
            }
        }
    }

    if($result) {
		$platformServices = Get-ArcGISPlatformServices -ServerHostName $FQDN -SiteName 'arcgis' -Referer $Referer -Token $token.token
        $messageBus = $platformServices.platformservices | Where-Object { $_.type -ieq 'MESSAGE_BUS' }
        if(-not($messageBus)){ 
            throw "No Message Bus found in platform service" 
        }
        $messageBusId = $messageBus.id
        Write-Verbose "ID of Message Bus is $messageBusId"

        if(-not($messageBusId)){ 
            throw "No Message Bus found in platform service" 
        }
        $messageBusService = Get-ArcGISPlatformServiceStatus -ServerHostName $FQDN -SiteName 'arcgis' -Token $token.token -PlatformServiceId $messageBusId -Referer $Referer 
        Write-Verbose "Status of Message Bus is $($messageBusService.configuredState)"
        if($messageBusService.configuredState -ine 'STARTED') {
            Write-Verbose "Message Bus is not started"
            $result = $false            
        }else {
            Write-Verbose "Message Bus is started"
        }
    }

    if($result) {
		$platformServices = Get-ArcGISPlatformServices -ServerHostName $FQDN -SiteName 'arcgis' -Referer $Referer -Token $token.token
        $syncService = $platformServices.platformservices | Where-Object { $_.type -ieq 'SYNCHRONIZATION_SERVICE' }
        if(-not($syncService)){ 
            throw "No Synchronization Service found in platform service" 
        }
        $syncServiceId = $syncService.id
        Write-Verbose "ID of Synchronization Service is $syncServiceId"

        if(-not($syncServiceId)){ 
            throw "No Synchronization Service found in platform service" 
        }
        $synchronizationService = Get-ArcGISPlatformServiceStatus -ServerHostName $FQDN -SiteName 'arcgis' -Token $token.token -PlatformServiceId $messageBusId -Referer $Referer 
        Write-Verbose "Status of Message Bus is $($synchronizationService.configuredState)"
        if($synchronizationService.configuredState -ine 'STARTED') {
            Write-Verbose "Synchronization Service is not started"
            $result = $false            
        }else {
            Write-Verbose "Synchronization Service is started"
        }
    }

    if($Ensure -ieq 'Present') {
	       $result   
    }
    elseif($Ensure -ieq 'Absent') {        
        (-not($result))
    }
}

function Get-ArcGISMachineProperties
{
    [CmdletBinding()]
    param(
    [System.String]
        [Parameter(Mandatory=$true)]
        $ServerHostName,

        [Parameter(Mandatory=$true)]
        $MachineName,

        [System.String]
        [Parameter(Mandatory=$false)]
        $SiteName = 'arcgis',

        [System.String]
        [Parameter(Mandatory=$true)]
        $Token,        

        [System.String]
        [Parameter(Mandatory=$false)]
        $Referer = 'http://localhost',
                
        [System.Int32]
        [Parameter(Mandatory=$false)]
        $ServerPort = 6080
    )

   Invoke-ArcGISWebRequest -Url ("http://$($ServerHostName):$($ServerPort)/$SiteName" + '/admin/machines/' + $MachineName + '/') -HttpFormParameters @{ f = 'json'; token = $Token } -Referer $Referer
}

function Set-ArcGISMachineProperties
{
    [CmdletBinding()]
    param(
    [System.String]
        [Parameter(Mandatory=$true)]
        $ServerHostName,

        [Parameter(Mandatory=$true)]
        $MachineName,

        [System.String]
        [Parameter(Mandatory=$false)]
        $SiteName = 'arcgis',

        [System.String]
        [Parameter(Mandatory=$true)]
        $Token,        

        [System.String]
        [Parameter(Mandatory=$false)]
        $Referer = 'http://localhost',
                
        [System.Int32]
        [Parameter(Mandatory=$false)]
        $ServerPort = 6080,

        [Parameter(Mandatory=$true)]
        $MachineProperties
    )
    $Props = @{ 
                machineName = $MachineProperties.machineName
                adminURL = $MachineProperties.adminURL
                webServerMaxHeapSize = $MachineProperties.webServerMaxHeapSize
                webServerCertificateAlias = $MachineProperties.webServerCertificateAlias
                appServerMaxHeapSize = $MachineProperties.appServerMaxHeapSize
                socMaxHeapSize = $MachineProperties.socMaxHeapSize
                OpenEJBPort = $MachineProperties.ports.OpenEJBPort
                JMXPort = $MachineProperties.ports.JMXPort
                NamingPort = $MachineProperties.ports.NamingPort
                DerbyPort = $MachineProperties.ports.DerbyPort
                f = 'json'
                token = $Token
              }   
   Invoke-ArcGISWebRequest -Url ("http://$($ServerHostName):$($ServerPort)/$SiteName" + '/admin/machines/' + $MachineName + '/edit') -HttpFormParameters $Props -Referer $Referer -HttpMethod 'POST' 
}

function Get-ArcGISAdminSystemProperties
{
    [CmdletBinding()]
    param(
    [System.String]
        [Parameter(Mandatory=$true)]
        $ServerHostName,

        [System.String]
        [Parameter(Mandatory=$false)]
        $SiteName = 'arcgis',

        [System.String]
        [Parameter(Mandatory=$true)]
        $Token,        

        [System.String]
        [Parameter(Mandatory=$false)]
        $Referer = 'http://localhost',
                
        [System.Int32]
        [Parameter(Mandatory=$false)]
        $ServerPort = 6080
    )

   Invoke-ArcGISWebRequest -Url ("http://$($ServerHostName):$($ServerPort)/$SiteName" + '/admin/system/properties/') -HttpFormParameters @{ f = 'json'; token = $Token } -Referer $Referer
}

function Get-ArcGISAdminConfigStore
{
    [CmdletBinding()]
    param(
    [System.String]
        [Parameter(Mandatory=$true)]
        $ServerHostName,

        [System.String]
        [Parameter(Mandatory=$false)]
        $SiteName = 'arcgis',

        [System.String]
        [Parameter(Mandatory=$true)]
        $Token,        

        [System.String]
        [Parameter(Mandatory=$false)]
        $Referer = 'http://localhost',
                
        [System.Int32]
        [Parameter(Mandatory=$false)]
        $ServerPort = 6080
    )

   Invoke-ArcGISWebRequest -Url ("http://$($ServerHostName):$($ServerPort)/$SiteName" + '/admin/system/configstore/') -HttpFormParameters @{ f = 'json'; token = $Token } -Referer $Referer
}

function Set-ArcGISAdminSystemProperties
{
    [CmdletBinding()]
    param(
    [System.String]
        [Parameter(Mandatory=$true)]
        $ServerHostName,

        [System.String]
        [Parameter(Mandatory=$false)]
        $SiteName = 'arcgis',

        [System.String]
        [Parameter(Mandatory=$true)]
        $Token,        

        [System.String]
        [Parameter(Mandatory=$false)]
        $Referer = 'http://localhost',
                
        [System.Int32]
        [Parameter(Mandatory=$false)]
        $ServerPort = 6080,

        [Parameter(Mandatory=$true)]
        $Properties
    )

   Invoke-ArcGISWebRequest -Url ("http://$($ServerHostName):$($ServerPort)/$SiteName" + '/admin/system/properties/update') -HttpFormParameters @{ f = 'json'; token = $Token; properties = (ConvertTo-Json $Properties -Depth 5) } -Referer $Referer
}

function Get-ArcGISPlatformServices
{
    [CmdletBinding()]
    param(
    [System.String]
        [Parameter(Mandatory=$true)]
        $ServerHostName,

        [System.String]
        [Parameter(Mandatory=$false)]
        $SiteName = 'arcgis',

        [System.String]
        [Parameter(Mandatory=$true)]
        $Token,

        [System.String]
        [Parameter(Mandatory=$false)]
        $Referer = 'http://localhost',
                
        [System.Int32]
        [Parameter(Mandatory=$false)]
        $ServerPort = 6080
    )

   Invoke-ArcGISWebRequest -Url ("http://$($ServerHostName):$($ServerPort)/$SiteName" + '/admin/system/platformservices/') -HttpFormParameters @{ f = 'json'; token = $Token } -Referer $Referer
}

function Get-ArcGISPlatformServiceStatus
{
    [CmdletBinding()]
    param(
    [System.String]
        [Parameter(Mandatory=$true)]
        $ServerHostName,

        [System.String]
        [Parameter(Mandatory=$false)]
        $SiteName = 'arcgis',

        [System.String]
        [Parameter(Mandatory=$true)]
        $Token,

         [System.String]
        [Parameter(Mandatory=$true)]
        $PlatformServiceId,

        [System.String]
        [Parameter(Mandatory=$false)]
        $Referer = 'http://localhost',
                
        [System.Int32]
        [Parameter(Mandatory=$false)]
        $ServerPort = 6080
    )

   Invoke-ArcGISWebRequest -Url ("http://$($ServerHostName):$($ServerPort)/$SiteName" + "/admin/system/platformservices/$PlatformServiceId/status/") -HttpFormParameters @{ f = 'json'; token = $Token } -Referer $Referer
}

function Start-ArcGISPlatformService
{
    [CmdletBinding()]
    param(
    [System.String]
        [Parameter(Mandatory=$true)]
        $ServerHostName,

        [System.String]
        [Parameter(Mandatory=$false)]
        $SiteName = 'arcgis',

        [System.String]
        [Parameter(Mandatory=$true)]
        $Token,

         [System.String]
        [Parameter(Mandatory=$true)]
        $PlatformServiceId,

        [System.String]
        [Parameter(Mandatory=$false)]
        $Referer = 'http://localhost',
                
        [System.Int32]
        [Parameter(Mandatory=$false)]
        $ServerPort = 6080
    )

   Invoke-ArcGISWebRequest -Url ("http://$($ServerHostName):$($ServerPort)/$SiteName" + "/admin/system/platformservices/$PlatformServiceId/start/") -HttpFormParameters @{ f = 'json'; token = $Token } -Referer $Referer -TimeOutSec 90
}

function Stop-ArcGISPlatformService
{
    [CmdletBinding()]
    param(
    [System.String]
        [Parameter(Mandatory=$true)]
        $ServerHostName,

        [System.String]
        [Parameter(Mandatory=$false)]
        $SiteName = 'arcgis',

        [System.String]
        [Parameter(Mandatory=$true)]
        $Token,

         [System.String]
        [Parameter(Mandatory=$true)]
        $PlatformServiceId,

        [System.String]
        [Parameter(Mandatory=$false)]
        $Referer = 'http://localhost',
                
        [System.Int32]
        [Parameter(Mandatory=$false)]
        $ServerPort = 6080
    )

   Invoke-ArcGISWebRequest -Url ("http://$($ServerHostName):$($ServerPort)/$SiteName" + "/admin/system/platformservices/$PlatformServiceId/stop/") -HttpFormParameters @{ f = 'json'; token = $Token } -Referer $Referer
}

Export-ModuleMember -Function *-TargetResource

