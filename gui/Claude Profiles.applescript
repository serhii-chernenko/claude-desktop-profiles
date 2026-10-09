property appTitle : "Claude Profiles"
property readmeUrl : "https://github.com/serhii-chernenko/claude-desktop-profiles#readme"
property menuCreate : "Create profile"
property menuColor : "Change color"
property menuRebuild : "Rebuild"
property menuCheck : "Check"
property menuLink : "Link sign-in (claude://)"
property menuRemove : "Remove"
property menuSetup : "Set up auto-rebuild & stable signing"
property menuInstallCli : "Install command-line tool"
property menuReadme : "Open README"
property optionCreateNew : "Create new"
property optionAllProfiles : "All profiles"
property optionMainClaude : "Main Claude (no profile)"
property modeSymlink : "Share history (symlink)"
property modeMove : "Reassign history (move)"
property modeCopy : "Copy history"
property labelDesktop : "Desktop app"
property labelCli : "Command line (Claude Code)"
property keepAll : "Keep desktop data and CLI config"
property deleteData : "Also delete desktop data (login, local state)"
property deleteConfig : "Also delete CLI config (settings, history)"
property deleteBoth : "Delete both"

on run
	set menuItems to {menuCreate, menuColor, menuRebuild, menuCheck, menuLink, menuRemove, menuSetup, menuInstallCli, menuReadme}
	repeat
		set picked to choose from list menuItems with title appTitle with prompt "What do you want to do?" OK button name "Continue" cancel button name "Quit"
		if picked is false then exit repeat
		set selectedAction to item 1 of picked
		try
			if selectedAction is menuCreate then
				createProfile()
			else if selectedAction is menuColor then
				changeColor()
			else if selectedAction is menuRebuild then
				rebuildProfiles()
			else if selectedAction is menuCheck then
				checkProfile()
			else if selectedAction is menuLink then
				linkSignIn()
			else if selectedAction is menuRemove then
				removeProfile()
			else if selectedAction is menuSetup then
				openSetupInTerminal()
			else if selectedAction is menuInstallCli then
				installCommandLineTool()
			else if selectedAction is menuReadme then
				open location readmeUrl
			end if
		on error errorMessage number errorNumber
			if errorNumber is not -128 then showError(errorMessage)
		end try
	end repeat
end run

on cliPath()
	return POSIX path of ((path to me as text) & "Contents:Resources:bin:claude-profiles")
end cliPath

on cliCommand(arguments)
	return "/bin/zsh " & quoted form of cliPath() & " " & arguments
end cliCommand

on runAction(arguments)
	with timeout of 3600 seconds
		return do shell script cliCommand(arguments) & " 2>&1"
	end timeout
end runAction

on runQuery(arguments)
	set errorFile to do shell script "/usr/bin/mktemp -t claude-profiles-gui"
	try
		with timeout of 600 seconds
			set output to do shell script cliCommand(arguments) & " 2>" & quoted form of errorFile
		end timeout
	on error errorMessage
		set errorText to do shell script "/bin/cat " & quoted form of errorFile & "; /bin/rm -f " & quoted form of errorFile
		if errorText is "" then set errorText to errorMessage
		error errorText
	end try
	do shell script "/bin/rm -f " & quoted form of errorFile
	return output
end runQuery

on showError(message)
	set shown to message
	if (length of shown) > 1500 then set shown to "..." & (text -1500 thru -1 of shown)
	display dialog shown with title appTitle with icon stop buttons {"OK"} default button "OK"
end showError

on notify(message)
	display notification message with title appTitle
end notify

on cancelOperation()
	error number -128
end cancelOperation

on splitText(sourceText, delimiter)
	set savedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to delimiter
	set parts to text items of sourceText
	set AppleScript's text item delimiters to savedDelimiters
	return parts
end splitText

on trimText(sourceText)
	return do shell script "/usr/bin/printf '%s' " & quoted form of sourceText & " | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'"
end trimText

on homePath()
	set rawPath to POSIX path of (path to home folder)
	if rawPath ends with "/" then set rawPath to text 1 thru -2 of rawPath
	return rawPath
