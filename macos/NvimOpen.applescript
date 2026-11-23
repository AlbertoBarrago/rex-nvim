-- NvimOpen: LaunchServices handler that passes opened files to `rex-nvim open`.
-- lib/install.zsh compiles this into ~/Applications/NvimOpen.app and puts the
-- path of this clone's bin/rex-nvim in place of the placeholder below.

property rexNvim : "__REX_NVIM_BIN__"

on open theItems
	-- The app holds an absolute path: a moved or deleted clone must say so,
	-- not fail silently on every click.
	try
		do shell script "test -x " & quoted form of rexNvim
	on error
		display notification "rex-nvim not found at " & rexNvim & ". Run rex-nvim install from the clone." with title "rex-nvim"
		return
	end try
	set args to ""
	repeat with anItem in theItems
		set args to args & " " & quoted form of POSIX path of anItem
	end repeat
	-- rex-nvim reports its own failures (notification and log), so its exit
	-- status is not turned into a second notification here.
	do shell script quoted form of rexNvim & " open" & args & " || true"
end open

on run
	display notification "Open a file with NvimOpen to edit it in nvim." with title "rex-nvim"
end run
