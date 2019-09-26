<## Async implemented via runspaces. ##>

# Set Requires
#Requires -Version 6.2

using namespace System # To access IAsyncResult
using namespace System.Collections # To access Queue
using namespace System.Management.Automation.Runspaces # To access InitialSessionState, RunspacePool

# Set global variables
[InitialSessionState]$script:InitialSessionState = [InitialSessionState]::CreateDefault() # Create initiale session state

<## Contains information about threads. ##>
class Thread {
	# Class properties
	[ScriptBlock]$Function # `[ScriptBlock].isValueType` is `False`, thus it is OK to store it here, and it should not take space
	[Int]$Id # Numeric ID, representing the index of this thread within the thread pool
	[PowerShell]$PowerShell # Actually where execution will take place
	[String]$ProgressActivity = "General processing" # The operation to report with Progress
	[String]$ProgressOperation = "General operation"
	[Int]$ProgressPercent = 0
	[Int]$ProgressSeconds = -1 # Seconds remaining, "-1" stands for undefined
	[String]$ProgressStatus = "Initializing" # We do not want the default status to display anything
	[ThreadPool]$ThreadPool # The associated thread pool
	[IAsyncResult]$AsyncResult # Holds async data for running thread

	# Constructs the bare minimum for the thread to be ready to be initialized
	Thread([ScriptBlock]$Function) {
		# Set Function
		$this.Function = $Function
	}

	# Constructs a thread
	Thread([ScriptBlock]$Function, [String]$ProgressActivity) {
		# Call primary constructor
		$this.Thread($Function)

		# Set progress activity
		$this.ProgressActivity = $ProgressActivity
	}

	<## Enqueues progress to the queue.

	Note, this was written, when classes did not support optional parameters in methods.
	
	** Usage - Parameter example **

	@{
		ProgressOperation = "General operation"
		ProgressPercent   = 0
		SecondsRemaining  = -1
		ProgressStatus    = Processing
	} ##>

	[Void]EnqueueProgress([Hashtable]$ProgressInfo) {
		$ProgressInfo.ThreadId = $this.Thread
		$this.ThreadPool.ProgressQueue.Enqueue($ProgressInfo)
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
		3
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

	<## Cleans up. ##>
	[Void]Remove() {
		$this.PowerShell.Dispose()
	}
	
	<## Begins the execution of the thread. ##>
	[Void]Start() {
		$this.AsyncResult = $this.PowerShell.BeginInvoke()
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
	[Int]$Id = 0 # Id, used for the progress reporting
	[String]$ProgressActivity = "General processing"
	[String]$ProgressOperation = "General operation"
	[Int]$ProgressPercent = 0
	[Int]$ProgressSeconds = -1 # Seconds remaining, "-1" stands for undefined
	[String]$ProgressStatus = "Initializing"
	[Queue]$ProgressQueue # A queue to store progress reporting	
	[RunspacePool]$RunspacePool
	[Int]$SleepTime = 100 # Number of milliseconds to sleep between thread updates
	[Thread[]]$ThreadArray # Array of threads

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

	<## Constructor, with customized optional properties ##>
	ThreadPool([Thread[]]$ThreadArray, [String]$ProgressActivity, [Int]$Id, [Int]$SleepTime) {
		# Call primary constructor
		$this.ThreadPool($ThreadArray)

		# Set the activity
		$this.ProgressActivity = $ProgressActivity

		# Set the Id
		$this.Id = $Id

		# Set sleep time
		$this.SleepTime = $SleepTime
	}

	<## Dequeues the progress queue, and updates the respective thread. ##>
	[Void]DequeueProgress() {
		# Dequeue
		$hash = $this.ProgressQueue.Dequeue()

		# Assign Thread for quick access
		$Thread = $this.ThreadArray[$hash.ThreadId]

		# Process the current operation
		$Thread.ProgressOperation =	"General operation"
		if ($hash.CurrentOperation -is [String]) {
			$Thread.ProgressOperation = $hash.CurrentOperation
		}

		# Process percent
		$Thread.ProgressPercent =	0
		if ($hash.PercentComplete -is [Int]) {
			if ($hash.PercentComplete -ge 0 -and $hash.PercentComplete -le 100) {
				$Thread.ProgressPercent = $hash.PercentComplete
			}
		}

		# Process seconds
		$Thread.ProgressSeconds =	0
		if ($hash.SecondsRemaining -is [Int]) {
			$Thread.ProgressSeconds = $hash.SecondsRemaining
		}

		# Process the status
		$Thread.ProgressStatus = "Processing"
		if ($hash.Status -is [String]) {
			$Thread.ProgressStatus = $hash.Status
		}
	}

	<## Reads the queue and updates thread info. ##>
	[Void]ReadProgressQueue() {
		while ($this.ProgressQueue.Count -gt 0) {
			$this.ProgressQueue.Dequeue()
		}
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

	<# Ends all the progress bars. #>
	[Void]StopProgress() {
		# Actually write from the current registered thread state
		$this.ThreadArray | ForEach-Object -Process {
			Write-Progress -Activity $this.ProgressActivity `
				-CurrentOperation $_.ProgressOperation `
				-Status Finalizing `
				-PercentComplete 100 `
				-ParentId $this.Id `
				-Id $this.Id $_.ThreadId `
				-SecondsRemaining 0 `
				-Completed
		}

		# Write pool's progress first
		Write-Progress -Activity $this.ProgressActivity `
			-CurrentOperation $this.ProgressOperation `
			-Status Finalizing `
			-PercentComplete 100 `
			-Id $this.Id `
			-SecondsRemaining 0 `
			-Completed
	}

	<# Updates the progress to the console. #>
	[Void]UpdateProgress() {
		# Write pool's progress first
		Write-Progress -Activity $this.ProgressActivity `
			-CurrentOperation $this.ProgressOperation `
			-Status $this.ProgressStatus `
			-PercentComplete $this.ProgressPercent `
			-Id $this.Id `
			-SecondsRemaining $this.ProgressSeconds

		# Actually write from the current registered thread state
		$this.ThreadArray | ForEach-Object -Process {
			Write-Progress -Activity $_.ProgressActivity `
				-CurrentOperation $_.ProgressOperation `
				-Status $_.ProgressOperation `
				-PercentComplete $_.ProgressPercent `
				-ParentId $this.Id `
				-Id $this.Id * $_.ThreadId `
				-SecondsRemaining $_.ProgressSeconds
		}
	}

	<## Waits for all the threads to complete. ##>
	[Void]Wait() {
		# Iterate through threads
		$this.ThreadArray | ForEach-Object -Process {
			$_.Wait()
		}
	}

	<## Waits and writes the progress to the console. ##>
	[Void]WaitAndWriteProgress() {
		# Firstly immediately report the progress
		$this.UpdateProgress()

		# Read from the queues
		$this.ReadProgressQueue()

		while (($this.ThreadArray | Select-Object -Property AsyncResult | Select-Object -Property IsCompleted) -notcontains "Completed") {
			# Update the progress
			$this.UpdateProgress()

			# Sleep
			Start-Sleep -Milliseconds $this.SleepTime
		}

		# Finally wait for all
		$this.Wait()

		# Finally close all the progresses
		$this.StopProgress()
	}
}