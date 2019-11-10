# Structure

```mermaid
classDiagram
class Lifecycle{
	<<enumeration>>
	New
	Start
	Update
	Wait
	Stop
	Remove
}
class Progress{
	-String Activity
	-Boolean Completed
	-Int32 Id
	#String CurrentOperation
	#Lifecycle Lifecycle
	#Int32 PercentComplete
	#Int32 SecondsRemaining
	#String Status
	#Stop()
	#Update()
}
class ThreadLike{
	-Boolean ProgressEnabled
	-UInt16 ThreadId
	#Lifecycle Lifecycle
	#Start()
	#Stop()
	#Update()
}
class Thread{
	-IAsyncResult AsyncResult
	-Function Function
	-PowerShell PowerShell
	-ThreadPool ThreadPool
	+Mutex Lock
	+Lifecycle Lifecycle
	+Remove()
	+Start()
	+Update()
	+Wait()
}
class ThreadPool{
	-RunspacePool RunspacePool
	-Thread[] ThreadArray
	+Int32 SleepMilliseconds
	-ConvertToSignedProgressId()
	-ConvertToThreadProgressId()
	-DequeueProgress()
	-GetThreadPoolProgressId()
	-ReadProgressQueue()
	+Lifecycle Lifecycle
	+RemoveAll()
	+StartThreads()
	+UpdateAllProgress()
	+WaitThreads()
	+Execute()
}
class Handle{
	+EnqueueProgress()
}
class Function{
	+ScriptBlock Scriptblock
}

Progress <|-- ThreadLike : extends
Progress <.. Lifecycle
ThreadLike <|-- Thread : extends
ThreadLike <|-- ThreadPool : extends
ThreadLike <.. Lifecycle
ThreadPool "1" *-- "1..*" Thread : contains
ThreadPool <.. Lifecycle
Thread "1" *-- Function : contains
Thread "1" *-- "1" Handle : contains
Thread <.. Lifecycle
Function "1" o-- "1" Handle
```
