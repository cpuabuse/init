<#
	File: Async.psm1
	cpuabuse.com
#>

<##
 # Async implemented via runspaces.
 #
 # **Lifecycle notation**
 #
 # `{{ Stage }}` to be substituted with the stage name.
 #
 # Symbol | Meaning
 # --- | ---
 # `...{{ Stage }}` | Repeatable
 # `[{{ Stage }}]` | Optional
 #
 # **Note**
 #
 # - Can be run copy-pasted into console multiple times and used successfully as well.
 # - Can be imported via both `using module` ad `Import-module`.
 #     For `Import-module` can only use the helper functions, instead of directly manipulating classes.
 #>

# Set Requires
#Requires -Version 6.0

# Namespaces
using namespace System # To access IAsyncResult
using namespace System.Collections # To access Queue
using namespace System.Management.Automation.Runspaces # To access InitialSessionState, RunspacePool

<#
 # Represents the lifecycle of classes used in this module.
 #
 # The lifecycle allows the objects to be aware of their states, and gracefully process lifecycle related errors.
 #>
enum Lifecycle {
	New = 0x1
	Start = 0x1 -shl 1
	Update = 0x1 -shl 2
	Wait = 0x1 -shl 3
	Stop = 0x1 -shl 4
	Remove = 0x1 -shl 5
}

<#
	Guarded script consts.

	Checking the guard for the case that script is run multiple times inside of the console.
	ReadOnly is representation of semantic const.
	Enum type conversion validation already performs validation for enum values, including rejecting null.
	"[ValidateNotNull()]" is not used on the integer typed variables as well, as there is implicit conversion to 0 on null values. And same is equivalent and goes to positive validations for the [UInt].
