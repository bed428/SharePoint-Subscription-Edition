###  SharePoint Farm Updates - Install & Run PS Config Wizard
    param($rebootNum=0)
    Set-ExecutionPolicy Bypass -Scope Process -confirm:$false -Force
    Add-PSSnapin "Microsoft.SharePoint.PowerShell" -ErrorAction SilentlyContinue
    $error.clear()


## Set Variables
    $farmName = "SPSE TEST"
    $taskRoot = "E:\ScheduledTasks\"
    $updateFileLoc = "C:\Folder\That\Contains\CU.exe,.msu";
    $psAcctName = "domain\account"
    $thisServer = $env:ComputerName
    $smtpServer = "smtp.domain.com"
    $emailTo = "to.email@domain.com"
    $emailFrom = "from.email@domain.com"


#region Functions
    Function LogWrite{
       Param ([string]$logstring)
       $timeStamp = get-date -format "yyyy-MM-dd  hh:mm:ss"
       $content = $timeStamp + "  " + $logstring
       Add-content $logfile -value $content
       write-host $content -for green
       $global:emailBody += "`n" + $content
    }
    function logError{
        if($error){
            $timeStamp = get-date -format "yyyy-MM-dd__hh-mm-sstt"
            $errorLog = $taskRoot + "SP_CumulativeUpdates\logs\errors\error_" + $timeStamp + ".log"
            $error | Out-String | Out-File $errorLog
            $error.clear()
        }
    }
    function get-availableUpdates{
        try{
       
            $updateList = @();
            $updatesAvailable = $false;
       
            foreach($server in $servers){
                $updateLoc = "\\" + $server + $updateFileLoc;
                Get-ChildItem -Path $updateloc | ?{$_.Name -match "uber-subscription" -and $_.Name -match ".*exe.*|.*msi.*"} | %{
                    $KB = "";
                    $_.Name.split("-") | %{
                        if($_ -like "kb*"){$KB = $_;}
                    }
                    if($KB -ne ""){
                        $filepath = $updateLoc + $_.Name
                        $updateList += [PSCustomObject]@{filename=$_.Name; kb=$KB; server=$server; filepath=$filepath}
                        $updatesAvailable = $true;
                    }
                }
            }
       
            if($updatesAvailable){
                $updateList = $updateList | sort-object kb -Unique
                return $updateList
            }
            else{
                return $false
            }
        }
        catch{
            LogWrite "  ERROR: function get-availableUpdates"
            logError
        }
    }
    function remove-File{
        Param([string] $filename)
   
        try{
            foreach($server in $servers){
                $filepath = "\\" + $server + $updateFileLoc + $filename
                if(Test-Path -path $filepath -PathType Leaf){
                    Remove-Item -Path $filepath
                    LogWrite "Removed File $filepath"
                }
            }


        }
        catch{
            LogWrite "  ERROR: function remove-Files"
            logError
        }
    }
    function Bindings(){
        try{
            return [System.Reflection.BindingFlags]::CreateInstance -bor
            [System.Reflection.BindingFlags]::GetField -bor
            [System.Reflection.BindingFlags]::Instance -bor
            [System.Reflection.BindingFlags]::NonPublic
        }
        catch{
            LogWrite "  ERROR: function Bindings"
            logError
        }
    }
    function GetFieldValue([object]$o, [string]$fieldName){
        try{
            $bindings = Bindings
            return $o.GetType().GetField($fieldName, $bindings).GetValue($o);
        }
        catch{
            LogWrite "  ERROR: function GetFieldValue"
            logError
        }
    }
    function get-InternalValue($obj, $propertyName){  
        try{
            if ($obj){  
                $type = $obj.GetType()  
                $property = $type.GetProperties([Reflection.BindingFlags] "Static,NonPublic,Instance,Public") | ? { $_.Name -eq $propertyName }      
                if ($property){  
                      $property.GetValue($obj, $null);  
                }  
            }  
        }
        catch{
            LogWrite "  ERROR: function get-InternalValue"
            logError
        }
    }  
    function installUpdateAll($f){
   
        try{
        # PSSession & Job Script Blocks
            $sesSB = {
                $f = $args[0]
                $jobSB = {
                    $f = $args[0]
               
                    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
                    $pinfo.FileName = $f
                    $pinfo.RedirectStandardError = $true
                    $pinfo.RedirectStandardOutput = $true
                    $pinfo.UseShellExecute = $false
                    $pinfo.WindowStyle = 'Hidden'
                    $pinfo.CreateNoWindow = $true
                    $pinfo.Arguments = "/quiet /passive /norestart"
                    $p = New-Object System.Diagnostics.Process
                    $p.StartInfo = $pinfo
                    $p.Start() | Out-Null
                    $stdout = $p.StandardOutput.ReadToEnd()
                    $stderr = $p.StandardError.ReadToEnd()
                    $p.WaitForExit()


                    $r = [PSCustomObject]@{server=$env:ComputerName; exitcode=$p.ExitCode; stdout=$stdout; stderr=$stderr }
                    write-output $r
                }
                start-job -name "PSJOB-SPUpdateInstall" -scriptblock $jobSB -ArgumentList $f
            }
       
            $s = New-PSSession -Credential $psCred -Authentication Kerberos -ComputerName $servers
            $j = Invoke-Command -Session $s -ScriptBlock $sesSB -ArgumentList $f
            $jrs = Invoke-Command -Session $s -ScriptBlock {get-job -Name "PSJOB-SPUpdateInstall" | Receive-Job -Wait -AutoRemoveJob}
            get-pssession | remove-pssession
       
            $results = @()
            foreach($r in $jrs){
                $s = $r.server
                $c = $r.exitcode
                if( $c -eq "0" ){
                    $results += [PSCustomObject]@{server=$s;result="Successfully Installed"}
                }
                elseif( " 17022 " -like "*$($c)*" ){
                    $results += [PSCustomObject]@{server=$s;result="Successfully Installed, Needs Reboot"}
                }
                elseif( " 17025 17028 " -like "*$($c)*" ){
                    $results += [PSCustomObject]@{server=$s;result="Already Installed / No Products Affected"}
                }
                else{
                    $results += [PSCustomObject]@{server=$s;result="Exit Code: $c"}
                }
            }
       
            return $results
        }
        catch{
            LogWrite "  ERROR: function installUpdate"
            logError
        }
    }
    function psConfigDBs{
        get-spcontentdatabase | %{
            LogWrite "   Upgrading DB: $($_.Name)"
            Upgrade-SPContentDatabase -Identity $_.Id -Confirm:$false
        }
    }
    function psConfigAll{
   
        try{
            $sesSB={
                $jobSB = {
                    Add-PSSnapIn Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue | Out-Null
                    $spVer = (Get-SPFarm).BuildVersion.Major
                    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
                    $pinfo.FileName = "C:\Program Files\Common Files\microsoft shared\Web Server Extensions\$spVer\BIN\psconfig.exe"
                    $pinfo.RedirectStandardError = $true
                    $pinfo.RedirectStandardOutput = $true
                    $pinfo.UseShellExecute = $false
                    $pinfo.WindowStyle = 'Hidden'
                    $pinfo.CreateNoWindow = $true
                    $pinfo.Arguments = "-cmd helpcollections -installall -cmd secureresources -cmd services -install -cmd installfeatures -cmd applicationcontent -install -cmd upgrade -inplace b2b -force -wait"
                    $p = New-Object System.Diagnostics.Process
                    $p.StartInfo = $pinfo
                    $p.Start() | Out-Null
                    $stdout = $p.StandardOutput.ReadToEnd()
                    $stderr = $p.StandardError.ReadToEnd()
                    $p.WaitForExit()
               
                    $failed = "na"
                    foreach($row in ($stdout -split "`r`n") | select -last 10){
                        if($row -like "Total number of unsuccessful configuration settings:*"){
                            $failed = ($row -split "Total number of unsuccessful configuration settings: ")[1].Trim()
                        }
                    }
               
                    $r = [PSCustomObject]@{exitcode=$p.ExitCode; stderr=$stderr; failed=$failed}
                    write-output $r
                }
                start-job -name "PSJOB-PSCONFIG" -scriptBlock $jobSB
            }
       
            function runPSConfig($pscServers){
                $global:runPSAgain = @()
                $global:psConfigErrTot = 0
                foreach($server in $pscServers){
                    LogWrite "    $server starting"
                    get-pssession | remove-pssession
                    $s = New-PSSession -Credential $psCred -Authentication Kerberos -ComputerName $server
                    $j = Invoke-Command -Session $s -ScriptBlock $sesSB
                    $r = Invoke-Command -Session $s -ScriptBlock {get-job -Name "PSJOB-PSCONFIG" | Receive-Job -Wait -AutoRemoveJob}
               
                    if($r.exitcode -eq 0 -and $r.failed -eq "0"){
                        LogWrite "    $server completed successfully"
                    }
                    else{
                        LogWrite "    $server completed with errors: exitcode:$($r.exitcode) failed settings:$($r.failed)"
                        LogWrite "        error msg: $($r.stderr)"
                        $global:runPSAgain += $server
                        $global:psConfigErrTot ++
                    }
                }
            }
       


            runPSConfig $servers
            if($global:runPSAgain.count -gt 0){
                runPSConfig $global:runPSAgain
            }
       
        }
        catch{
            LogWrite "  ERROR: function psConfigAll"
            logError
        }  
    }
    function restartThisServer{


        try{
            if($rebootNum -lt 4){
                $rebootNum = $rebootNum + 1
                $argStr = '-ExecutionPolicy Bypass -File "C:\scheduledTasks\SPUpdates\SPUpdates.ps1" -rebootNum $rebootNum'
                $Trigger = New-ScheduledTaskTrigger -RandomDelay (New-TimeSpan -Minutes 2) -AtStartup
                $Settings = New-ScheduledTaskSettingsSet -DontStopOnIdleEnd -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 10 -StartWhenAvailable
                $Settings.ExecutionTimeLimit = "PT0S"
                Register-ScheduledTask -TaskName "SP Patching - Continue after Reboot" -Action $Action -Trigger $Trigger -RunLevel Highest -User "SYSTEM" -Settings $Settings
           
                Restart-Computer
            }
            else{
                LogWrite " MAX REBOOT LIMIT REACHED - ABORTING SCRIPT"
            }
        }
        catch{
            LogWrite "  ERROR: function restartThisServer"
            logError
        }  
    }
