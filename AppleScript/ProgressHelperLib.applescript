-- ProgressHelperLib: AppleScript commands for progress-helper windows.
--
-- The handlers use raw event codes because osacompile cannot load a library's own
-- dictionary while compiling it. ProgressHelperLib.sdef maps the codes to these names:
--
--   «event PrHlStRt»   progress bar start
--   «event PrHlUpDt»   progress bar update   «class PrTs» total steps, «class PrCs» completed steps,
--                                           «class PrDe» description, «class PrSt» status, «class PrIc» icon
--   «event PrHlCaCl»   progress bar cancel
--   «event PrHlEnDo»   progress bar end [message]
--
-- Each command runs the progress-helper program. The window closes itself if the
-- script that opened it stops running.

use AppleScript version "2.4"
use scripting additions

property sessionID : missing value
property helper : missing value

-- progress bar start
on «event PrHlStRt»
	if sessionID is not missing value then my closeSession()
	-- $PPID is the process running this script (osascript, Script Editor or Automator).
	set ownerPID to do shell script "echo $PPID"
	set sessionID to do shell script quoted form of my helperPath() & " start --watch-pid " & ownerPID
end «event PrHlStRt»

-- progress bar update [total steps N] [completed steps N] [description T] [status T] [icon F]
on «event PrHlUpDt» given «class PrTs»:totalN : missing value, «class PrCs»:completedN : missing value, «class PrDe»:descText : missing value, «class PrSt»:statusText : missing value, «class PrIc»:iconFile : missing value
	if sessionID is missing value then «event PrHlStRt»
	set args to ""
	if iconFile is not missing value then set args to args & " --icon " & quoted form of my posixPath(iconFile)
	if descText is not missing value then set args to args & " --label " & quoted form of (descText as text)
	if statusText is not missing value then set args to args & " --status " & quoted form of (statusText as text)
	if totalN is not missing value then
		if (totalN as integer) > 0 then
			set args to args & " --total " & (totalN as integer)
		else
			set args to args & " --indeterminate"
		end if
	end if
	if completedN is not missing value then set args to args & " --completed " & (completedN as integer)
	if args is not "" then
		try
			do shell script quoted form of my helperPath() & " update " & quoted form of sessionID & args
		end try
	end if
end «event PrHlUpDt»

-- progress bar cancel
on «event PrHlCaCl»
	if sessionID is missing value then return
	set didStop to false
	try
		do shell script quoted form of my helperPath() & " cancelled " & quoted form of sessionID
		set didStop to true
	end try
	if didStop then
		my closeSession()
		error number -128
	end if
end «event PrHlCaCl»

-- progress bar end [message]
-- AppleScript passes the library itself as the direct parameter when the command has
-- no argument, hence the class check.
on «event PrHlEnDo» msg : missing value
	if sessionID is missing value then return
	if msg is not missing value and class of msg is text then
		try
			do shell script quoted form of my helperPath() & " update " & quoted form of sessionID & ¬
				" --label " & quoted form of msg & " --status '' --total 1 --completed 1"
		end try
		delay 1.5
	end if
	my closeSession()
end «event PrHlEnDo»

-- ---- helpers ----------------------------------------------------------------

on closeSession()
	try
		do shell script quoted form of my helperPath() & " end " & quoted form of sessionID
	end try
	set sessionID to missing value
end closeSession

-- Scripts run with a minimal PATH, so look in the usual install folders.
on helperPath()
	if helper is missing value then
		try
			set helper to do shell script "for d in /opt/homebrew/bin /usr/local/bin \"$HOME/.local/bin\"; do [ -x \"$d/progress-helper\" ] && { echo \"$d/progress-helper\"; exit 0; }; done; exit 1"
		on error
			error "progress-helper is not installed. Install it with: brew install phennessey/tap/progress-helper" number 1
		end try
	end if
	return helper
end helperPath

on posixPath(f)
	if class of f is text then return f
	return POSIX path of (f as alias)
end posixPath