#>
if ($null -eq (Get-Variable -Name "AsyncVariableGuard" -Scope "Script" -ErrorAction "Ignore")) {
	# Set the guard
	New-Variable -Name "AsyncVariableGuard" -Scope "Script"

	# Error messages
	[ValidateNotNullOrEmpty()][String]$script:ErrorProgressForbiddenMethod = "A method of 'Progress' class was invoked. That method is forbidden by current stage of object lifecycle."; `
		Set-Variable -Name "ErrorProgressForbiddenMethod" `
		-Description "Error text for lifecycle inconsistency." `
		-Option "ReadOnly" `
		-Scope "Script"
	[ValidateNotNullOrEmpty()][String]$script:ErrorThreadLikeForbiddenMethod = "A method of 'ThreadLike' class was invoked. That method is forbidden by current stage of object lifecycle."; `
		Set-Variable -Name "ErrorThreadLikeForbiddenMethod" `
		-Description "Error text for lifecycle inconsistency." `
		-Option "ReadOnly" `
		-Scope "Script"
	[ValidateNotNullOrEmpty()][String]$script:ErrorThreadPoolTooManyThreads = "Too many threads to assign to the pool."; `
		Set-Variable -Name "ErrorThreadPoolTooManyThreads" `
		-Description "The requested amount of the threads cannnot be represented by the integer variable type." `
		-Option "ReadOnly" `
		-Scope "Script"
	
	# Lifecycle costants
	[Lifecycle]$script:LifecycleNew = "New"; `
		Set-Variable -Name "LifecycleNew" `
		-Description "Enum value for the 'New' stage of lifecycle." `
		-Option "ReadOnly" `
		-Scope "Script"
	[Lifecycle]$script:LifecycleRemove = "Remove"; `
		Set-Variable -Name "LifecycleRemove" `
		-Description "Enum value for the 'Remove' stage of lifecycle." `
		-Option "ReadOnly" `
		-Scope "Script"
	[Lifecycle]$script:LifecycleStart = "Start"; `
		Set-Variable -Name "LifecycleStart" `
		-Description "Enum value for the 'Start' stage of lifecycle." `
		-Option "ReadOnly" `
		-Scope "Script"
	[Lifecycle]$script:LifecycleStop = "Stop"; `
		Set-Variable -Name "LifecycleStop" `
		-Description "Enum value for the 'Stop' stage of lifecycle." `
		-Option "ReadOnly" `
		-Scope "Script"
	[Lifecycle]$script:LifecycleUpdate = "Update"; `
		Set-Variable -Name "LifecycleUpdate" `
		-Description "Enum value for the 'Update' stage of lifecycle." `
		-Option "ReadOnly" `
		-Scope "Script"
	[Lifecycle]$script:LifecycleWait = "Wait"; `
		Set-Variable -Name "LifecycleWait" `
		-Description "Enum value for the 'Wait' stage of lifecycle." `
		-Option "ReadOnly" `
		-Scope "Script"

	# Progress class
	[ValidateNotNullOrEmpty()][String]$script:ProgressActivityInitial = "General processing"; `
		Set-Variable -Name "ProgressActivityInitial" `
		-Description "Initial operation string." `
		-Option "ReadOnly" `
		-Scope "Script"
	[ValidateNotNullOrEmpty()][String]$script:ProgressCurrentOperationInitial = "Generic operation"; `
		Set-Variable -Name "ProgressCurrentOperationInitial" `
		-Description "Initial operation string." `
		-Option "ReadOnly" `
		-Scope "Script"
	[Int32]$script:ProgressSecondsRemainingUndefined = -1; `
		Set-Variable -Name "ProgressSecondsRemainingUndefined" `
		-Description "Seconds remaining." `
		-Option "ReadOnly" `
		-Scope "Script"; `
		[Int32]$script:ProgressSecondsRemainingInitial = $script:ProgressSecondsRemainingUndefined; `
		Set-Variable -Name "ProgressSecondsRemainingUndefined" `
		-Description "Initial seconds remaining." `
		-Option "ReadOnly" `
		-Scope "Script" # `-1` is undefined (Int32)
	[ValidateNotNullOrEmpty()][String]$script:ProgressStatusInitial = "Initializing"; `
		Set-Variable -Name "ProgressStatusInitial" `
		-Description "Operation's initial status." `
		-Option "ReadOnly" `
		-Scope "Script"
	[ValidateNotNullOrEmpty()][String]$script:ProgressStatusDefault = "Processing"; `
		Set-Variable -Name "ProgressStatusDefault" `
		-Description "Operation's default status." `
		-Option "ReadOnly" `
		-Scope "Script"

	# `ThreadPoolPercentComplete` variables are added for logical checks of data received via hashtable queue, and they are separate to the range validators of the Progress class members.
	[ValidateRange(0, 100)][Int32]$script:ThreadPoolPercentCompleteDefault = 1; `
		Set-Variable -Name "ProgressPercentCompleteDefault" `
		-Description "Default minimum progress percentage, during processing." `
		-Option "ReadOnly" `
		-Scope "Script"
	[ValidateRange(0, 100)][Int32]$script:ThreadPoolPercentCompleteMaximum = 100; `
		Set-Variable -Name "ProgressPercentCompleteMaximum" `
		-Description "Maximum possible value, passing sanity check." `
		-Option "ReadOnly" `
		-Scope "Script" # Set in decimal, as it is a specific decimal value.
	[ValidateRange(0, 100)][Int32]$script:ThreadPoolPercentCompleteMinumum = 0; `
		Set-Variable -Name "ProgressPercentCompleteMinumum" `
		-Description "Minimum possible value, passing sanity check." `
		-Option "ReadOnly" `
		-Scope "Script"; `
		[ValidateRange(0, 100)][Int32]$script:ThreadPoolPercentCompleteInitial = $script:ProgressPercentCompleteMinumum; `
		Set-Variable -Name "ProgressPercentCompleteInitial" `
		-Description "Initial percentage." `
		-Option "ReadOnly" `
		-Scope "Script" # Set in decimal, as it is a specific decimal value.

	# Other ThreadPool variables
	[UInt]$script:ThreadPoolReadProgressQueueMaxIterations = 0x10; `
		Set-Variable  -Name "ThreadPoolReadProgressQueueMaxIterations" `
		-Description "The maximum amount of loops the dequeueing will do in `ReadProgressQueue` method of `ThreadPool` class." `
		-Option "ReadOnly" `
		-Scope "Script"
	[ValidateRange("NonNegative")][Int32]$script:ThreadPoolSleepMilliseconds = 0x80; `
		Set-Variable  -Name "ThreadPoolSleepMilliseconds" `
		-Description "Default amount of milliseconds to sleep between loop iterations." `
		-Option "ReadOnly" `
		-Scope "Script"
	[ValidateNotNull()][InitialSessionState]$script:ThreadPoolInitialSessionState = [InitialSessionState]::CreateDefault(); `
		Set-Variable -Name "ThreadPoolInitialSessionState" `
		-Description "Create initial session state." `
		-Option "ReadOnly" `
		-Scope "Script"
	[UInt16]$script:ThreadPoolProgressIdMaxThreads = [UInt16]::MaxValue; `
		Set-Variable -Name "ThreadPoolProgressIdMaxThreads" `
		-Description "Maximum number of threads allowed per pool." `
		-Option "ReadOnly" `
		-Scope "Script"
	[UInt]$script:ThreadPoolProgressIdShift = 16; `
		Set-Variable -Name "ThreadPoolProgressIdShift" `
		-Description "Half of `Int32` binary digit amount." `
		-Option "ReadOnly" `
		-Scope "Script"
	[UInt32]$script:ThreadPoolProgressIdUnsignedLimit = 0x1 -shl 32; `
		Set-Variable -Name "ThreadPoolProgressIdUnsignedLimit" `
		-Description "Start of second half of `UInt32` range." `
		-Option "ReadOnly" `
		-Scope "Script"

	# Set magic numbers
	[UInt]$script:UZero = [UInt16]$script:UZero16 = [Int32]$script:SZero32 = 0x0; `
		Set-Variable -Name "UZero" `
		-Description "Zero of [UInt]." `
		-Option "ReadOnly" `
		-Scope "Script"; `
		Set-Variable -Name "UZero16" `
		-Description "Zero of [UInt16]." `
		-Option "ReadOnly" `
		-Scope "Script"; `
		Set-Variable -Name "SZero32" `
		-Description "Zero of [Int32]." `
		-Option "ReadOnly" `
		-Scope "Script"
}

