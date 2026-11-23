-- NvimOpen: LaunchServices handler that passes opened files to `rex-nvim open`.
-- lib/install.zsh compiles this into ~/Applications/NvimOpen.app and puts the
-- path of this clone's bin/rex-nvim in place of the placeholder below.

on open theItems
	set args to ""
	repeat with anItem in theItems
		set args to args & " " & quoted form of POSIX path of anItem
	end repeat
	try
		do shell script quoted form of "__REX_NVIM_BIN__" & " open" & args
	on error errMsg
		display notification errMsg with title "rex-nvim"
	end try
end open

on run
	display notification "Open a file with NvimOpen to edit it in nvim." with title "rex-nvim"
end run
