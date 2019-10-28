<## Must be run as a script file.
Script for initializing a TypeScript repository. Written for Powershell Core 6.2.
Takes in "origanization" and "repository" YAML files. ##>

# Set Requires
#Requires -Version 6.0
# Requires -Modules Async

# Use modules
using module ./Async.psm1

# Set strict mode
Set-StrictMode -Version Latest

# Set global variables
[String]$script:ExecutionDirectory = (Get-Location).Path
[String]$script:ScriptDirectory = $PSScriptRoot

# Installs yaml parser in current directory
function InstallYAMLParserInCurrentDirectory([Thread]$Thread) {
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
		npm install js-yaml --no-save
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

# Preparation thread pool
$PreparationThreadPool = New-Object -TypeName ThreadPool -ArgumentList @(@(
		# Install YAML parser if necessary
		New-Object -TypeName Thread -ArgumentList @($function:InstallYAMLParserInCurrentDirectory)
	))
$PreparationThreadPool.Start()
$PreparationThreadPool.WaitAndWriteProgress()
$PreparationThreadPool.Remove()

# Set location to original
Set-Location -Path $ExecutionDirectory