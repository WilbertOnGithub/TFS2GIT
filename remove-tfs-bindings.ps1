$folder = pwd;

#first clear the read-only flag from all files
get-childitem "$folder" -Recurse | % {         
	# Test for ReadOnly flag and remove if present 
	if ($_.attributes -band [system.IO.FileAttributes]::ReadOnly) {  
		$_.attributes = $_.attributes -bxor [system.IO.FileAttributes]::ReadOnly
	}
}

#next delete all files that are *.suo, *.user, and *.*scc - we don't want thim in TFS
Get-ChildItem  $folder *.suo -Recurse -Force | Remove-Item -Force
Get-ChildItem  $folder *.*scc -Recurse -Force | Remove-Item -Force
Get-ChildItem  $folder *.user -Recurse -Force | Remove-Item -Force

#next get all the .sln file - and remove the VSS binding information
Get-ChildItem $folder *.sln -Recurse | foreach {
	$file = $_
	echo "Opening $file"
	$fileout = $file.FullName + ".new"
	Set-Content $fileout $null
	$switch=0
	Get-Content $file.FullName | foreach {
		if ($switch -eq 0) {
			if ($_.Contains("GlobalSection(TeamFoundationVersionControl) = preSolution")) {
				#we found the section to skip - so set the flag and don't copy the content
				echo "Found TFS Section"
				$switch=1
			}
			else {
				#we haven't found it yet - so copy the content
				Add-Content $fileout $_
			}        
		}
		elseif ($switch -eq 1) {
			if ($_.Contains("EndGlobalSection")) {
				#last line to skip - after it we start writing the content again
				$switch=2
			}
		}
		else { 
			#write remaining lines
			Add-Content $fileout $_
		}
	}
	
	#remove the original .sln and rename the new one
	$newname = $file.Name
	Remove-Item $file.FullName
	Rename-Item $fileout -NewName $newname
}