end homePath

on tildePath(absolutePath)
	set home to homePath()
	if absolutePath is home then return "~"
	if absolutePath starts with (home & "/") then return "~" & (text ((length of home) + 1) thru -1 of absolutePath)
	return absolutePath
end tildePath

on hexByte(value)
	set digits to "0123456789abcdef"
	return (character ((value div 16) + 1) of digits) & (character ((value mod 16) + 1) of digits)
end hexByte

on hexFromColor(rgb)
	set hex to "#"
	repeat with channelIndex from 1 to 3
		set hex to hex & hexByte(((item channelIndex of rgb) div 257))
	end repeat
	return hex
end hexFromColor

on colorFromHex(hex)
	set digits to "0123456789abcdef"
	set cleaned to hex
	if cleaned starts with "#" then set cleaned to text 2 thru -1 of cleaned
	if (length of cleaned) is not 6 then return {52428, 26214, 13107}
	set rgb to {}
	repeat with channelIndex from 0 to 2
		set highDigit to (offset of (character (channelIndex * 2 + 1) of cleaned) in digits) - 1
		set lowDigit to (offset of (character (channelIndex * 2 + 2) of cleaned) in digits) - 1
		if highDigit < 0 or lowDigit < 0 then return {52428, 26214, 13107}
		set end of rgb to (highDigit * 16 + lowDigit) * 257
	end repeat
	return rgb
end colorFromHex

on pickColor(startHex)
	set startColor to colorFromHex(startHex)
	return hexFromColor(choose color default color startColor)
end pickColor

on chooseIndexes(labels, promptText, allowMultiple, allowEmpty, defaultLabels)
	set picked to choose from list labels with title appTitle with prompt promptText multiple selections allowed allowMultiple empty selection allowed allowEmpty default items defaultLabels OK button name "Continue" cancel button name "Cancel"
	if picked is false then cancelOperation()
	set indexes to {}
	repeat with pickedLabel in picked
		repeat with labelIndex from 1 to count of labels
			if (item labelIndex of labels) is (pickedLabel as text) then
				set end of indexes to labelIndex
				exit repeat
			end if
		end repeat
	end repeat
	return indexes
end chooseIndexes

on listProfiles(desktopOnly)
	set profiles to {}
	set output to runQuery("list --plain")
	repeat with lineText in paragraphs of output
		if (lineText as text) is not "" then
			set fields to splitText(lineText as text, tab)
			if (count of fields) >= 7 and (item 1 of fields) is not "default" then
				if not desktopOnly or (item 4 of fields) is "1" then set end of profiles to fields
			end if
		end if
	end repeat
	return profiles
end listProfiles

on profileLabel(fields)
	return (item 2 of fields) & " (" & (item 1 of fields) & ")"
end profileLabel

on pickProfile(promptText, includeAll, includeMain, desktopOnly)
	set profiles to listProfiles(desktopOnly)
	if (count of profiles) is 0 and not includeMain then
		if desktopOnly then error "No profiles with a desktop app yet. Use \"" & menuCreate & "\" first."
		error "No profiles yet. Use \"" & menuCreate & "\" first."
	end if
	set labels to {}
	repeat with fields in profiles
		set end of labels to profileLabel(fields)
	end repeat
	if includeAll then set end of labels to optionAllProfiles
	if includeMain then set end of labels to optionMainClaude
	set chosen to item 1 of chooseIndexes(labels, promptText, false, false, {})
	if chosen > (count of profiles) then return {profileSlug:"", profileText:(item chosen of labels), profileFields:{}}
	set fields to item chosen of profiles
	return {profileSlug:(item 1 of fields), profileText:profileLabel(fields), profileFields:fields}
end pickProfile

