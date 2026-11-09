-- Lays out the Finder window of the mounted disk image. Argument: the volume name.
-- 720 x 472 bounds give 720 x 440 of content under a 32 pt title bar; positions are icon centres.
on run argv
	tell application "Finder"
		tell disk (item 1 of argv)
			open
			set cw to container window
			set current view of cw to icon view
			set toolbar visible of cw to false
			set statusbar visible of cw to false
			set bounds of cw to {120, 120, 840, 592}
			set opts to icon view options of cw
			set arrangement of opts to not arranged
			set icon size of opts to 128
			set text size of opts to 13
			set shows item info of opts to false
			set shows icon preview of opts to false
			set background picture of opts to file ".background:background.tiff"
			set position of item "Toss.app" of cw to {186, 246}
			set position of item "Applications" of cw to {534, 246}
			set position of item "User Guide.txt" of cw to {642, 332}
			update without registering applications
			delay 2
			close
		end tell
	end tell
end run
