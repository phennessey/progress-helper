-- Quick Action: make a JPEG copy of each selected image, with a progress window.
--
-- In Automator: New Quick Action, "Workflow receives current image files in Finder",
-- add "Run AppleScript" and paste this in. Requires `progress-helper setup-applescript`.

use script "ProgressHelperLib"
use scripting additions

on run {input, parameters}
	set total to count of input
	progress bar start
	progress bar update total steps 0 description "Preparing…"
	try
		repeat with i from 1 to total
			progress bar cancel
			set f to item i of input
			set p to POSIX path of f
			progress bar update icon f description "Converting “" & (do shell script "basename " & quoted form of p) & "”" ¬
				total steps total completed steps (i - 1) status ("" & i & " of " & total)
			do shell script "sips -s format jpeg " & quoted form of p & " --out " & quoted form of (p & ".jpg") & " >/dev/null"
		end repeat
	on error number -128
		return input
	end try
	progress bar end
	return input
end run
