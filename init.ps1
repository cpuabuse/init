# Script for initializing a TypeScript repository. Written for Powershell Core 6.2. Takes in "origanization" and "repository" YAML files.

$npm_init_name = $organization.name + "-" + $repository.name
$npm_init_version = "0.0.1"
$npm_init_description = $repository.description
$npm_init_main = "" # Always index.js
$npm_init_scripts = ConvertFrom-Json –InputObject $scripts
$npm_init_keywords = $repository.keywords
$npm_init_author = $organization.name
$npm_init_license = "" # ISC
$npm_init_bugs = "" # Information from the current directory, if present
$npm_init_homepage = "" # Information from the current directory, if present

npm init