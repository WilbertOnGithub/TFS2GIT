# Script that copies the history of an entire Team Foundation Server repository to a Git repository.
# Original author: Wilbert van Dolleweerd (wilbert@arentheym.com)
#
# Contributions from:
# - Patrick Slagmeulen
# - Tim Kellogg (timothy.kellogg@gmail.com)
# - Mike Glenn (mglenn@ilude.com)
#
# Assumptions:
# - MSysgit is installed and in the PATH 
# - Team Foundation commandline tooling is installed and in the PATH (tf.exe)

Param
(
	[Parameter(Mandatory = $True)]
	[string]$TFSRepository,
	[string]$Server,
	[string]$GitRepository = "",
	[string]$WorkspaceName = "TFS2GIT",
	[int]$StartingCommit,
	[int]$EndingCommit,
	[string]$UserMappingFile,
	
	# create lightweight tags on the first and list imported commits
	[switch]$t
)

function Exec([scriptblock]$cmd, [string]$errorMessage = "Error executing command: " + $cmd) {
  & $cmd
  if ($LastExitCode -ne 0) {
    throw $errorMessage
  }
}

function CheckPath([string]$program) 
{
	$count = (gcm -CommandType Application $program -ea 0 | Measure-Object).Count
	if($count -le 0)
	{
		Write-Host "$program must be found in the PATH!"
		Write-Host "Aborting..."
		exit
	}
}

# Do some sanity checks on specific parameters.
function CheckParameters
{
	if($Script:GitRepository -eq "") {
		$index = $TFSRepository.LastIndexOf("/") + 1;
		$Script:GitRepository = $TFSRepository.SubString($index, $TFSRepository.Length - $index) + ".git";
	}
	
	Write-Host "Git Repo will be named: $Script:GitRepository"

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
		if ($ChangeSet.ChangeSet -eq $StartingCommit)
		{
			$StartingCommitFound = $true
		}
		if ($ChangeSet.ChangeSet -eq $EndingCommit)
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
	return  GetAllChangeSetsFromHistory | Where-Object {($_.ChangeSet -ge $StartingCommit) -and ($_.ChangeSet -le $EndingCommit)}
}


function GetTemporaryDirectory
{
	return $env:temp + "\workspace"
}

# Creates a hashtable with the user account name as key and the name/email address as value
function GetUserMapping
{
	$UserMapping = @{}

	if ((Test-Path $UserMappingFile))
	{
		Write-Host "Reading user mapping file" $UserMappingFile
		Get-Content $UserMappingFile | foreach { [regex]::Matches($_, "^([^=#]+)=(.*)$") } | foreach { $userMapping[$_.Groups[1].Value] = $_.Groups[2].Value }
		#foreach ($key in $userMapping.Keys) 
		#{
		#	Write-Host $key "=>" $userMapping[$key]
		#}
	}	
	else {
		Write-Host "Could not read user mapping file" $UserMappingFile
	}

	return $UserMapping
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
	
	Write-Host "Creating TFS workspace for $TFSRepository"

	# Create the workspace and map it to the temporary directory we just created.
	exec { tf workspace /delete $TFSServer $WorkspaceName /noprompt | Out-null }
	exec { tf workspace /new $TFSServer /noprompt /comment:"Temporary workspace for converting a TFS repository to Git" $WorkspaceName }
	exec { tf workfold /unmap $TFSServer /workspace:$WorkspaceName $/ }
	exec { tf workfold /map $TFSServer /workspace:$WorkspaceName $TFSRepository $TempDir }
}


