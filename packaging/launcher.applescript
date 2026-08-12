use framework "Foundation"
use framework "AppKit"
use framework "WebKit"

property mainWindow : missing value
property webView : missing value
property coreTask : missing value
property dashboardURL : "http://127.0.0.1:9090/"

on run
	my startCore()
	if my waitForCore() then
		my buildWindow()
	else
		my showStartupError()
		current application's NSApp's terminate:me
	end if
end run

on reopen
	if mainWindow is missing value then
		my buildWindow()
	else
		mainWindow's makeKeyAndOrderFront:me
		current application's NSApp's activateIgnoringOtherApps:true
	end if
end reopen

on idle
	if coreTask is not missing value then
		if (coreTask's isRunning()) as boolean is false then
			set coreTask to missing value
			current application's NSApp's terminate:me
		end if
	end if
	return 2
end idle

on quit
	if coreTask is not missing value then
		if (coreTask's isRunning()) as boolean then coreTask's terminate()
		set coreTask to missing value
	end if
	continue quit
end quit

on windowWillClose_(notification)
	current application's NSApp's terminate:me
end windowWillClose_

on startCore()
	if my coreIsHealthy() then return
	set appPath to (current application's NSBundle's mainBundle()'s bundlePath()) as text
	set corePath to appPath & "/Contents/Resources/zhilian.rb"
	set nullHandle to current application's NSFileHandle's fileHandleWithNullDevice()
	set coreTask to current application's NSTask's alloc()'s init()
	coreTask's setLaunchPath:"/usr/bin/ruby"
	coreTask's setArguments:{corePath, "--no-open"}
	set processInfo to current application's NSProcessInfo's processInfo()
	set inheritedEnvironment to processInfo's environment()
	set coreEnvironment to inheritedEnvironment's mutableCopy()
	coreEnvironment's setObject:"en_US.UTF-8" forKey:"LANG"
	coreEnvironment's setObject:"en_US.UTF-8" forKey:"LC_ALL"
	coreTask's setEnvironment:coreEnvironment
	coreTask's setStandardOutput:nullHandle
	coreTask's setStandardError:nullHandle
	coreTask's |launch|()
end startCore

on coreIsHealthy()
	set nullHandle to current application's NSFileHandle's fileHandleWithNullDevice()
	set healthTask to current application's NSTask's alloc()'s init()
	healthTask's setLaunchPath:"/usr/bin/curl"
	healthTask's setArguments:{"--fail", "--silent", "--max-time", "1", dashboardURL & "api/health"}
	healthTask's setStandardOutput:nullHandle
	healthTask's setStandardError:nullHandle
	healthTask's |launch|()
	healthTask's waitUntilExit()
	return ((healthTask's terminationStatus()) as integer) is 0
end coreIsHealthy

on waitForCore()
	repeat 60 times
		if my coreIsHealthy() then return true
		current application's NSThread's sleepForTimeInterval:0.1
	end repeat
	return false
end waitForCore

on showStartupError()
	set alert to current application's NSAlert's alloc()'s init()
	alert's setMessageText:"智连核心启动失败"
	alert's setInformativeText:"请退出应用后重新打开。如果问题持续，请检查 7890 和 9090 端口是否被其他程序占用。"
	alert's addButtonWithTitle:"退出"
	alert's runModal()
end showStartupError

on buildWindow()
	set nativeApp to current application's NSApplication's sharedApplication()
	nativeApp's setActivationPolicy:(current application's NSApplicationActivationPolicyRegular)

	set windowFrame to {{0, 0}, {1180, 760}}
	set mainWindow to current application's NSWindow's alloc()'s initWithContentRect:windowFrame styleMask:15 backing:2 defer:false
	mainWindow's setTitle:"智连"
	mainWindow's setReleasedWhenClosed:false
	mainWindow's setDelegate:me
	mainWindow's |center|()

	set configuration to current application's WKWebViewConfiguration's alloc()'s init()
	set containerView to mainWindow's |contentView|()
	set contentBounds to containerView's |bounds|()
	set webView to current application's WKWebView's alloc()'s initWithFrame:contentBounds configuration:configuration
	webView's setAutoresizingMask:18
	mainWindow's setContentView:webView

	set pageURL to current application's NSURL's URLWithString:dashboardURL
	set pageRequest to current application's NSURLRequest's requestWithURL:pageURL
	webView's loadRequest:pageRequest

	mainWindow's makeKeyAndOrderFront:me
	nativeApp's activateIgnoringOtherApps:true
end buildWindow
