on run argv
    set mountFolder to POSIX file (item 1 of argv) as alias
    tell application "Finder"
        tell folder mountFolder
            open
            try
                delay 1
                set options to icon view options of container window
                if current view of container window is not icon view then error "Installer did not reopen in icon view"
                if toolbar visible of container window then error "Installer toolbar is visible"
                if statusbar visible of container window then error "Installer status bar is visible"
                if icon size of options is not 104 then error "Incorrect saved icon size"
                if position of item "AiQuotaBar.app" is not {170, 210} then error "Incorrect app position"
                if position of item "Applications" is not {470, 210} then error "Incorrect Applications position"
                set savedBounds to bounds of container window
                if (item 3 of savedBounds) - (item 1 of savedBounds) is not 640 then error "Incorrect saved window width"
                if (item 4 of savedBounds) - (item 2 of savedBounds) is not 448 then error "Incorrect saved window height"
                close
                return "Finder reopen verified: 640x420 content, 104pt icons, app (170,210), Applications (470,210)"
            on error messageText number messageNumber
                close
                error messageText number messageNumber
            end try
        end tell
    end tell
end run