<##
 # Class representing a progress, a way to interact with it logically, translate to physical representation, and write progress to console.
 #
 # The string members of the class have `ValidateNotNullOrEmpty()` validator present, but the end-user should not have restrictions like that, so it is a class implementation's responsibility to perform null/empty checks.
 #
 # **Lifecycle**
 #
 # 1. New
 # 2. ...Call `UpdateProgress`
 # 3. Call `StopProgress`
 #>
class Progress {
	hidden [ValidateNotNullOrEmpty()][String]$ProgressActivity = $script:ProgressActivityInitial # The activity to report with Progress
	[ValidateNotNullOrEmpty()][String]$ProgressCurrentOperation = $script:ProgressCurrentOperationInitial # Operation name
	hidden [Int32]$ProgressId # Operation Id
	hidden [Lifecycle]$ProgressLifecycle # Lifecycle of the progress
	[ValidateRange(0, 100)][Int32]$ProgressPercentComplete = $script:ProgressPercentCompleteInitial # Percent complete
	[Int32]$ProgressSecondsRemaining = $script:ProgressSecondsRemainingInitial # Seconds remaining
	[ValidateNotNullOrEmpty()][String]$ProgressStatus = $script:ProgressStatusInitial # Operation status
	hidden [Boolean]$ProgressCompleted = $False # Not-completed initially

