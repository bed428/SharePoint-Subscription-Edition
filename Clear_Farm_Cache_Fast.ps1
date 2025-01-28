


function timerServiceAll($action){
	foreach ($server in $global:servers)
	{
		$servername = $server.Address
		write-host "$action Timer Service on server $servername" -fore yellow
		if($action -like "stop"){ (Get-WmiObject Win32_Service -filter "name='SPTimerV4'" -ComputerName $servername).stopservice() | Out-Null }
		elseif($action -like "start"){ (Get-WmiObject Win32_Service -filter "name='SPTimerV4'" -ComputerName $servername).startservice() | Out-Null }
	}
	write-host ""
}

function clearCacheAll{

	$clearCacheSB = {
		$serverpath = $args[0]
		$servername = $args[1]
		
		$folders = Get-ChildItem ("\\" + $serverpath + "\C$\ProgramData\Microsoft\SharePoint\Config") | ?{$_.Name -like "*-*"}

		foreach ($folder in $folders){
			$items = Get-ChildItem $folder.FullName -Recurse
			foreach ($item in $items){
				if ($item.Name.ToLower() -eq "cache.ini"){
					$cachefolder = $folder.FullName
				}
			}
		}

		$cachefolderitems = Get-ChildItem $cachefolder -Recurse
		foreach ($cachefolderitem in $cachefolderitems){
			if ($cachefolderitem -like "*.xml"){
				$cachefolderitem.Delete()
			}
		}
		$a = Get-Content $cachefolder\cache.ini
		$a = 1
		Set-Content $a -Path $cachefolder\cache.ini
	}

	# Start all Jobs
	foreach($server in $global:servers){
		$serverpath = $server.Address
		$servername = $server.Name
		start-job -name $jobname -scriptblock $clearCacheSB -ArgumentList $serverpath, $servername
	}
	
	# Wait for all jobs to complete
	$count = 0;
	Do{ 
	    $count++; start-sleep -s 5;
		$runningCnt = @(get-job | ?{$_.State -ne "Completed"}).Count	
		write-host "  waiting - $runningCnt still running"
	}
	Until($runningCnt -eq 0 -or $count -eq 60 )
	write-host "  Finished"

	get-job | remove-job
}


function iisResetAll{

	$iisResetSB = {
		$serverpath = $args[0]
		$servername = $args[1]
		
		Do{
			$result = invoke-command -computername $servername {cd C:\Windows\System32\; ./cmd.exe /c 'iisreset'; $lastexitcode}
			write-host $result
			$exitcode = $result[-1]
		} 
		While($exitcode -gt 0)
	}


	foreach($server in $global:servers){
		$serverpath = $server.Address
		$servername = $server.Name
		start-job -scriptblock $iisResetSB -ArgumentList $serverpath, $servername
	}

	# Wait for all jobs to complete
	$count = 0;
	Do{ 
	    $count++; start-sleep -s 5;
		$runningCnt = @(get-job | ?{$_.State -ne "Completed"}).Count	
		write-host "  waiting - $runningCnt still running"
	}
	Until($runningCnt -eq 0 -or $count -eq 60 )
	write-host "  Finished"

	get-job | remove-job
}






### Main

Add-PSSnapin -Name Microsoft.SharePoint.PowerShell -erroraction SilentlyContinue
$global:servers = get-spserver | ?{$_.role -like "*Application*" -or $_.role -like "*Web*" -or $_.role -like "*Custom*"}
write-host "CLEAR CONFIG CACHE ON FARM" -fore green

timerServiceAll "Stop"
clearCacheAll
iisResetAll
timerServiceAll "Start"




