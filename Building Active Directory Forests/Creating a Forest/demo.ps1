<#
	Environment
	===========

	- (2) Windows Server 2016 VMs on the same network (soon-to-be domain controllers)
	- (1) Windows 10 computer in workgroup with open PowerShell Remoting sessions to both servers

	Our Mission
	===========

	- Create an Active Directory forest on the TEST-DC VM called techsnips-test.local
	- Create an Active Directory forest on the PROD-DC VM called techsnips.local
	- Create a PowerShell function to ease forest creation
	- Populate each forest with test objects by creating a custom function
    
#>

#region Setting up the test forest

## We could also just use the -ComputerName parameter on Install-WindowsFeature
Install-windowsfeature -Name AD-Domain-Services

$safeModePw = ConvertTo-SecureString -String 'p@$$w0rd10' -AsPlainText -Force

$forestParams = @{
	DomainName                    = 'powerlab.local'
	DomainMode                    = 'WinThreshold'
	ForestMode                    = 'WinThreshold'
	Confirm                       = $false
	SafeModeAdministratorPassword = $safeModePw
	WarningAction                 = 'Ignore'
}
Install-ADDSForest @forestParams

#endregion

#region Creating a custom function
function New-ActiveDirectoryForest {
	param(
		[Parameter(Mandatory)]
		[pscredential]$Credential,

		[Parameter(Mandatory)]
		[string]$SafeModePassword,

		[Parameter(Mandatory)]
		[string]$ComputerName,

		[Parameter()]
		[string]$DomainName = 'powerlab.local',

		[Parameter()]
		[string]$DomainMode = 'WinThreshold',

		[Parameter()]
		[string]$ForestMode = 'WinThreshold'
	)

	Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock {

		Install-windowsfeature -Name AD-Domain-Services
		
		$forestParams = @{
			DomainName                    = $using:DomainName
			DomainMode                    = $using:DomainMode
			ForestMode                    = $using:ForestMode
			Confirm                       = $false
			SafeModeAdministratorPassword = (ConvertTo-SecureString -AsPlainText -String $using:SafeModePassword -Force)
			WarningAction                 = 'Ignore'
		}
		$null = Install-ADDSForest @forestParams
	}
}

New-ActiveDirectoryForest -Credential $credential -SafeModePassword 'p@$$w0rd10'
#endregion

#region Setting up the production forest

## Have already established a PowerShell Remoting session to PROD-DC
Enter-PSSession -Session $prodDcSession

Install-windowsfeature -Name AD-Domain-Services

$safeModePw = ConvertTo-SecureString -String 'p@$$w0rd10' -AsPlainText -Force

$forestParams = @{
	DomainName                    = 'powerlab.local'
	DomainMode                    = 'WinThreshold'
	ForestMode                    = 'WinThreshold'
	Confirm                       = $false
	SafeModeAdministratorPassword = $safeModePw
	WarningAction                 = 'Ignore'
}
Install-ADDSForest @forestParams

#endregion


#region Populating the domain with test objects

## Creating the data source CSVs
Import-Csv -Path 'C:\Users.csv'
Import-Csv -Path 'C:\Groups.csv'

<# 
    For each group, we're going to:
        - check to see if the OU it is in in exists. If not, it will be created.
        - check to see if the user exists. If not, it will be created.

    For each user, we're going to:
        - check to see if the OU it is in exists. If not, it will be created.
        - check to see if the user exists. If not, it will be created.
        - check to see if the user is already a member of it's group. If not, it will be added
#>

function New-ActiveDirectoryObject {
	param(
		[Parameter(Mandatory)]
		[string]$UsersFilePath,
        
		[Parameter(Mandatory)]
		[string]$GroupsFilePath,
        
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]$DomainController,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[pscredential]$Credential
	)

	## Read CSVs to bring them in to begin working with them
	$users = Import-Csv -Path $UsersFilePath
	$groups = Import-Csv -Path $GroupsFilePath
    
	## Create the PS remoting session to connect to the DC
	$newSessParams = @{
		ComputerName = $DomainController
	}
	if ($PSBoundParameters.ContainsKey('Credential')) {
		$newSessParams.Credential = $Credential
	}
	$dcSession = New-PSSession @newSessParams

	## Create the scriptblock that will be run on the DC
	$scriptBlock = {
		foreach ($group in $using:groups) {
			## Check to see if the OU the group is supposed to be in
			if (-not (Get-AdOrganizationalUnit -Filter "Name -eq '$($group.OUName)'")) {
				## Create the OU
                Write-Verbose -Message 'Adding OU...'
				New-AdOrganizationalUnit -Name $group.OUName
			}
			## Check to see if the group exists
			if (-not (Get-AdGroup -Filter "Name -eq '$($group.GroupName)'")) {
				## Create the group
                Write-Verbose -Message 'Adding group...'
				New-AdGroup -Name $group.GroupName -GroupScope $group.Type -Path "OU=$($group.OUName),DC=powerlab,DC=local"
			}
		}

		foreach ($user in $using:users) {
			## Check to see if the OU the user is supposed to be in
			if (-not (Get-AdOrganizationalUnit -Filter "Name -eq '$($user.OUName)'")) {
				## Create the OU
                Write-Verbose -Message 'Adding OU...'
				New-AdOrganizationalUnit -Name $user.OUName
			}
			## Check to see if the user exists
			if (-not (Get-AdUser -Filter "Name -eq '$($user.UserName)'")) {
				## Create the user
                Write-Verbose -Message 'Adding User...'
				New-AdUser -Name $user.UserName -Path "OU=$($user.OUName),DC=powerlab,DC=local"
			}
			## Check to see if the user is already in the group
			if ($user.UserName -notin (Get-AdGroupMember -Identity $user.MemberOf).Name) {
				## Add the user to the group
                Write-Verbose -Message 'Adding group member...'
				Add-AdGroupMember -Identity $user.MemberOf -Members $user.UserName
			}
		}
	}

	## Run the code on the DC
	Invoke-Command -Session $dcSession -ScriptBlock $scriptBlock
    
	## Cleanup the temporary remoting session
	$dcSession | Remove-PSSession
}

$params = @{
	GroupsFilePath   = 'C:\Groups.csv'
	UsersFilePath    = 'C:\Users.csv'
	DomainController = $computerName
	Credential       = $credential
    Verbose = $true
}
New-ActiveDirectoryObject @params
#endregion