<# Script for initializing a TypeScript repository. Written for Powershell Core 6.2.
Takes in "origanization" and "repository" YAML files. #>

# Set global variables
$ExecutionDirectory = (Get-Location).Path
$ScriptDirectory = $PSScriptRoot

<# Contains information for threads to be created.
ThreadInfo and Thread are separate due to the need to know the length of array during Thread initialization. #>
class ThreadInfo {
	# Class properties
	$ProgressActivity = "General processing"
	[Int]$ProgressId

	# Constructor for when only Id is provided
	ThreadInfo([Int]$ProgressId) {
		$this.Id = $ProgressId
	}

	# Constructor for when all the data is provided
	ThreadInfo([Int]$ProgressId, [String]$ProgressActivity) {
		$this.Id = $ProgressId
		$this.ProgressActivity = $ProgressActivity
	}
}

# Array holding thread information
$ThreadCounter = 0
[ThreadInfo[]]$ThreadInfoArray = [ThreadInfo]::new($ThreadCounter++, "YAML Parser")

# Prepare runspaces; Supplied with min and max instances count
$MainRunspacePool = [RunspaceFactory]::CreateRunspacePool($ThreadInfoArray.length, $ThreadInfoArray.length)

# Arrays holding thread abstraction

[PowerShell[]]$PowerShellArray

$ThreadInfoArray | ForEach-Object -Process {
	# Add a powershell instance to array
	$PowerShell = [PowerShell]::Create()

	# Associate PS instance with pool
	$PowerShell.RunspacePool = $MainRunspacePool

	# Add script to PS
	$PowerShell.AddScript(
		# Script body
		{
			# Declare params
			Param (
				[ThreadInfo]$ThreadInfo
			)
		}
	)
	$PowerShell.AddParameters($_)
}

# Open main pool
$MainRunspacePool.Open()

# Installs yaml parser in current directory
function InstallYAMLParserInCurrentDirectory {
	Write-Progress -Activity "Determining if YAML parser is installed..." -CurrentOperation current_op -Status curr_status -PercentComplete 20 -Id 1

	# Set flag that YAML parser already installed
	$exists = $false
	
	# List the installed packages
	$NPMList = npm list --json | ConvertFrom-Json

	# Determine if exists
	if ((Get-Member -InputObject $NPMList -MemberType NoteProperty -Name dependencies).length -gt 0) {
		if ((Get-Member -InputObject $NPMList.dependencies -MemberType NoteProperty -Name js-yaml).length -gt 0) {
			$exists = $true
		}
	}

	# Install parser, if doesn't exist
	if (!$exists) {
		npm install js-yaml --no-save 2> Out-Null
	}
}

# Initializes NPM
function InitializeNPM {
	$npm_init_name = $organization.name + "-" + $repository.name
	$npm_init_version = "0.0.1"
	$npm_init_description = $repository.description
	$npm_init_main = "" # Always index.js
	$npm_init_scripts = ConvertFrom-Json –InputObject $script
	$npm_init_keywords = $repository.keywords
	$npm_init_author = $organization.name
	$npm_init_license = "" # ISC
	$npm_init_bugs = "" # Information from the current directory, if present
	$npm_init_homepage = "" # Information from the current directory, if present

	npm init
}



# Set location to script
Set-Location -Path $ScriptDirectory

# Install YAML parser if necessary
InstallYAMLParserInCurrentDirectory

# Set location to original
Set-Location -Path $ExecutionDirectory