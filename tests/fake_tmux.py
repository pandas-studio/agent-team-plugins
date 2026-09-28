#!/usr/bin/env python3
"""A stateful stand-in for the tmux calls the --here layouts make (#100).

State lives in the JSON file named by FAKE_TMUX_STATE:
  {"current": "%0", "next": 1, "windows": {"@0": {"options": {}, "panes": ["%0"]}},
   "fail": {"split-window": 2}, "calls": [[...argv...], ...]}
Pane ids are never reused. "-t %N" resolves to the window holding pane %N.
"fail" makes the Nth call of a subcommand exit 1, after recording it.
Supports the calls the layouts make, plus kill-pane and break-pane -s for
the tests to change a window the way a user would.
"""

import json
import os
import sys


def main(argv):
    path = os.environ["FAKE_TMUX_STATE"]
    with open(path) as f:
        state = json.load(f)
    state["calls"].append(argv)
    cmd, args = argv[0], argv[1:]
    counts = state.setdefault("counts", {})
    counts[cmd] = counts.get(cmd, 0) + 1
    rc, out = 0, ""
    if state.get("fail", {}).get(cmd) == counts[cmd]:
        rc = 1
    else:
        rc, out = run(state, cmd, args)
    with open(path, "w") as f:
        json.dump(state, f)
    sys.stdout.write(out)
    return rc


def opts(args, flags_with_value=("-t", "-F", "-c", "-s")):
    """Split tmux-style args into ({flag: value or True}, positionals)."""
    flags, pos, i = {}, [], 0
    while i < len(args):
        a = args[i]
        if a in flags_with_value:
            flags[a] = args[i + 1]
            i += 2
        elif a.startswith("-") and len(a) > 1 and not pos:
            for ch in a[1:]:
                flags["-" + ch] = True
            i += 1
        else:
            pos.append(a)
            i += 1
    return flags, pos


def window_of(state, target):
    pane = target or state["current"]
    for wid, win in state["windows"].items():
        if pane in win["panes"]:
            return wid, win, pane
    raise LookupError(pane)


def run(state, cmd, args):
    flags, pos = opts(args)
    try:
        wid, win, pane = window_of(state, flags.get("-t") or flags.get("-s"))
    except LookupError:
        return 1, ""
    if cmd == "display-message":
        fmt = pos[0] if pos else ""
        return 0, {"#{pane_id}": pane, "#S": "fake"}.get(fmt, fmt) + "\n"
    if cmd == "show-options":
        value = win["options"].get(pos[0])
        if value is None:
            return (0, "") if "-q" in flags else (1, "")
        return 0, value + "\n"
    if cmd == "set-option":
        if "-u" in flags:
            win["options"].pop(pos[0], None)
        else:
            win["options"][pos[0]] = pos[1]
        return 0, ""
    if cmd == "split-window":
        new = "%%%d" % state["next"]
        state["next"] += 1
        win["panes"].insert(win["panes"].index(pane) + 1, new)
        state.setdefault("splits", []).append(
            {"target": pane, "dir": "h" if "-h" in flags else "v", "new": new})
        return 0, (new + "\n") if "-P" in flags else ""
    if cmd == "list-panes":
        return 0, "".join(p + "\n" for p in win["panes"])
    if cmd == "select-pane":
        win["active"] = pane
        return 0, ""
    if cmd == "kill-pane":
        win["panes"].remove(pane)
        if not win["panes"]:
            del state["windows"][wid]
        return 0, ""
    if cmd == "break-pane":
        # -s PANE: move it into a new window of its own.
        src = flags.get("-s")
        _, from_win, _ = window_of(state, src)
        from_win["panes"].remove(src)
        new_id = "@%d" % (max(int(w[1:]) for w in state["windows"]) + 1)
        state["windows"][new_id] = {"options": {}, "panes": [src]}
        return 0, ""
    if cmd in ("rename-window", "select-layout", "send-keys"):
        return 0, ""
    return 1, ""


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
