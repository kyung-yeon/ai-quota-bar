on run argv
    set mountFolder to POSIX file (item 1 of argv) as alias
    tell application "Finder"
        tell folder mountFolder
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set pathbar visible of container window to false
            set sidebar width of container window to 0
            set bounds of container window to {200, 140, 840, 588}
            set options to icon view options of container window
            set arrangement of options to not arranged
            set icon size of options to 104
            set text size of options to 14
            set label position of options to bottom
            set shows item info of options to false
            set shows icon preview of options to true
            set background picture of options to file ".background:background.tiff"
            -- Keep hidden volume metadata outside the visible canvas, too.
            set position of every item to {900, 500}
            set position of item "AiQuotaBar.app" to {170, 210}
            set position of item "Applications" to {470, 210}
            update without registering applications
            delay 1
            close
            open
            delay 1
            close
        end tell
    end tell
end run