on scanExisting()
	set configDirs to {}
	set dataDirs to {}
	set projects to {}
	set output to runQuery("scan --plain")
	repeat with lineText in paragraphs of output
		if (lineText as text) is not "" then
			set fields to splitText(lineText as text, tab)
			set kind to item 1 of fields
			if kind is "config" and (count of fields) >= 3 then
				set end of configDirs to {item 2 of fields, item 3 of fields}
			else if kind is "data" and (count of fields) >= 2 then
				set end of dataDirs to {item 2 of fields}
			else if kind is "project" and (count of fields) >= 6 then
				set end of projects to {item 2 of fields, item 3 of fields, item 4 of fields, item 5 of fields, item 6 of fields}
			end if
		end if
	end repeat
	return {configDirs:configDirs, dataDirs:dataDirs, projects:projects}
end scanExisting

on chooseAdoption(candidatePaths, candidateLabels, promptText)
	if (count of candidatePaths) is 0 then return ""
	set labels to {optionCreateNew} & candidateLabels
	set chosen to item 1 of chooseIndexes(labels, promptText, false, false, {optionCreateNew})
	if chosen is 1 then return ""
	return item (chosen - 1) of candidatePaths
end chooseAdoption

on createProfile()
	set nameAnswer to display dialog "Name of the new profile (for example Work):" default answer "" with title appTitle buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel"
	set profileName to trimText(text returned of nameAnswer)
	if profileName is "" then error "The profile name cannot be empty."

	set profileColor to pickColor("#cc6633")

	set kinds to chooseIndexes({labelDesktop, labelCli}, "Where should \"" & profileName & "\" be used?", true, false, {labelDesktop, labelCli})
	set wantsDesktop to kinds contains 1
	set wantsCli to kinds contains 2

	set existing to scanExisting()
	set dataDir to ""
	set configDir to ""

	if wantsDesktop then
		set dataPaths to {}
		set dataLabels to {}
		repeat with entry in dataDirs of existing
			set end of dataPaths to item 1 of entry
			set end of dataLabels to tildePath(item 1 of entry)
		end repeat
		set dataDir to chooseAdoption(dataPaths, dataLabels, "Desktop data folder (login and local state) for \"" & profileName & "\":")
	end if

	set linkTargets to {}
	set linkMode to "symlink"
	if wantsCli then
		set configPaths to {}
		set configLabels to {}
		repeat with entry in configDirs of existing
			set end of configPaths to item 1 of entry
			set end of configLabels to tildePath(item 1 of entry) & " (" & (item 2 of entry) & " projects)"
		end repeat
		set configDir to chooseAdoption(configPaths, configLabels, "Claude Code config folder for \"" & profileName & "\":")

		set projectEntries to projects of existing
		if (count of projectEntries) > 0 then
			set projectLabels to {}
			repeat with entry in projectEntries
				set ownerText to ""
				if (item 5 of entry) is not "-" then set ownerText to ", profile " & (item 5 of entry)
				set end of projectLabels to (tildePath(item 2 of entry)) & " (" & (item 3 of entry) & " sessions" & ownerText & ") in " & tildePath(item 1 of entry)
			end repeat
			set selectedProjects to chooseIndexes(projectLabels, "Link existing projects and their session history to \"" & profileName & "\" (optional):", true, true, {})
			repeat with selectedPosition from 1 to count of selectedProjects
				set end of linkTargets to item 2 of (item (item selectedPosition of selectedProjects) of projectEntries)
			end repeat
			if (count of linkTargets) > 0 then
				set modeChoice to item 1 of chooseIndexes({modeSymlink, modeMove, modeCopy}, "How should the session history be linked?", false, false, {modeSymlink})
				if modeChoice is 1 then
					set linkMode to "symlink"
				else if modeChoice is 2 then
					set linkMode to "move"
					display dialog "Reassigning moves the history out of its current config folder. Quit Claude and any running Claude Code sessions first." with title appTitle with icon caution buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel"
				else
					set linkMode to "copy"
				end if
			end if
		end if
	end if

	set arguments to "new --name " & quoted form of profileName & " --color " & quoted form of profileColor
	if wantsDesktop then
		set arguments to arguments & " --desktop"
	else
		set arguments to arguments & " --no-desktop"
	end if
	if wantsCli then
		set arguments to arguments & " --cli"
	else
		set arguments to arguments & " --no-cli"
	end if
	if dataDir is not "" then set arguments to arguments & " --data-dir " & quoted form of dataDir
	if configDir is not "" then set arguments to arguments & " --config-dir " & quoted form of configDir
	repeat with target in linkTargets
		set arguments to arguments & " --link " & quoted form of (target as text)
	end repeat
	if (count of linkTargets) > 0 then set arguments to arguments & " --link-mode " & linkMode
	set arguments to arguments & " --yes --plain"

	notify("Creating \"" & profileName & "\". Building the app copy can take a couple of minutes.")
	set output to runAction(arguments)
	notify("Profile \"" & profileName & "\" is ready.")
	offerReveal(profileName, output)
