-- argv is data, never AppleScript source or input into the PM's terminal.
on run argv
  tell application "Ghostty"
    set cfg to new surface configuration
    -- The embedded surface API already treats command as shell text, unlike
    -- the config-file parser. A literal shell: prefix becomes an executable.
    -- ghostty v1.3.1 src/apprt/embedded.zig (opts.command -> .shell).
    set command of cfg to item 1 of argv
    set initial working directory of cfg to item 2 of argv
    set wait after command of cfg to true
    set win to new window with configuration cfg
    activate window win
    return id of win
  end tell
end run
