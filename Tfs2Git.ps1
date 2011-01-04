# Script that copies the history of an entire Team Foundation Server repository to a Git repository.
# Original author: Wilbert van Dolleweerd (wilbert@arentheym.com)
#
# Contributions from:
# - Patrick Slagmeulen
# - Tim Kellogg (timothy.kellogg@gmail.com)
#
# Assumptions:
# - MSysgit is installed and in the PATH 
# - Team Foundation commandline tooling is installed and in the PATH (tf.exe)

Param
(
	[Parameter(Mandatory = $True)]
	[string]$TFSRepository,
	[string]$GitRepository = "ConvertedFromTFS",
	[string]$WorkspaceName = "TFS2GIT",
	[int]$StartingCommit,
	[int]$EndingCommit,
	[string]$UserFile
)

# Do some sanity checks on specific parameters.
function CheckParameters
{
	# If Starting and Ending commit are not used, simply ignore them.
	if (!$StartingCommit -and !$EndingCommit)
	{
		return;
	}

	if (!$StartingCommit -or !$EndingCommit)
	{
		Write-Host "You must supply values for both parameters StartingCommit and EndingCommit"
		Write-Host "Aborting..."
		exit
	}

	if ($EndingCommit -le $StartingCommit)
	{
		if ($EndingCommit -eq $StartingCommit)
		{
			Write-Host "Parameter StartingCommit" $StartingCommit "cannot have the same value as the parameter EndingCommit" $EndingCommit
			Write-Host "Aborting..."
			exit
		}

		Write-Host "Parameter EndingCommit" $EndingCommit "cannot have a lower value than parameter StartingCommit" $StartingCommit
		Write-Host "Aborting..."
		exit
	}
}

# When doing a partial import, check if specified commits are actually present in the history
function AreSpecifiedCommitsPresent([array]$ChangeSets)
{
	[bool]$StartingCommitFound = $false
	[bool]$EndingCommitFound = $false
	foreach ($ChangeSet in $ChangeSets)
	{
		if ($ChangeSet -eq $StartingCommit)
		{
			$StartingCommitFound = $true
		}
		if ($ChangeSet -eq $EndingCommit)
		{
			$EndingCommitFound = $true
		}
	}

	if (!$StartingCommitFound -or !$EndingCommitFound)
	{
		if (!$StartingCommitFound)
		{
			Write-Host "Specified starting commit" $StartingCommit "was not found in the history of" $TFSRepository
			Write-Host "Please check your starting commit parameter."
		}
		if (!$EndingCommitFound)
		{
			Write-Host "Specified ending commit" $EndingCommit "was not found in the history of" $TFSRepository
			Write-Host "Please check your ending commit parameter."			
		}

		Write-Host "Aborting..."		
		exit
	}
}

# Build an array of changesets that are between the starting and the ending commit.
function GetSpecifiedRangeFromHistory
{
	$ChangeSets = GetAllChangeSetsFromHistory

	# Create an array
	$FilteredChangeSets = @()

	foreach ($ChangeSet in $ChangeSets)
	{
		if (($ChangeSet -ge $StartingCommit) -and ($ChangeSet -le $EndingCommit))
		{
			$FilteredChangeSets = $FilteredChangeSets + $ChangeSet
		}
	}

	return $FilteredChangeSets
}


function GetTemporaryDirectory
{
	return $env:temp + "\workspace"
}

$userMapping = @{}
function PrepareUserMapping
{
	if ($UserFile -and $(Test-Path $UserFile)) 
	{
		Get-Content $UserFile | foreach { [regex]::Matches($_, "^([^=#]+)=(.*)$") } | foreach { $userMapping[$_.Groups[1].Value] = $_.Groups[2].Value }
	}
	foreach ($key in $userMapping.Keys) 
	{
		Write-Host $key "=>" $userMapping[$key]
	}
}

function PrepareWorkspace
{
	$TempDir = GetTemporaryDirectory

	# Remove the temporary directory if it already exists.
	if (Test-Path $TempDir)
	{
		remove-item -path $TempDir -force -recurse		
	}
	
	md $TempDir | Out-null

	# Create the workspace and map it to the temporary directory we just created.
	tf workspace /delete $WorkspaceName /noprompt
	tf workspace /new /noprompt /comment:"Temporary workspace for converting a TFS repository to Git" $WorkspaceName
	tf workfold /unmap /workspace:$WorkspaceName $/
	tf workfold /map /workspace:$WorkspaceName $TFSRepository $TempDir
}