end createProfile

on createdFields(output)
	set outputLines to paragraphs of output
	repeat with lineIndex from (count of outputLines) to 1 by -1
		set lineText to item lineIndex of outputLines
		if lineText starts with ("created" & tab) then return splitText(lineText, tab)
	end repeat
	return {}
end createdFields

on offerReveal(profileName, output)
	set launcherPath to ""
	set fields to createdFields(output)
	if (count of fields) >= 3 then
		set createdSlug to item 2 of fields
		set candidate to item 3 of fields
		if createdSlug is not "" and candidate is not "-" then
			try
				do shell script "/bin/test -d " & quoted form of candidate
				set launcherPath to candidate
			end try
		end if
	end if
	if launcherPath is "" then
		display dialog "Profile \"" & profileName & "\" created." with title appTitle buttons {"Done"} default button "Done"
		return
	end if
	set reply to display dialog "Profile \"" & profileName & "\" created." & return & return & "Open it with its launcher and pin the launcher (not the app copy) to the Dock. The first launch asks once for Keychain access: choose Always Allow." with title appTitle buttons {"Done", "Show launcher in Finder"} default button "Show launcher in Finder"
	if button returned of reply is "Show launcher in Finder" then
		do shell script "/usr/bin/open -R " & quoted form of launcherPath
	end if
end offerReveal

on changeColor()
	set chosenProfile to pickProfile("Change the color of:", false, false, true)
	set startHex to item 3 of (profileFields of chosenProfile)
	if startHex is "" or startHex is "-" then set startHex to "#cc6633"
	set newColor to pickColor(startHex)
	notify("Recoloring " & (profileText of chosenProfile) & "...")
	set output to runAction("recolor " & quoted form of (profileSlug of chosenProfile) & " --color " & quoted form of newColor & " --yes")
	notify("Recolored " & (profileText of chosenProfile) & ".")
	display dialog "Color updated." & return & return & output with title appTitle buttons {"OK"} default button "OK"
end changeColor

on rebuildProfiles()
	set chosenProfile to pickProfile("Rebuild:", true, false, true)
	if (profileSlug of chosenProfile) is "" then
		notify("Rebuilding all profiles. This can take several minutes.")
		set output to runAction("build --all --yes")
	else
		notify("Rebuilding " & (profileText of chosenProfile) & ". This can take a couple of minutes.")
		set output to runAction("build " & quoted form of (profileSlug of chosenProfile) & " --yes")
	end if
	notify("Rebuild finished.")
	showOutput("Rebuild finished.", output)
end rebuildProfiles

on checkProfile()
	set chosenProfile to pickProfile("Check:", false, false, false)
	set output to runAction("check " & quoted form of (profileSlug of chosenProfile))
	showOutput("Check: " & (profileText of chosenProfile), output)
end checkProfile

on showOutput(heading, output)
	set shown to output
	if (length of shown) > 3000 then set shown to "..." & (text -3000 thru -1 of shown)
	set reply to display dialog heading & return & return & shown with title appTitle buttons {"Close", "Open as text file"} default button "Close"
	if button returned of reply is "Open as text file" then
		set reportFile to do shell script "/usr/bin/mktemp -t claude-profiles-report"
		do shell script "/usr/bin/printf '%s\\n' " & quoted form of output & " | /usr/bin/tr '\\r' '\\n' > " & quoted form of reportFile & " && /usr/bin/open -e " & quoted form of reportFile
	end if
