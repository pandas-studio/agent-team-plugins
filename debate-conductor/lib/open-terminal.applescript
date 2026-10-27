on run argv
  set cmd to item 1 of argv
  tell application "Terminal"
    -- No existing target, including cold-start Resume windows: those may
    -- contain restored user work and must never receive the attach command.
    set newTab to do script cmd
    activate
    return tty of newTab
  end tell
end run
