# Script that copies the history of an entire Team Foundation Server repository to a Git repository.
# Author: Wilbert van Dolleweerd
#
# Assumptions:
# - MSysgit is installed and in the PATH 
# - Team Foundation commandline tooling is installed and in the PATH (tf.exe)

Param
(
	[Parameter(Mandatory = $True)]
	[string]$TFSRepository,
	[string]$WorkspaceName = "TFS2GIT"
)

function GetTemporaryDirectory
{
	return $env:temp + "\workspace"
}

function PrepareWorkspace
{
	$TempDir = GetTemporaryDirectory

	if (Test-Path $TempDir)
	{
		remove-item -path $TempDir -force -recurse		
	}
	
	md $TempDir | Out-null

	tf workspace /delete $WorkspaceName /noprompt
	tf workspace /new /noprompt /comment:"Temporary workspace for converting a TFS repository to Git" $WorkspaceName
	tf workfold /unmap /workspace:$WorkspaceName $/
	tf workfold /map /workspace:$WorkspaceName $TFSRepository $TempDir
}

function GetChangesetsFromHistory 
{
	$HistoryFileName = "history.txt"

	tf history $TFSRepository /recursive /noprompt /format:brief | Out-File $HistoryFileName

	$History = Get-Content $HistoryFileName
	[array]$ChangeSets = [regex]::Matches($History, "\d{1,5}(?=\s{5}BC2SC)")

	$ChangeSets = $ChangeSets | Sort-Object			 

	return $ChangeSets			 
}

function GetSources ([array]$ChangeSets)
{
	$TemporaryDirectory = GetTemporaryDirectory

	Write-Host "Creating empty Git repository at", $TemporaryDirectory
	git init $TemporaryDirectory

	foreach ($ChangeSet in $ChangeSets)
	{
		# Delete any leftover directories 
		Get-Childitem -path $TemporaryDirectory -Recurse | Remove-Item -force -Recurse

		# Retrieve sources
		Write-Host "Retrieving sources from", $TFSRepository, "in", $TemporaryDirectory
		Write-Host "This is changeset", $ChangeSet
		tf get $TemporaryDirectory /overwrite /force /recursive /noprompt /version:C$ChangeSet 

		# Add sources to Git
		Write-Host "Adding sources to Git repository"
		pushd $TemporaryDirectory
		git add .
		$CommitMessage = "Changeset " + $ChangeSet
		git commit -a -m $CommitMessage 
		popd 
	}
}

function Main
{
	PrepareWorkspace
	GetSources(GetChangesetsFromHistory)
}

Main