end showOutput

on linkSignIn()
	set chosenProfile to pickProfile("Send claude:// sign-in links to:", false, true, true)
	set targetSlug to profileSlug of chosenProfile
	if targetSlug is "" then set targetSlug to "main"
	set output to runAction("link " & quoted form of targetSlug & " --yes")
	display dialog output with title appTitle buttons {"OK"} default button "OK"
end linkSignIn

on removeProfile()
	set chosenProfile to pickProfile("Remove:", false, false, false)
	set choiceIndex to item 1 of chooseIndexes({keepAll, deleteData, deleteConfig, deleteBoth}, "Removing " & (profileText of chosenProfile) & " deletes its app copy, launcher and settings entry.", false, false, {keepAll})
	set arguments to "remove " & quoted form of (profileSlug of chosenProfile)
	set confirmText to "Remove " & (profileText of chosenProfile) & "? The running copy will be quit."
	if choiceIndex is 2 or choiceIndex is 4 then
		set arguments to arguments & " --delete-data"
		set confirmText to confirmText & return & "Desktop data (including its login) will be deleted permanently."
	end if
	if choiceIndex is 3 or choiceIndex is 4 then
		set arguments to arguments & " --delete-config"
		set confirmText to confirmText & return & "CLI config and session history will be deleted permanently."
	end if
	display dialog confirmText with title appTitle with icon caution buttons {"Cancel", "Remove"} default button "Cancel" cancel button "Cancel"
	set output to runAction(arguments & " --yes")
	display dialog output with title appTitle buttons {"OK"} default button "OK"
end removeProfile

on openSetupInTerminal()
	display dialog "Setup creates a local code-signing identity, trusts it, and installs one LaunchAgent that rebuilds profiles after Claude updates. It asks for your login password in Terminal, so it runs there." with title appTitle buttons {"Cancel", "Open Terminal"} default button "Open Terminal" cancel button "Cancel"
	installCliCopy()
	tell application "Terminal"
		activate
		do script "/bin/zsh " & quoted form of installedCliPath() & " setup"
	end tell
end openSetupInTerminal

on installedCliPath()
	return homePath() & "/.local/share/claude-profiles/bin/claude-profiles"
end installedCliPath

on installCliCopy()
	set resourcesDir to POSIX path of ((path to me as text) & "Contents:Resources:")
	set shareDir to homePath() & "/.local/share/claude-profiles"
	set binDir to homePath() & "/.local/bin"
	set linkPath to binDir & "/claude-profiles"
	set copyCommand to "/bin/rm -rf " & quoted form of (shareDir & ".new") & " && /bin/mkdir -p " & quoted form of (shareDir & ".new") & " " & quoted form of binDir
	repeat with itemName in {"bin", "lib", "VERSION"}
		set copyCommand to copyCommand & " && /usr/bin/ditto --noqtn " & quoted form of (resourcesDir & itemName) & " " & quoted form of (shareDir & ".new/" & itemName)
	end repeat
	set copyCommand to copyCommand & " && /bin/chmod -R go-w " & quoted form of (shareDir & ".new") & " && /bin/rm -rf " & quoted form of shareDir & " && /bin/mv " & quoted form of (shareDir & ".new") & " " & quoted form of shareDir & " && /bin/ln -sfn " & quoted form of installedCliPath() & " " & quoted form of linkPath
	do shell script copyCommand
	return linkPath
end installCliCopy

on installCommandLineTool()
	set linkPath to installCliCopy()
	set initLine to "eval \"$(claude-profiles shell-init zsh)\""
	set reply to display dialog "Installed: " & tildePath(linkPath) & " → ~/.local/share/claude-profiles" & return & return & "Make sure ~/.local/bin is on your PATH. To get claude-<profile> aliases and folder-based profile selection, add this line to ~/.zshrc:" & return & return & initLine & return & return & "After updating this app, run this action again to update the command-line tool." with title appTitle buttons {"Close", "Copy shell-init line"} default button "Close"
	if button returned of reply is "Copy shell-init line" then set the clipboard to initLine
end installCommandLineTool
