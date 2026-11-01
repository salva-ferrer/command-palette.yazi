-- Command palette for Yazi (fzf based).
--
-- LOCAL PATCH over Mr-Ples/command-palette@e5e6105 (2026-11-01):
--   * keymap files are parsed with python3 tomllib instead of the hand-rolled
--     line parser (which only understood `[[mgr.prepend_keymap]]` tables, not
--     the inline `prepend_keymap = [ { on = ..., run = ... } ]` form),
--   * `ya.manager_emit` (removed in Yazi 26.x) -> `ya.emit`,
--   * `run` arrays, quoted args and `--flag`/`--key=val` are handled.
-- Fork: github.com/salva-ferrer/command-palette.yazi (package.toml points to it).
-- Also reads ~/.config/yazi/default-keymap.mgr.toml (vendored snapshot of Yazi's
-- built-in [mgr] keymap, so default bindings show up in the palette).

local function fail(s, ...)
	ya.notify { title = "Command Palette", content = string.format(s, ...), timeout = 5, level = "error" }
end

local function info(s, ...)
	ya.notify { title = "Command Palette", content = string.format(s, ...), timeout = 3, level = "info" }
end

-- Emits one line per binding: desc \t keys \t run
-- (run commands joined by \x1f; backslash, newline and tab escaped as \\ \n \t)
local PY = [==[
import glob, os, sys, tomllib
home = os.path.expanduser("~/.config/yazi")
files = [os.path.join(home, "keymap.toml"), os.path.join(home, "default-keymap.mgr.toml")] + sorted(glob.glob(os.path.join(home, "plugins", "**", "*.toml"), recursive=True))
def esc(s):
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
seen = set()
for f in files:
    try:
        with open(f, "rb") as fh:
            data = tomllib.load(fh)
    except Exception as e:
        print("skip %s: %s" % (f, e), file=sys.stderr)
        continue
    for layer in data.values():
        if not isinstance(layer, dict):
            continue
        for kind in ("prepend_keymap", "keymap", "append_keymap"):
            for e in layer.get(kind, []):
                on, run = e.get("on"), e.get("run")
                if on is None or run is None:
                    continue
                keys = "".join(on) if isinstance(on, list) else str(on)
                cmds = run if isinstance(run, list) else [run]
                cmds = [c.strip() for c in cmds if c.strip()]
                if not cmds:
                    continue
                desc = e.get("desc") or "(no description)"
                line = "%s\t%s\t%s" % (esc(desc), esc(keys), esc("\x1f".join(cmds)))
                if line in seen:
                    continue
                seen.add(line)
                print(line)
]==]

local function unescape(s)
	return (s:gsub("\\(.)", function(c)
		if c == "n" then return "\n" end
		if c == "t" then return "\t" end
		return c
	end))
end

