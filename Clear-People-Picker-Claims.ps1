#Search Terms because this is so silly: People Picker Stagnant Claims Provider Claim Remove Old 
#Apparently rebuilding whole web apps doesn't clear this. 

$WebApp = Get-SPWebApplication "Your Web App"

$WebApp.UseClaimsAuthentication = "$FALSE"
$WebApp.Update()

$WebApp = Get-SPWebApplication $WebApp
$WebApp.UseClaimsAuthentication = "$TRUE"
$WebApp.Update()

#.... that's it. That clears out the cached people picker claims I guess. Why would that do it and not rebuilding the whole web app? Who knows, SharePoint...