# Retrieve the history from Team Foundation Server, parse it line by line, 
# and use a regular expression to retrieve the individual changeset numbers.
function GetAllChangesetsFromHistory 
{
	$HistoryFileName = "history.txt"

	tf history $TFSRepository /recursive /noprompt /format:brief | Out-File $HistoryFileName

	# Necessary, because Powershell has some 'issues' with current directory. 
	# See http://huddledmasses.org/powershell-power-user-tips-current-directory/
	$FileWithCurrentPath =  (Convert-Path (Get-Location -PSProvider FileSystem)) + "\" + $HistoryFileName 
	
	$file = [System.IO.File]::OpenText($FileWithCurrentPath)
	# Skip first two lines 
	$line = $file.ReadLine()
	$line = $file.ReadLine()

	while (!$file.EndOfStream)
	{
		$line = $file.ReadLine()
		# Match digits at the start of the line
		$num = [regex]::Match($line, "^\d+").Value
		$ChangeSets = $ChangeSets + @([System.Convert]::ToInt32($num))
	}
	$file.Close()

	# Sort them from low to high.
	$ChangeSets = $ChangeSets | Sort-Object			 

	return $ChangeSets
}

# Actual converting takes place here.
function Convert ([array]$ChangeSets)
{
	$TemporaryDirectory = GetTemporaryDirectory

	# Initialize a new git repository.
	Write-Host "Creating empty Git repository at", $TemporaryDirectory
	git init $TemporaryDirectory

	# Let git disregard casesensitivity for this repository (make it act like Windows).
	# Prevents problems when someones only changes case on a file or directory.
	git config core.ignorecase true

	[bool]$RetrieveAll = $true
	foreach ($ChangeSet in $ChangeSets)
	{
		# Retrieve sources from TFS
		Write-Host "Retrieving sources from", $TFSRepository, "in", $TemporaryDirectory
		Write-Host "This is changeset", $ChangeSet

		if ($RetrieveAll)
		{
			# For the first changeset, we have to get everything.
			tf get $TemporaryDirectory /force /recursive /noprompt /version:C$ChangeSet | Out-Null
			$RetrieveAll = $false
		}
		else
		{
			# Now, only get the changed files.
			tf get $TemporaryDirectory /recursive /noprompt /version:C$ChangeSet | Out-Null
		}


		# Add sources to Git
		Write-Host "Adding sources to Git repository"
		pushd $TemporaryDirectory
		git add . | Out-Null
		$CommitMessageFileName = "commitmessage.txt"
		GetCommitMessage $ChangeSet $CommitMessageFileName

		$commitMsg = Get-Content $CommitMessageFileName		
		$match = ([regex]'User: (\w+)').Match($commitMsg)
		if ($userMapping.Count -gt 0 -and $match.Success) 
		{	
			$author = $userMapping[$match.Groups[1].Value]
			Write-Host "Author is" $author
			git commit --file $CommitMessageFileName --author $author | Out-Null
		}
		else 
		{
			git commit --file $CommitMessageFileName | Out-Null
		}
		popd 
	}
}

# Retrieve the commit message for a specific changeset
function GetCommitMessage ([string]$ChangeSet, [string]$CommitMessageFileName)
{	
	tf changeset $ChangeSet /noprompt | Out-File $CommitMessageFileName -encoding utf8
}

# Clone the repository to the directory where you started the script.
function CloneToLocalBareRepository
{
	$TemporaryDirectory = GetTemporaryDirectory

	# If for some reason, old clone already exists, we remove it.
	if (Test-Path $GitRepository)
	{
		remove-item -path $GitRepository -force -recurse		
	}
	git clone --bare $TemporaryDirectory $GitRepository
	$(Get-Item -force $GitRepository).Attributes = "Normal"
	Write-Host "Your converted (bare) repository can be found in the" $GitRepository "directory."
}

# Clean up leftover directories and files.
function CleanUp
{
	$TempDir = GetTemporaryDirectory

	Write-Host "Removing workspace"
	tf workspace /delete $WorkspaceName /noprompt

	Write-Host "Removing working directories in" $TempDir
	Remove-Item -path $TempDir -force -recurse

	# Remove history file
	Remove-Item "history.txt"
}

# This is where all the fun starts...
function Main
{
	CheckParameters
	PrepareUserMapping
	PrepareWorkspace

	if ($StartingCommit -and $EndingCommit)
	{
		Write-Host "Filtering history...this may take a while"
		AreSpecifiedCommitsPresent(GetAllChangeSetsFromHistory)
		Convert(GetSpecifiedRangeFromHistory)
	}
	else
	{
		Convert(GetAllChangeSetsFromHistory)
	}

	CloneToLocalBareRepository
	CleanUp

	Write-Host "Done!"
}

Main