local function get_all_commands()
	local out, err = Command("python3"):arg({ "-I", "-c", PY }):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not out then
		fail("Failed to run python3: %s", tostring(err))
		return {}
	end
	if not out.status.success then
		fail("Keymap parser failed: %s", out.stderr)
		return {}
	end
	local commands = {}
	for line in out.stdout:gmatch("[^\r\n]+") do
		local desc, keys, run = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
		if desc then
			commands[#commands + 1] = { desc = unescape(desc), key = unescape(keys), run = unescape(run), raw = run }
		end
	end
	return commands
end

-- Split a command line on whitespace, honouring '...' and "..." quoting.
local function tokenize(s)
	local tokens, i, n = {}, 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c:match("%s") then
			i = i + 1
		else
			local buf = ""
			while i <= n and not s:sub(i, i):match("%s") do
				local ch = s:sub(i, i)
				if ch == "'" or ch == '"' then
					local j = s:find(ch, i + 1, true)
					if not j then j = n + 1 end
					buf = buf .. s:sub(i + 1, j - 1)
					i = j + 1
				else
					buf = buf .. ch
					i = i + 1
				end
			end
			tokens[#tokens + 1] = buf
		end
	end
	return tokens
end

-- Execute one Yazi command string, as written in `run = "..."`.
local function execute_one(cmd)
	local name, rest = cmd:match("^(%S+)%s*(.*)$")
	if not name then return end

	if name == "shell" then
		-- shell [--block] [--confirm] [--orphan] [--] <command string verbatim>
		local opts = {}
		for _, flag in ipairs { "block", "confirm", "orphan" } do
			local pat = "%-%-" .. flag .. "%f[%s%z]"
			if rest:find(pat) then
				opts[flag] = true
				rest = rest:gsub(pat, "", 1)
			end
		end
		rest = rest:gsub("^%s+", ""):gsub("^%-%-%s+", ""):gsub("%s+$", "")
		-- A single surrounding pair of quotes is Yazi's own argument quoting.
		local q = rest:sub(1, 1)
		if (q == '"' or q == "'") and rest:sub(-1) == q and not rest:sub(2, -2):find(q, 1, true) then
			rest = rest:sub(2, -2)
		end
		if rest == "" then
			fail("Empty shell command: %s", cmd)
			return
		end
		opts[1] = rest
		ya.emit("shell", opts)
		return
	end

	-- Generic: positional args, `--flag` -> flag=true, `--key=val` -> key=val.
	-- A bare `--` (plugin arg separator) is dropped.
	local args = {}
	for _, tok in ipairs(tokenize(rest)) do
		if tok == "--" then
			-- skip
		elseif tok:sub(1, 2) == "--" then
			local k, v = tok:match("^%-%-([^=]+)=(.*)$")
			if k then
				args[k] = v
			else
				args[tok:sub(3)] = true
			end
		else
			args[#args + 1] = tok
		end
	end
	ya.emit(name, args)
end

local function execute_command(run)
	for cmd in (run .. "\x1f"):gmatch("(.-)\x1f") do
		if cmd ~= "" then
			execute_one(cmd)
		end
	end
end

local function show_command_palette()
	local commands = get_all_commands()
	if #commands == 0 then
		fail("No commands found in keymap files")
		return
	end

	local _permit = ui.hide()
	local child, err = Command("fzf")
		:arg({
			"--height=80%",
			"--layout=reverse",
			"--border",
			"--prompt=Command Palette: ",
			"--header=Type to search commands",
			"--preview-window=right:40%",
			"--preview=printf '%s' {4} | sed 's/\\\\n/\\n/g'",
			"--delimiter=\t",
			"--with-nth=1,2",
			"--bind=ctrl-/:toggle-preview",
		})
		:stdin(Command.PIPED)
		:stdout(Command.PIPED)
		:stderr(Command.INHERIT)
		:spawn()

	if not child then
		fail("Failed to spawn fzf: %s", tostring(err))
		return
	end

	local lines = {}
	for i, c in ipairs(commands) do
		-- field 3 = index, so the exact run string never goes through fzf
		lines[#lines + 1] = string.format("%s\t[%s]\t%d\t%s", c.desc:gsub("[\t\n]", " "), c.key:gsub("[\t\n]", " "), i, (c.raw:gsub("\031", "  |  ")))
	end
	child:write_all(table.concat(lines, "\n") .. "\n")
	child:flush()

	local output = child:wait_with_output()
	if not output then
		fail("Cannot read fzf output")
		return
	end
	if not output.status.success then
		-- 1 = no match, 130 = cancelled (Esc / Ctrl-C)
		if output.status.code ~= 1 and output.status.code ~= 130 then
			fail("fzf exited with error code: %s", tostring(output.status.code))
		end
		return
	end

	local idx = tonumber(output.stdout:match("\t(%d+)\t"))
	local sel = idx and commands[idx]
	if sel then
		execute_command(sel.run)
	end
end

return {
	entry = function()
		show_command_palette()
	end,
}
