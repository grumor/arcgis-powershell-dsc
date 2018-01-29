<#
    .SYNOPSIS
        Creates a File Share for the Server and Portal to be shared in a High Availabilty Setup.
	.PARAMETER Ensure
		Indicates if the FileShare will be created and given the necessary Permissions. Take the values Present or Absent. 
        - "Present" ensures that FileShare is Created, if not already created.
        - "Absent" ensures that FileShare is removed, i.e. if present.
    .PARAMETER FileShareName
        Name of the FileShare as seen by Remote Resources.
    .PARAMETER FileShareLocalPath
        Local Path on Machine for the FileShare.
    .PARAMETER UserName
		UserName or Domain Account UserName which will have access to the File Share over the network.
#>

function Get-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Collections.Hashtable])]
	param
	(
		[parameter(Mandatory = $true)]
		[System.String]
		$FileShareName,

		[parameter(Mandatory = $true)]
		[System.String]
		$FileShareLocalPath,

		[parameter(Mandatory = $true)]
		[System.String]
		$UserName
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
		$FileShareName,

		[parameter(Mandatory = $true)]
		[System.String]
		$FileShareLocalPath,

		[parameter(Mandatory = $true)]
		[System.String]
		$UserName,

		[ValidateSet("Present","Absent")]
		[System.String]
		$Ensure
	)

    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false

    if($Ensure -eq 'Present') {
		New-Item $FileShareLocalPath –type directory;
		New-SMBShare –Name $FileShareName –Path $FileShareLocalPath –FullAccess $UserName
        #Grant-FileShareAccess -Name $FileShareName -AccessRight Full -AccountName $UserName
		$acl = Get-Acl $FileShareLocalPath
		$permission = "$UserName","FullControl","ContainerInherit,ObjectInherit","None","Allow"
        $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
        $acl.SetAccessRule($accessRule)
		$acl | Set-Acl $FileShareLocalPath
    }
    elseif($Ensure -eq 'Absent') {
		if ($share = Get-WmiObject -Class Win32_Share -Filter "Name='$FileShareName'"){ 
			$share.delete() 
		}
    }
    Write-Verbose "In Set-Resource for ArcGIS FileShare"
}

function Test-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Boolean])]
	param
	(
        [parameter(Mandatory = $true)]
		[System.String]
		$FileShareName,

		[parameter(Mandatory = $true)]
		[System.String]
		$FileShareLocalPath,

		[parameter(Mandatory = $true)]
		[System.String]
		$UserName,

		[ValidateSet("Present","Absent")]
		[System.String]
		$Ensure
	)

    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false

    $result = $false
	
	$fs = Get-WmiObject -Class Win32_Share -Filter "Name='$FileShareName'"
	if($fs){
		if((($fs | Get-Acl).AccessToString) -match $UserName){
			$result = $True
		}else{
			Write-Verbose "Correct Permissions are not granted."
		}
	}else{
		Write-Verbose "FileShare Not Found"
		if(Test-Path $FileShareLocalPath){
			Throw "FileShareLocalPath already exist. Please Choose Another One!"
		}
		$fsPath = $FileShareLocalPath -replace "\\","\\"
		if(Get-WmiObject Win32_Share -Filter "path='$fsPath'"){
			Throw "File Share Local Path already has a FileShare defined for it. Please Choose Another One!"
		}
	}
	
    if($Ensure -ieq 'Present') {
	       $result   
    }
    elseif($Ensure -ieq 'Absent') {        
        (-not($result))
    }
}

Export-ModuleMember -Function *-TargetResource