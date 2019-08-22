# Script for initializing a TypeScript repository. Written for Powershell Core 6.2. Takes in "origanization" and "repository" YAML files.

# Set global variables
$CurrentDirectory = (Get-Location).Path
$ScriptDirectory = $PSScriptRoot

# Installs yaml parser in current directory
function InstallYAMLParserInCurrentDirectory { 
	# Set flag that YAML parser already installed
	$exists = False
	
	# List the installed packages
	$NPMList = npm list --json | ConvertFrom-Json

	# Determine if exists
	if ("dependencies" -in (Get-Member -InputObject $NPMList -MemberType Property)) {
		if ("js-yaml" -in (Get-Member -InputObject $NPMList.dependencies -MemberType Property)) {
			$exists = True
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

# Install YAML parser if necessary
InstallYAMLParserInCurrentDirectory

# Set location to original
Set-Location -Path $CurrentDirectory