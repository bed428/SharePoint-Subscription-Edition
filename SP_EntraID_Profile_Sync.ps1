<####  Script to Sync the SP User Profile App with EntraID 
Written By: Brian Dupy

IMPORTANT: 
	Microsoft.Graph keeps Delta links for a limited span of time. This must be run on a recurring schedule or you risk losing your Delta link. No error checking is built in for this as of now since it's unlikely in my scenario.
 		https://learn.microsoft.com/en-us/graph/delta-query-overview
   		As of 2025-02-12: For directory objects, the limit is seven days.
Prereqs: 
  - EntraCP installed
  - User Profile Service created successfully.
  - Azure Application Registration with the following permissions: 
      User.Read.All
      GroupMember.Read.All #Optional?? Not sure I have it because EntraCP requires it, using the same appreg as that.
  - Microsoft.Graph PowerShell module 
      (To install on server w/o internet: 
        + Login to computer with Internet.
        + Run: "Save-Module Microsoft.Graph -Path "C:\users\username\Downloads\Microsoft.Graph"
        + Zip it (super efficient. 1GB to 160MB)
        + Transfer and unzip to server's "C:\Program Files\WindowsPowerShell\Modules". For example, you'll have the following structure: 
          .\Modules\Microsoft.Graph.DeviceManagement
          .\Modules\Microsoft.Graph.DeviceManagement.Act..
          .\Modules\Microsoft.Graph.DeviceManagement.Ad...
          .\Modules\Microsoft.Graph.DeviceManagement.Entr...
          .\Modules\Microsoft.Graph.Devices.CloudPrint
          etc.
        )
      
#>
try{Add-PSSnapin "Microsoft.SharePoint.Powershell"}catch{} #try catch makes it silentlycontinue.
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Force
$maximumfunctioncount = 32768



#region Log Functions
    Function CreateLog() {
        # EventLog - create source if missing
        if (!(Get-EventLog -LogName Application -Source $logSource -ErrorAction SilentlyContinue)) {
            New-EventLog -LogName Application -Source $logSource -ErrorAction SilentlyContinue | Out-Null
        }
    }

    Function WriteLog($text, $color) {
        $global:msg += "`n$text"
        if ($color) {
            Write-Host $text -Fore $color
        }
        else {
            Write-Output $text
        }
    }

    Function SaveLog($id, $txt, $error) {
        # EventLog
        if (!$skiplog) {
            if (!$error) {
                # Success
                $global:msg += $txt
                Write-EventLog -LogName Application -Source $logSource -EntryType Information -EventId $id -Message $global:msg
            }
            else {      
                # Error
                $global:msg += "ERROR`n"
                $global:msg += $error.Message + "`n" + $error.ItemName
                Write-EventLog -LogName Application -Source $logSource -EntryType Warning -EventId $id -Message $global:msg
            }
        }
    }
#endregion Log Functions



###### START Main Script

$logSource = "EntraID Update SPProfiles "
$global:msg = ""
CreateLog
WriteLog "EntraID Update SP Profiles `n------`n"