	<##
	 # Constructor, setting Id and activity.
	 #>
	Progress(
		<## Progress Id to set. #>
		[Int32]$ProgressId,
		<## Activity string. #>
		[String]$ProgressActivity
	) {
		# Set activity
		$this.ProgressActivity = $ProgressActivity

		# Set progress id
		$this.ProgressId = $ProgressId

		# Explicitly setting lifecycle
		$this.ProgressLifecycle = $script:LifecycleNew 
	}

	<## Set progress state to stopped. #>
	StopProgress() {
		# Only `New` or `Update` stage
		if ($script:LifecycleNew -bor $script:LifecycleUpdate -band $this.ProgressLifecycle -eq $this.ProgressLifecycle) {
			# Set the percentage
			$this.ProgressPercentComplete = $script:ProgressPercentCompleteMaximum
	
			# Set the compelted state
			$this.ProgressCompleted = $True

			# Update the progress
			$this.UpdateProgress()

			# Set lifecycle
			$this.ProgressLifecycle = $script:LifecycleStop
		}
		else {
			throw $script:ErrorProgressForbiddenMethod
		}
		
	}

	<## Report the progress. #>
	UpdateProgress() {
		# Functional code, separated for ensuring clear lifecycle
		function UpdateProgressDo {
			# Actually write from the current registered thread state
			Write-Progress -Activity $this.ProgressActivity `
				-CurrentOperation $this.ProgressOperation `
				-Status $this.ProgressStatus `
				-PercentComplete $this.ProgressPercent `
				-ParentId $this.ThredPoolId `
				-Id $this.ProgressId `
				-SecondsRemaining $this.ProgressSeconds `
				if ($this.ProgressCompleted) { -Completed }
		}

		# Switch by lifecycle state
		switch ($this.ProgressLifecycle) {
			# Update state - switch optimized for update operation
			$script:LifecycleUpdate {
				# Execute the functional code
				UpdateProgressDo

				# Break
				break
			}

			# New state
			$script:LifecycleNew {
				# Execute the functional code
				UpdateProgressDo

				# Set lifecycle
				$this.ProgressLifecycle = $script:LifecycleUpdate

				# Break
				break
			}

			# Default - throw error
			default {
				throw $script:ErrorProgressForbiddenMethod
			}
		}
	}
}

<##
 # Class implementing the metadata of thread like objects.
 #
 # `ThreadLike` takes the arguments as is, and does not perform any checks.
 #
 # **Lifecycle**
 #
 # 1. New
 # 2. Call `StartThreadLike`
 # 3. [Update]
 #     ...Reassign `Progress` Members
 #     ...Call `UpdateThreadLike`
 # 5. Call `StopThreadLike`
 #>
class ThreadLike : Progress {
	[UInt16]$ThreadId # Numeric ID, identifying the thread like object
	[Lifecycle]$ThreadLikeLifecycle # Lifecycle of the threadlike
	[Boolean]$ProgressEnabled # Is the `Progress` base class even to be used

	# Constructor setting thread-like metadata
	ThreadLike([UInt]$ThreadId, [Int32]$ProgressId, [String]$ProgressActivity, [Boolean]$ProgressEnabled) {
		# Call superconstructor
		$this.Progress($ProgressId, $ProgressActivity)

		# Set Id
		$this.ThreadId = $ThreadId

		# Set progress
		$this.ProgressEnabled = $ProgressEnabled

		# Explicitly set the lifecycle
		$this:ThreadLikeLifecycle = $script:LifecycleNew
	}

	<## Stops the state of a `ThreadLike`. #>
	[Void]StopThreadLike() {
		# Only if `Update` or `New` stage
		if ($script:LifecycleNew -bor $script:LifecycleUpdate -band $this.ThreadLikeLifecycle -eq $this.ThreadLikeLifecycle) {
			# Stop the Progress
			if ($this.ProgressEnabled) {
				$this.StopProgress();
			}
		}
		else {
			throw $script:ErrorThreadLikeForbiddenMethod
		}
	}

	<## A wrapper to perform the actual call to the update progress. #>
	[Void]UpdateProgressAsThreadLike() {
		# Update the Progress
		if ($this.ProgressEnabled) {
			$this.UpdateProgress();
		}
	}

	<## Updates the state of a `ThreadLike`. #>
	[Void]UpdateThreadLike() {
		# Functional processing
		function UpdateThreadLikeDo {
			
		}

		# Switch on lifecycle - optimized for update stage
		switch ($this.ThreadLikeLifecycle) {
			# Case update
			$script:LifecycleUpdate {
				# Actual update functionality
				UpdateThreadLikeDo

				# Break
				break
			}

			# Case new
			$script:LifecycleNew {
				# Actual update functionality
				UpdateThreadLikeDo

				# Set lifecycle
				$this.ThreadLikeLifecycle = $script:LifecycleUpdate

				# Break
				break
			}

			# Lifecycle stage error
			default {
				throw $script:ErrorThreadLikeForbiddenMethod
			}
		}
	}

	<## Starts the `ThreadLike`. #>
	[Void]StartThreadLike() {
		# Switch by lifecycle state
		if ($script:LifecycleNew -band $this.ProgressLifecycle -eq $this.ProgressLifecycle) {
			# Update the Progress
			if ($this.ProgressEnabled) {
				$this.UpdateProgress();
			}
		}
		else {
			throw $script:ErrorThreadLikeForbiddenMethod
		}
	}
}

<##
 # Contains information about threads.
 #
 # ** Lifecycle **
 #
 # 1. New
 # 3. Start
 # 4. Wait
 # 5. Remove
 #>
class Thread : ThreadLike {
	# Class properties
	[IAsyncResult]$AsyncResult # Holds async data for running thread
	[ScriptBlock]$Function # `[ScriptBlock].isValueType` is `False`, thus it is OK to store it here, and it should not take space
	[PowerShell]$PowerShell # Actually where execution will take place
	[ThreadPool]$ThreadPool # The associated thread pool; `[ThreadPool].isValueType` is `False`
	
	<##
	 # Constructs a thread.
	 #
	 # **Required thread function signature**
	 # 
	 # ```powershell
	 # function MyFunction([Thread]$Thread){
	 # 	# Function body
	 # }
	 # ```
	 #>
	Thread(
		[ScriptBlock]$Function,
		[String]$ProgressActivity,
		[Int32]$ProgressId,
		[Boolean]$ProgressEnabled,
		[UInt16]$ThreadId,
		[ThreadPool]$ThreadPool
	) {
		# Call superconstructor
		$this.ThreadLike($ThreadId, $ProgressId, $ProgressActivity, $ProgressEnabled)

		# Set Function
		$this.Function = $Function

		# Set thread pool
		$this.ThreadPool = $ThreadPool

		# Add a powershell instance
		$this.PowerShell = [PowerShell]::Create()

		# Associate PS instance with pool
		$this.PowerShell.RunspacePool = $this.ThreadPool.RunspacePool

		# Add script to PS
		$this.PowerShell.AddScript(
			{ # Script body 
				# Declare params
				Param (
					$Thread # Class type is not specified on purpose https://github.com/PowerShell/PowerShell/issues/3641
				)

				# Invoke the command
				Invoke-Command -ScriptBlock $Thread.Function -ArgumentList $Thread
			}
		)

		# Add the primary parameter so the thread can call back
		$this.PowerShell.AddParameters(
			@{
				Thread = $this
			}
		)
	}

	<##
	 # Enqueues progress to the queue.
	 #
	 # ** Usage - Parameter example **
	 #
	 # ```powershell
	 # @{
	 # ProgressOperation = "Generic operation"
	 # ProgressPercent   = 0
	 # SecondsRemaining  = -1
	 # ProgressStatus    = Processing
	 # }`
	 #
	 # **Note**
	 #
	 # This was written, when classes did not support optional parameters in methods.
	 #>
	[Void]EnqueueProgress([Hashtable]$ProgressInfo) {
		$ProgressInfo.ThreadId = $this.ThreadId
		$this.ThreadPool.ProgressQueue.Enqueue($ProgressInfo)
	}

	<## Cleans up. #>
	[Void]RemoveThread() {
		$this.PowerShell.Dispose()
	}
	
	<## Begins the execution of the thread. #>
	[Void]StartThread() {
		# Start `ThreadLike`
		$this.StartThreadLike()

		# Invoke the actual asynchronous code
		$this.AsyncResult = $this.PowerShell.BeginInvoke()
	}

	<## Updates the thread's state #>
	[Void]UpdateThread() {
		# Update ThreadLike
		$this.UpdateThreadLike()
	}

	<## Waits for the operation to complete. #>
	[Void]WaitThread() {
		# End invocation
		$this.PowerShell.EndInvoke($this.AsyncResult)

		# Stop `ThreadLike`
		$this.StopThreadLike()
	}
}

<##
 # Contains information about the thread pool, initializes the threads.
 #
 # The `ThreadId` on both the pool and children threads is of type `UInt16`, as extended from the `ThreadLike` class.
 # The `ProgressId` of the pool is calculated as `[UInt32]$this.ThreadId -shl $script:ThreadPoolProgressIdShift + [UInt32]$script:ThreadPoolProgressIdMaxThreads`, where `ThreadPoolProgressIdShift` is `16`, and `ThreadPoolProgressIdMaxThreads` is `[UInt16]::MaxValue`.
 # The `ProgressId` for the children threads is calculated the similar way, only instead of `ThreadPoolProgressIdMaxThreads` we are adding the index of the thread info array for the respecrive thread.
 # Thus there is 1 less possible threads per pool, than there are possible pools.
 #
 # **Note**
 #
 # For calculation of the ProgressId, the shift was chosen over multiplication on purspose, as this operation is to be faster __in principle__.
 #
 # ** Lifecycle **
 #
 # 1. New
 # 2. Start
 # 4. Wait
 # 5. Remove
 #>
class ThreadPool : ThreadLike {
	# Class properties
	[Queue]$ProgressQueue # A queue to store progress reporting	
	[UInt]$ReadProgressQueueMaxIterations = $script:ThreadPoolReadProgressQueueMaxIterations # Max iterations in `ReadQueue`
	[RunspacePool]$RunspacePool # Runspace pool to hold it all
	[Int32]$SleepMilliseconds = $script:ThreadPoolSleepMilliseconds # Number of milliseconds to sleep between thread updates
	[Thread[]]$ThreadArray


	<## Converts from unsigned to signed progress Id. #>
	[Int32] static ConvertToSignedProgressId ([UInt32]$UnsignedProgressId) {
		# Transform to Int32
		if ($UnsignedProgressId -lt $script:ThreadPoolProgressIdUnsignedLimit) {
			return [Int32]$UnsignedProgressId
		}

		# Represent unsgined in a signed range
		return [Int32]([Int64]$UnsignedProgressId - [Int64]$script:ThreadPoolProgressIdUnsignedLimit)
	}

	<##
	 # Converts from ThreadId of the ThreadPool and ThreadId of the thread to thread's ProgressId.
	 #
	 # **Note**
	 #
	 # Not performing the check - `$ThreadThreadId -lt $script:ThreadProgressIdMaxThreadThreadId`, since if thread info array length reaches the `[UInt16]::MaxValue`, there would be an error thrown in the constructor.
	 #>
	[Int32] ConvertToThreadProgressId ([UInt16]$ThreadThreadId) {
		# Set the absolute unsigned progress Id
		[UInt32]$UnsignedProgressId = [UInt32]$this.ThreadId -shl $script:ThreadPoolProgressIdShift + [UInt32]$ThreadThreadId

		# Return progress Id as signed
		return [ThreadPool]::ConvertToSignedProgressId($UnsignedProgressId)
	}

	<## Converts from thread pool Id to thread pool's progress Id. #>
	[Int32] GetThreadPoolProgressId () {
		# Set the absolute unsigned progress Id
		[UInt32]$UnsignedProgressId = [UInt32]$this.ThreadId -shl $script:ThreadPoolProgressIdShift + [UInt32]$script:ThreadPoolProgressIdMaxThreads

		# Return progress Id as signed
		return [ThreadPool]::ConvertToSignedProgressId($UnsignedProgressId)
	}

	<## Constructor. #>
	ThreadPool([UInt16]$ThreadId, [String]$ProgressActivity, [Hashtable[]]$ThreadInfoArray) {
		# First things first - validate the array
		{
			# Validate the length - practically unnecessary check
			if ($ThreadInfoArray.Length -ge $script:ThreadPoolProgressIdMaxThreads) {
				throw $script:ErrorThreadPoolTooManyThreads
			}

			# Validate the hashtable data integrity
			$ThreadInfoArray | ForEach-Object -Process {
				if ($_.ContainsKey("Activity")) {
					$_.Activity -is [String] {
						if ($_.ContainsKey("Function")) {
							if ($_.Function -is [ScriptBlock]) {
								return
							}
						}
					}
				}
			
				# Throw an error - only if there is absent or inappropriate or null Function, or non String/null Activity
				throw "Improperly defined hashtable 'ThreadInfoArray' has been provided."
			}
		}

		# Call superconstructor
		$this.ThreadLike($ThreadId, $this.ConvertToThreadPoolProgressId(), $ProgressActivity)
		

		# Determine thread array length; Will throw an error if `$ThreadInfoArray.length` larger than `[UInt]::MaxValue`
		[UInt16]$ThreadAmount = $ThreadInfoArray.Length

		# Initialize thread array
		$this.ThreadArray = New-Object -TypeName "[Thread[]]" -ArgumentList @($ThreadAmount)

		# Create synchronized progress queue
		$this.ProgressQueue = [Queue]::Synchronized(
			(New-Object -TypeName "System.Collections.Queue")
		)

		# Initialize & open pool
		{
			$this.RunspacePool = [RunspaceFactory]::CreateRunspacePool($script:ThreadPoolInitialSessionState <# Accessing script scope, since cannot use global scope vars directly from class methods. #>)
			$this.RunspacePool.SetMinRunspaces($ThreadAmount)
			$this.RunspacePool.SetMaxRunspaces($ThreadAmount)
			$this.RunspacePool.Open()
		}

		# Populate threads
		for ([UInt16]$i = $script:UZero16; $i -lt $ThreadAmount; $i++) {
			$this.ThreadArray[$i] = New-Object -TypeName "Thread" -ArgumentList @(
				$ThreadInfoArray[$i].Function,
				$ThreadInfoArray[$i].Activity,
				$this.ConvertToThreadProgressId($i),
				$i,
				$this
			)
		}
	}

	<##
	 # Dequeues the progress queue, and updates the respective thread.
	 #
	 # Performs the check for consistency of the enqueued data, including the `ThreadId` set by the thread's method, since there are no private members, hence the queue could be accessed manually, and all checks are needed.
	 #>
	[Void]DequeueProgress() {
		# Dequeue
		$hash = $this.ProgressQueue.Dequeue()

		# Verify there is the Id key
		if ($hash.ContainsKey("ThreadId")) {
			# Verify that the key is indeed an integer
			if ($hash.ThreadId -is [UInt16]) {
				# If we write progress beyond managed range, then there will remain artifacts after finalizing
				if ($hash.ThreadId -lt $this.ThreadArray.length) {
					
					# Assign Thread for quick access; Class instances are passed by reference
					$Progress = $this.ThreadArray[$hash.ThreadId]

					# Process the current operation
					if ($hash.ContainsKey("CurrentOperation")) {
						if ($hash.CurrentOperation -is [String]) {
							$Progress.ProgressCurrentOperation = $hash.CurrentOperation
						}
					}

					# Process percent
					{
						# Process dequeued value
						if ($hash.ContainsKey("PercentComplete")) {
							if ($hash.PercentComplete -is [Int32]) {
								if ($hash.PercentComplete -ge $Progress.ProgressPercent -and $hash.PercentComplete -le $script:ProgressPercentCompleteMaximum) {
									$Progress.ProgressPercentComplete = $hash.PercentComplete
								}
							}
						}
						
						# Display to user at least something, if no percentage reported, or 0 is reported
						if ($Progress.ProgressPercentComplete -lt $script:ProgressPercentCompleteDefault) {
							$Progress.ProgressPercentComplete = $script:ProgressPercentCompleteDefault
						}
					}

					# Process seconds; There is no check for wether the remaining time is lower than previous value, due to the fact that it is and __estimation__ and not a decrementing value
					if ($hash.ContainsKey("SecondsRemaining")) {
						if ($hash.SecondsRemaining -is [Int32]) {
							if ($hash.SecondsRemaining -ge $script:SZero32) {
								$Progress.ProgressSecondsRemaining = $hash.SecondsRemaining
							}
						}
					}

					# Process the status
					$Progress.ProgressStatus = $script:ProgressStatusDefault
					if ($hash.ContainsKey("Status")) {
						if ($hash.Status -is [String]) {
							$Progress.ProgressStatus = $hash.Status
						}
					}
				}
			}
		}
	}

	<## Reads the queue and updates thread info, untill the queue is empty. ##>
	[Void]ReadProgressQueue() {
		[UInt]$i = $script:Uzero
		do {
			$this.ProgressQueue.Dequeue()
		} while ($this.ProgressQueue.Count -gt $script:SZero32 <# `Queue.Count` property is `Int32` #> -and $i++ -lt $this.ReadProgressQueueMaxIterations)
	}

	<## Cleans up. ##>
	[Void]RemoveAll() {
		# Clean up threads first
		$this.ThreadArray | ForEach-Object -Process {
			$_.Remove()
		}

		# Deal with the pool
		$this.RunspacePool.Close() 
		$this.RunspacePool.Dispose()
	}

	<## Execute threads. ##>
	[Void]StartThreads() {
		# Iterate through threads
		$this.ThreadArray | ForEach-Object -Process {
			$_.Start()
		}
	}

	<# Updates the progress to the console. #>
	[Void]UpdateAllProgress() {
		# Write pool's progress first
		$this.UpdateProgress()

		# Actually write from the current registered thread state
		$this.ThreadArray | ForEach-Object -Process {
			$_.UpdateProgress()
		}
	}

	<## Waits for all the threads to complete. ##>
	[Void]WaitThreads() {
		# Iterate through threads
		$this.ThreadArray | ForEach-Object -Process {
			$_.Wait()
		}
	}

	<## Starts and waits for threads, meanwhile and writes the progress to the console. ##>
	[Void]Execute() {
		# Immediately update initial progress
		$this.UpdateAllProgress()

		# Start the threads so the CPU doesn't idle
		$this.StartThreads()

		# Main execution loop
		while (($this.ThreadArray | Select-Object -Property AsyncResult | Select-Object -Property IsCompleted) -notcontains "Completed") {
			# Read from the queues
			$this.ReadProgressQueue()
			
			# Update the progress
			$this.UpdateAllProgress()

			<#
				Sleep - busy waiting is always a bad thing.
				Let us wait a bit between iterations, so we can free up a core for thread executions.
			#>
			Start-Sleep -Milliseconds $this.SleepMilliseconds
		}

		# Finally wait for all, to ceremonially call `EndInvoke`
		$this.Wait()

		# Finally close all the progresses
		$this.UpdateAllProgress()
	}
}

Export-ModuleMember