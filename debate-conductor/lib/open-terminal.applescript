on run argv
  set cmd to item 1 of argv
  set wasRunning to application "Terminal" is running
  tell application "Terminal"
    if not wasRunning then
      launch
      -- Reuse only the sole idle startup tab of the app WE just launched.
      -- Never target a preexisting user's window or close an unknown window.
      if (count of windows) is 1 then
        set win to window 1
        if (count of tabs of win) is 1 and not busy of selected tab of win then
          set newTab to do script cmd in selected tab of win
          activate
          return tty of newTab
        end if
      end if
    end if
    set newTab to do script cmd
    activate
    return tty of newTab
  end tell
end run