try{
		
	
	## 1. Connect to MSGraph

	# Azrue Configuration, Tenant and Registered App with Graph User lookup rights
	WriteLog "Connecting to MSGraph... `n"
	$clientId = "REDACTED" #app registration's client ID
	$clientSecret = "nREDACTED" #secret value on the application registration. (no secretid needed)
	$tenantName = "REDACTED.onMicrosoft.com" #tenant name, lookup available here: https://gettenantpartitionweb.azurewebsites.net/
	$tenantId = "REDACTED" #tenant id, look here: https://gettenantpartitionweb.azurewebsites.net/

	# Convert the client secret to a secure string
	$ClientSecretPass = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force

	# Create a credential object using the client ID and secure string
	$ClientSecretCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $ClientId, $ClientSecretPass

	# Connect to Microsoft Graph with Client Secret
	Connect-MgGraph -Environment Global -TenantId $tenantId -ClientSecretCredential $ClientSecretCredential -NoWelcome



	## 2. Connect to SP User Profile Application

	WriteLog "Connecting to SPUPS... `n"
	$mysiteurl = "http://centraladmin:port"
	$IdPName = "REDACTED"
	$site = new-object microsoft.sharepoint.spsite($mysiteurl)
	$servicecontext = get-spservicecontext($site)
	$upm = new-object microsoft.office.server.userprofiles.userprofilemanager($servicecontext) 


	
	## 3. Query EntraID
	<#Original, working for FULL
	    $tsStart = get-date -format "hh:mm:ss"
	    WriteLog "Query EntraID - Start - $tsStart"
	    $EntraUsers = get-mgUser -All -Property UserPrincipalName, displayName, mail, givenName, surName, lastUpdatedDateTime | Where-Object {$_.UserPrincipalName -like "*#EXT#*"}
	    $userCount = $EntraUsers.count
	    $tsEnd = get-date -format "hh:mm:ss"
	    $dur = new-timespan -start $tsStart -end $tsEnd
	    WriteLog "Query EntraID - End - $tsEnd"
	    WriteLog "  - $userCount Total EXT Users"
	    WriteLog "  - Duration: $dur"
	#>

    function Add-MGUsersToUpdate {
	    param(
    	    [Parameter(Mandatory = $true, HelpMessage = 'Response from Invoke-MgGraphRequest -Method GET -Uri graph.microsoft.com')]
    	    [Hashtable]$RequestResponse
	    )

	    foreach ($item in $RequestResponse.value) {
            $businessphone = if($item.Businessphones.count -eq 0){$null} else {$item.BusinessPhones[0]}
    	    $global:UsersToUpdate += [PSCustomObject]@{
        	    ID = $item.id           	 
        	    userPrincipalName = $item.userPrincipalName
        	    displayName = $item.displayName
        	    mail = $item.mail
        	    givenName = $item.givenName
        	    surname = $item.surname
                department = $item.department
                employeeType = $item.employeeType
                jobTitle = $item.jobTitle
                companyName = $item.companyName
                officeLocation = $item.officeLocation
                mobilePhone = $item.mobilePhone
                businessPhone = $businessphone
    	    }
	    }
    }
    
    $tsStart = get-date -format "hh:mm:ss"
	WriteLog "Query EntraID - Start - $tsStart"

    $global:UsersToUpdate = @()
    $DeltaLinkPath = "E:\ScheduledTasks\SP_EntraID_Profile_Sync_DeltaLink.txt"
    $DeltaLink = Get-Content $DeltaLinkPath -ErrorAction SilentlyContinue
        
    #If Deltalink does NOT exist, performs a FULL sync. NOTE: DELTA LINKS ARE ONLY GOOD FOR 7 DAYS.
        if( !$DeltaLink ) { 
            WriteLog "`nQuery EntraID - ERROR - $tsStart - No Delta Link Found. Beginning Delta Query. This may take some time...`n"
            $Request = Invoke-MgGraphRequest -Method GET -Uri ('https://graph.microsoft.com/beta/users/delta?$select=UserPrincipalName,displayname,mail,givenname,surname,department,employeeType,jobTitle,companyName,officeLocation,mobilePhone,businessPhones')
            
            Add-MGUsersToUpdate -RequestResponse $Request
        }
    #IF Deltalink DOES exist, performs a Delta sync
        elseif( $DeltaLink ) {
            WriteLog "`nQuery EntraID - Delta Link exists. Using preexisting link to pull profiles with updates.`n"
            $Request = Invoke-MgGraphRequest -Method GET -Uri $DeltaLink
            Add-MGUsersToUpdate -RequestResponse $Request
        }
    #CONT of both a FULL and DELTA sync. Loops until "deltaLink" is identified in the request, which signifies that's the final NextLink.
        $loopcount = 1 #1, not 0, because the if/elseif is #1. 
        while(!$Request.'@odata.deltaLink'){
            $loopcount ++
            WriteLog "`n - Calling @odata.nextLink - Count $loopcount"
            $Request = Invoke-MgGraphRequest -Method GET -Uri $Request.'@odata.nextLink'
            Add-MGUsersToUpdate -RequestResponse $Request
        }

    #Write New Delta Link to file.
        WriteLog "`nQuery EntraID - End - $tsEnd"
        WriteLog "  - New Delta Link Written to File: $DeltaLinkPath"
        $request.'@odata.deltaLink' | Out-File $DeltaLinkPath -Force
        
    #Filter user list
        WriteLog "`n Filter Users to Update - Pre-filter count = $($UsersToUpdate.count)"
        $UsersToUpdate = $UsersToUpdate | Where-Object {$NULL -ne $_.Mail}
        WriteLog "  - After Filtering users with a valid Mail = $($UsersToUpdate.Count)"

	## 4. Update SP Profile Database
	
	$tsStart = get-date -format "hh:mm:ss"
	WriteLog "`nUpdate SP Profiles - Start - $tsStart"
	
	$profilesUpdated=0
	$profilesAdded=0

	foreach($EntraUser in $UsersToUpdate){

		$claimPrincipal = New-SPClaimsPrincipal -ClaimValue $EntraUser.mail -ClaimType I -TrustedIdentityTokenIssuer $IdPName -IdentifierClaim

		if ($upm.UserExists($claimPrincipal.ToEncodedString())){
			$userProfile = $upm.GetUserProfile($claimPrincipal.ToEncodedString())
			
			# Exists, Check if update needed
			if( $userProfile["FirstName"].Value -ne $EntraUser.givenName `
                -or $userProfile["LastName"].Value -ne $EntraUser.surName `
                -or	$userProfile["PreferredName"].Value -ne $EntraUser.displayName `
                -or $userProfile["WorkEmail"].Value -ne $EntraUser.mail `
                -or $userprofile["Department"].Value -ne $EntraUser.department `
                -or $userprofile["employeeType"].Value -ne $EntraUser.employeeType `
                -or $userProfile["SPS-jobTitle"].Value -ne $EntraUser.jobTitle `
                -or $userProfile["companyName"].Value -ne $EntraUser.companyName `
                -or $userProfile["SPS-Location"].Value -ne $EntraUser.officeLocation `
                -or $userProfile["CellPhone"].Value -ne $EntraUser.mobilePhone `
                -or $userProfile["WorkPhone"].Value -ne $EntraUser.businessPhone `
                -or $userProfile["GraphID"].Value -ne $EntraUser.ID
               ) {
				    $userProfile["FirstName"].Value = $EntraUser.givenName
				    $userProfile["LastName"].Value = $EntraUser.surName
				    $userProfile["PreferredName"].Value = $EntraUser.displayName
				    $userProfile["WorkEmail"].Value = $EntraUser.mail
                    $userProfile["Department"].Value = $EntraUser.department
                    $userProfile["employeeType"].Value = $EntraUser.employeeType
                    $userProfile["SPS-jobTitle"].Value = $EntraUser.jobTitle
                    $userProfile["companyName"].Value = $EntraUser.companyName
                    $userProfile["SPS-Location"].Value = $EntraUser.officeLocation
                    $userProfile["CellPhone"].Value = $EntraUser.mobilePhone
                    $userProfile["WorkPhone"].Value = $EntraUser.businessPhone
                    $userProfile["GraphID"].Value = $EntraUser.ID
				    $userProfile.Commit();
				    $profilesUpdated++;
				    WriteLog "  - UPDATE - $($EntraUser.UserPrincipalName)"
			}
		}
		# Doesn't Exist, Create Profile
		else{
			$userProfile = $upm.createuserprofile($claimPrincipal.ToEncodedString())
			$userProfile["SPS-ClaimID"].Value = $EntraUser.mail
			$userProfile["SPS-ClaimProviderID"].Value = $IdPName
			$userProfile["SPS-ClaimProviderType"].Value = "Trusted"
			$userProfile["SPS-UserPrincipalName"].Value = $EntraUser.UserPrincipalName
			$userProfile["SPS-DistinguishedName"].Value = $EntraUser.UserPrincipalName
			$userProfile["FirstName"].Value = $EntraUser.givenName
			$userProfile["LastName"].Value = $EntraUser.surName
			$userProfile["PreferredName"].Value = $EntraUser.displayName
			$userProfile["WorkEmail"].Value = $EntraUser.mail
            $userProfile["Department"].Value = $EntraUser.department
            $userProfile["employeeType"].Value = $EntraUser.employeeType
            $userProfile["SPS-jobTitle"].Value = $EntraUser.jobTitle
            $userProfile["companyName"].Value = $EntraUser.companyName
            $userProfile["SPS-Location"].Value = $EntraUser.officeLocation
            $userProfile["CellPhone"].Value = $EntraUser.mobilePhone
            $userProfile["WorkPhone"].Value = $EntraUser.businessPhone
            $userProfile["GraphID"].Value = $EntraUser.ID
			$userProfile.Commit();
			$profilesAdded++;
			WriteLog "  - ADD - $($EntraUser.UserPrincipalName)"
		}
		
	}
	
	$tsEnd = get-date -format "hh:mm:ss"
	$dur = new-timespan -start $tsStart -end $tsEnd
	WriteLog "Update SP Profiles - End - $tsEnd"
	WriteLog "$profilesAdded Added, $profilesUpdated Updated"
	WriteLog "  - Duration: $dur `n`n"
	SaveLog 1 "Operation completed successfully"
}
catch{
	SaveLog 101 "ERROR" $_.Exception
}


