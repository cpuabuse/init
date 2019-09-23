<## Must be run as a script file.
Script for initializing a TypeScript repository. Written for Powershell Core 6.2.
Takes in "origanization" and "repository" YAML files. ##>

using namespace System # To access IAsyncResult
using namespace System.Collections # To access Queue
using namespace System.Management.Automation.Runspaces # To access InitialSessionState, RunspacePool

# Set global variables
[String]$script:ExecutionDirectory = (Get-Location).Path
[String]$script:ScriptDirectory = $PSScriptRoot
[InitialSessionState]$script:InitialSessionState = [InitialSessionState]::CreateDefault() # Create initiale session state

<## Contains information about threads. ##>
class Thread {
	# Class properties
	[ScriptBlock]$Function # `[ScriptBlock].isValueType` is `False`, thus it is OK to store it here, and it should not take space
	[Int]$Id # Numeric ID, representing the index of this thread within the thread pool
	[PowerShell]$PowerShell # Actually where execution will take place
	[String]$ProgressOperation # The operation to report with Progress
	[ThreadPool]$ThreadPool # The associated thread pool
	[IAsyncResult]$AsyncResult # Holds async data for running thread

	# Constructs the bare minimum for the thread to be ready to be initialized
	Thread([ScriptBlock]$Function, [String]$ProgressOperation) {
		# Set class members
		$this.Function = $Function
		$this.ProgressOperation = $ProgressOperation
	}

	<## Initializes the thread from the thread pool.

	** Lifecycle **

	1. New
	2. Initialzie
	3. Start
	4. Wait
	5. Remove

	** Thread signature **
	
	```powershell
	function MyFunction([Thread]$Thread){
		# Function body
	}
	```

	** About arguments**

	Varibable | Value type
	--- | ---
	[System.Collections.Queue].isValueType | False
	[ThreadPool].isValueType | False ##>
	[Void]Initialize([Int]$Id, [ThreadPool]$ThreadPool) {
		# Set ID
		$this.Id = $Id

		# Set thread pool
		$this.ThreadPool = $ThreadPool

		# Add a powershell instance
		$this.PowerShell = [PowerShell]::Create()

		# Associate PS instance with pool
		$this.PowerShell.RunspacePool = $ThreadPool.RunspacePool

		# Add script to PS
		$this.PowerShell.AddScript(
			# Script body
			{
				# Declare params
				Param (
					$Thread # Class type is not specified on purpose https://github.com/PowerShell/PowerShell/issues/3641
				)

				Invoke-Command -ScriptBlock $Thread.Function -ArgumentList $Thread
			}
		)
		$this.PowerShell.AddParameters(
			@{
				Thread = $this
			}
		)
	}

	<## Begins the execution of the thread. ##>
	[Void]Start() {
		$this.AsyncResult = $this.PowerShell.BeginInvoke()
	}

	<## Cleans up. ##>
	[Void]Remove() {
		$this.PowerShell.Dispose()
	}

	<## Waits for the operation to complete. ##>
	[Void]Wait() {
		# End invocation
		$this.PowerShell.EndInvoke($this.AsyncResult)
	}
}

<## Contains information about the thread pool.

** Lifecycle **

1. New
2. Start
3. Wait
4. Remove ##>
class ThreadPool {
	# Class properties
	[Thread[]]$ThreadArray # Array of threads
	[String]$ProgressActivity = "General processing"
	[Queue]$ProgressQueue # A queue to store progress reporting
	[RunspacePool]$RunspacePool

	# Primary constructor
	ThreadPool([Thread[]]$ThreadArray) {
		# Initialize thread array
		$this.ThreadArray = $ThreadArray

		# Determine thread array length
		$ThreadArrayLength = $this.ThreadArray.length

		# Create synchronized progress queue
		$this.ProgressQueue = [Queue]::Synchronized(
			(New-Object System.Collections.Queue)
		)

		# Initialize & open pool
		$this.RunspacePool = [RunspaceFactory]::CreateRunspacePool($script:InitialSessionState <# Accessing script scope, since cannot use global scope vars directly from class methods. #>)
		$this.RunspacePool.SetMinRunspaces($ThreadArrayLength)
		$this.RunspacePool.SetMaxRunspaces($ThreadArrayLength)
		$this.RunspacePool.Open()

		# Initialize threads
		for (
			$i = 0
			$i -lt $ThreadArrayLength
			$i++
		) {
			$this.ThreadArray[$i].Initialize($i, $this)
		}
	}

	<## Constructor, with custom progress activity name. ##>
	ThreadPool([String]$ProgressActivity, [Thread[]]$ThreadArray) {
		# Set the activity
		$this.$ProgressActivity = $ProgressActivity

		# Call primary constructor
		$this.ThreadPool($ThreadArray)
	}

	<## Cleans up. ##>
	[Void]Remove() {
		# Clean up threads first
		$this.ThreadArray | ForEach-Object -Process {
			$_.Remove()
		}

		# Deal with the pool
		$this.RunspacePool.Close() 
		$this.RunspacePool.Dispose()
	}

	<## Execute threads. ##>
	[Void]Start() {
		# Iterate through threads
		$this.ThreadArray | ForEach-Object -Process {
			$_.Start()
		}
	}

	<## Waits for all the threads to complete. ##>
	[Void]Wait() {
		# Iterate through threads
		$this.ThreadArray | ForEach-Object -Process {
			$_.Wait()
		}
	}
}

# Installs yaml parser in current directory
function InstallYAMLParserInCurrentDirectory {
	"test" > test.txt
	
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
$ThreadPool = [ThreadPool]::new(@([Thread]::new($function:InstallYAMLParserInCurrentDirectory, "test")))
$ThreadPool.Start()
$ThreadPool.Wait()

# Set location to original
Set-Location -Path $ExecutionDirectory