#endregion Functions


#region LogWrite
    $logpath = $taskRoot + "SPCumulativeUpdates\Logs\"
    $logfile = $logpath + "SPUpdate_" + (get-date -format "yyyy-MM-dd") + ".log"
    Out-File -FilePath $logfile -Encoding UTF8 -Force
    $str = ""
    $global:emailBody = ""




    LogWrite " "
    if($rebootNum -gt 0){
        LogWrite "### SP UPDATES - START After Reboot ( $rebootNum )"
    }
    else{
        LogWrite "### SP UPDATES - START"
    }
    LogWrite "  SP Farm Build Version: $((get-spfarm).BuildVersion.ToString())"
#endregion LogWrite


#region Main Script
    try{
        # Remove any existing start-up task
        #unregister-scheduledTask -TaskName "SP Patching - Continue after Reboot" -ErrorAction SilentlyContinue -Confirm:$false


        # Get list of SP Servers
        $servers = @()
        Get-SPServer | ?{$_.Role -ne "Invalid"} | Select-Object Address | %{ $servers += $_.Address; }


        # Get Credentials
        $psAcct = get-spmanagedaccount $psAcctName
        $psSSec = (GetFieldValue $psAcct "m_Password").SecureStringValue
        $psCred = New-Object System.Management.Automation.PSCredential ($psAcctName, $psSSec)
   
        # Pause Search
        <#
        LogWrite "Pausing Search.."
        Get-SPEnterpriseSearchServiceApplication | Suspend-SPEnterpriseSearchServiceApplication
        LogWrite "Pausing Search Complete"
        #>
   


        # Get List of Available Updates
   
            # COPY FILES FROM NETWORK LOCATION :: If Update Location is a network Share, then copy files to SP Servers Temp folder, and set that as the update location
           
            #TODO: MAY NEED TO UPDATE THIS IF LIKE "\\*" LOGIC DEPENDING ON WHERE THE FINAL UPDATEFILELOC WILL BE.
            if($updateFileLoc -like "\\*"){
                $updateFileLocOrig = $updateFileLoc
                Get-ChildItem -Path $updateFileLoc | ?{$_.Name -match ".*uber-subscription.*" -and $_.Name -match ".*exe.*"} | %{
                    $sourceFile = $updateFileLoc + $_.Name
                    foreach($server in $servers){
                        $destLoc = "\\" + $server + "\c$\windows\temp\"
                        $destFile = $destLoc + $_.Name
                        if(!(test-path $destFile)){
                            Copy-Item -Path "Microsoft.PowerShell.Core\FileSystem::$sourceFile" -Destination "Microsoft.PowerShell.Core\FileSystem::$destLoc"
                        }
                    }
                }
                $updateFileLoc = "\c$\windows\temp\";
            }


        LogWrite ""
        LogWrite "SP Updates/Patches..."
        $updateList = get-availableUpdates
   
        if($updateList){
   
            $updateCount = @($updateList).count
            LogWrite "   Found $updateCount Available Updates"
       
            $sub = $farmname + " - SP Updates (1 of 4) - Installing $updateCount Updates"
            Send-MailMessage -From $emailFrom -To $emailTo -SmtpServer $smtpServer -Subject $sub -Body $global:emailBody
   
            # Install Updates on Servers (or verify already installed)
            foreach($update in $updateList){
           
                LogWrite "      $($update.kb)   $($update.filename)"
                $results = installUpdateAll $update.filepath
           
                $reboots = @();
                $removeFiles = @();
                $removeFile = $true;
                foreach($r in $results){
                    LogWrite "           $($r.server) : $($r.result)"
                    if($r.result -like "*Reboot*"){
                        $reboots += $r.server
                    }
                    if($r.result -like "*error*" -or $r.result -like "*unknown*" ){
                        $removeFile = $false
                    }
                }
           
                if($removeFile){
                    start-sleep -s 10
                    remove-File($update.filename)
                }


           
                if(@($reboots).count -gt 0){
                    $otherServers = $reboots | ?{$_ -ne $thisServer}
                    if(@($otherServers).count -gt 0){
                        $servStr = $otherServers -join ","
                        LogWrite "  Restarting $servStr"
                        Restart-Computer -ComputerName $otherServers -Wait -For PowerShell -Timeout 300 -Delay 2 -Force
                    }
                    if($reboots -contains $thisServer){
                        LogWrite "   Restarting this server - will re-run this script on Start Up"
                        restartThisServer
                        start-sleep -s 10
                        exit
                    }
                }
            }
       
       
            # REMOVE FILES FROM NETWORK LOCATION ::
            if($updateFileLocOrig -like "\\*"){
                start-sleep -s 10
                LogWrite ""
                Get-ChildItem -Path $updateFileLocOrig | ?{$_.Name -match ".*sts2016.*|.*wssloc2016.*" -and $_.Name -match ".*exe.*|.*msi.*"} | %{
                    $sourceFile = $updateFileLocOrig + $_.Name
                    Remove-Item -Path "Microsoft.PowerShell.Core\FileSystem::$sourceFile"
                    LogWrite "Removed File $sourceFile"
                }
            }
       
       
            # Run PSCONFIG on DBs
            $sub = $farmname + " - SP Updates (2 of 4) - Updating Content Databases"
            Send-MailMessage -From $emailFrom -To $emailTo -SmtpServer $smtpServer -Subject $sub -Body $global:emailBody
            LogWrite ""
            LogWrite "PSConfig Databases.."
            psConfigDBs
            LogWrite "PSConfig Databases Complete"
       
       
            # Run PSCONFIG on Servers
            $sub = $farmname + " - SP Updates (3 of 4) - Updating SP Servers"
            Send-MailMessage -From $emailFrom -To $emailTo -SmtpServer $smtpServer -Subject $sub -Body $global:emailBody
            LogWrite ""
            LogWrite "PSConfig Servers.."
            psConfigAll #HERE
            LogWrite "PSConfig Servers Complete - $($global:psConfigErrTot) Errors"
       
       
            # Get SP Build
            get-spproduct -local
            LogWrite ""
            LogWrite "  SP Farm Build Version: $((get-spfarm).BuildVersion.ToString())"
               
        }
        else{
            LogWrite "   No Available Updates Found"
        }
        LogWrite "SP Updates/Patches Complete"


   
        # Resume Search
        <#
        LogWrite "resuming Search"
        Get-SPEnterpriseSearchServiceApplication | Resume-SPEnterpriseSearchServiceApplication
        LogWrite "resuming Search Complete"
        #>




        # End Script - Send Email


        LogWrite "### SP UPDATES - END"
        LogWrite ""
        $sub = $farmname + " - SP Updates - Completed"
        Send-MailMessage -From $emailFrom -To $emailTo -SmtpServer $smtpServer -Subject $sub -Body $global:emailBody
    }
    catch{
        LogWrite "  ERROR: Main Script"
        logError
    }  
#endregion Main Script