# Retrieve the history from Team Foundation Server, parse it line by line, 
# and use a regular expression to retrieve the individual changeset numbers.
function GetAllChangesetsFromHistory 
{
	# read the usermapping file.
	$UserMapping = GetUserMapping

	Write-Host "Retrieving history for $TFSRepository"
	
	$content = tf history $TFSServer $TFSRepository /recursive /noprompt /format:detailed | Out-String 

	$msg = $content -split "^-{100,}", 0, "multiline"
	
	$sets = @()

	$msg | Where-Object { $_.Length -gt 0 } | ForEach-Object {
		$changeset = ((Select-String -InputObject $_ -Pattern "(?m)^Changeset: (?<Changeset>.*)$")| select -expand Matches | foreach {$_.groups["Changeset"].value})
		$date = [DateTime]((Select-String -InputObject $_ -Pattern "(?m)^Date: (?<Date>.*)$")| select -expand Matches | foreach {$_.groups["Date"].value})
		$user = ((Select-String -InputObject $_ -Pattern "(?m)^User: (?:\w+\\)?(?<User>\w+)")| select -expand Matches | foreach {$_.groups["User"].value})
		$comment = [regex]::Match($_, "(?s)Comment:(?<Message>.*?)Items:").Groups[1].Value.Trim()
		
		if($comment -ne "") {
			$comment += "`n"
		}
		$comment += "Changeset: $changeset"
		
		$output = New-Object PsObject
		Add-Member -InputObject $output NoteProperty ChangeSet ([int]$changeset)
		Add-Member -InputObject $output NoteProperty Date ($date)
		Add-Member -InputObject $output NoteProperty Comment ($comment)
		Add-Member -InputObject $output NoteProperty FullMessage ($_.Trim())
		#Add-Member -InputObject $output NoteProperty TfsUser ($user)
		
		if($UserMapping.ContainsKey($user)){
			Add-Member -InputObject $output NoteProperty User ($userMapping[$user])
		}
		else {
			Add-Member -InputObject $output NoteProperty User ($user)
		}
		
		$sets += $output
	}

	return ($sets | Sort-Object -Property ChangeSet)
}

# Actual converting takes place here.
function Convert ([array]$ChangeSets)
{
	$TemporaryDirectory = GetTemporaryDirectory

	# Initialize a new git repository.
	Write-Host "Creating empty Git repository at $TemporaryDirectory"
	
	pushd $TemporaryDirectory
	
	git init -q

	# Create a gitignore file to keep TFS version control files, 
	# user files and cache files from being added to the new repo
@"
## Ignore Visual Studio temporary files, build results, and
## files generated by popular Visual Studio add-ons.
## https://github.com/github/gitignore

*.suo
*.user
*.cache
*.vssscc
*.vspscc
"@ | Out-File .gitignore -encoding ascii

	# Let git disregard casesensitivity for this repository (make it act like Windows).
	# Prevents problems when someones only changes case on a file or directory.
	git config core.ignorecase true

	$totalcount = $ChangeSets.length
	
	Write-Host "Preparing to retrieve $totalcount ChangeSets from $TFSRepository into $TemporaryDirectory"

	[bool]$RetrieveAll = $true
	[int]$count = 1
	$ChangeSets | Foreach-Object {
		$ChangeSet = $_
		$version = $ChangeSet.ChangeSet
		
		# Retrieve sources from TFS
		Write-Host "Retrieving changeset $version"  

		if ($count -eq 1)
		{
			# For the first changeset, we have to get everything.
			tf get $TemporaryDirectory /force /recursive /noprompt /version:C$version | Out-Null
			$RetrieveAll = $false
		}
		else
		{
			# Now, only get the changed files.
			tf get $TemporaryDirectory /recursive /noprompt /version:C$version | Out-Null
		}

		# Add sources to Git index
		git add -A | Out-Null
		
		$date = $ChangeSet.Date.ToString("ddd MMM d HH:mm:ss yyyy zz00")
		$user = $ChangeSet.User
		$ChangeSet.Comment | Out-File ..\commit.txt -encoding ascii 
		
		Write-Host "Commiting  changeset $version to git! ($count of $totalcount imported)"
		
		git commit -q --date `"$date`" --author `"$user`" -F ..\commit.txt 
		
		# if flag set create a lightweight tag on the first commit
		if($count -eq 1 -AND $t) {
			git tag Start-TFS-Import
		}
		
		# mom said clean up your room!
		rm ..\commit.txt
		
		$count++
	}
	
	# if flag set create a lightweight tag on the last commit
	if($t) {
		git tag End-TFS-Import
	}
	
	Write-Host "Running garbage collection on git repository!"
	
	git gc
	
	popd
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

	Write-Host "Removing workspace from TFS"
	tf workspace /delete $TFSServer $WorkspaceName /noprompt

	Write-Host "Removing working directories in" $TempDir
	Remove-Item -path $TempDir -force -recurse
}

# This is where all the fun starts...
function Main
{
	CheckPath("git.cmd")
	CheckPath("tf.exe")
	
	CheckParameters
	
	$TFSServer = ""
	if($Server -ne "") {
		$TFSServer = "/server:$Server"
	}
	
	PrepareWorkspace

	if ($StartingCommit -and $EndingCommit)
	{
		Write-Host "Filtering history..."
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
