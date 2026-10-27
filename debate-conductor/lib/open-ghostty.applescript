-- argv is data, never AppleScript source or input into the PM's terminal.
on run argv
  tell application "Ghostty"
    set cfg to new surface configuration
    -- The surface API accepts raw command text (no shell: prefix). On macOS
    -- Ghostty wraps it with exec -l, so argv[1] starts with an executable.
    -- v1.3.1 src/apprt/embedded.zig and src/termio/Exec.zig.
    set command of cfg to item 1 of argv
    set initial working directory of cfg to item 2 of argv
    set wait after command of cfg to true
    set win to new window with configuration cfg
    activate window win
    return id of win
  end tell
end run
