-- Standalone tests for CustomFilters.CompileFilter.
-- Run from the repo root with a Lua 5.1 interpreter:
--   lua tests/customfilters_compile.lua

-- Minimal stand-ins for the parts of Prat touched while the module file loads
local loader
local module = { PL = setmetatable({}, { __index = function(_, k) return k end }) }
local noop = function() end
Prat = setmetatable({
	AddModuleToLoad = function(_, fn) loader = fn end,
	NewModule = function() return module end,
}, { __index = function() return noop end })

dofile("modules/CustomFilters.lua")
loader()

local compile = module.CompileFilter

local failures, count = 0, 0

local function check(desc, ok)
	count = count + 1
	if not ok then
		failures = failures + 1
		print("FAIL: " .. desc)
	end
end

local function filter(searchfor, opts)
	opts = opts or {}
	return {
		searchfor = searchfor,
		matchtype = opts.matchtype or "text",
		ignorecase = opts.ignorecase or false,
		wholeword = opts.wholeword or false,
	}
end

local function expectPattern(f, expected)
	local got = compile(f)
	check(("compile %q -> %q (got %q)"):format(f.searchfor, expected, got), got == expected)
end

local function expectMatch(f, subjects, shouldMatch)
	local pattern = compile(f)
	for _, s in ipairs(subjects) do
		local matched = s:find(pattern) ~= nil
		check(("%q %s %q"):format(f.searchfor, shouldMatch and "should match" or "should not match", s),
			matched == shouldMatch)
	end
end

-- Legacy Lua pattern filters pass through untouched, whatever the options say
expectPattern(filter("%d+g", { matchtype = "pattern", ignorecase = true, wholeword = true }), "%d+g")
expectPattern({ searchfor = "abc" }, "abc") -- no matchtype saved at all

-- Empty / missing search text
expectPattern(filter(""), "")
expectPattern(filter(nil), "")

-- Plain text escapes every magic character
expectPattern(filter("1.5k"), "1%.5k")
expectPattern(filter("^$()%.[]*+-?"), "%^%$%(%)%%%.%[%]%*%+%-%?")
expectMatch(filter("(wts)"), { "[(WTS)] no", "lol wts boost" }, false)
expectMatch(filter("(wts)"), { "lol (wts) boost" }, true)
expectMatch(filter("a.b"), { "axb" }, false)
expectMatch(filter("a.b"), { "a.b" }, true)

-- Case sensitivity
expectPattern(filter("murloc", { ignorecase = true }), "[mM][uU][rR][lL][oO][cC]")
expectMatch(filter("murloc"), { "Murloc" }, false)

-- The "murloc" case: ignore case, anywhere
local murloc = filter("murloc", { ignorecase = true })
expectMatch(murloc, {
	"murloc",
	"MURLOC",
	"Murlocs everywhere",
	"xXmUrLoCXx",
	"mrglmurlocmrgl",
}, true)
expectMatch(murloc, { "murl oc", "mur-loc", "nothing here" }, false)

-- The "anal" case: ignore case, whole word
local anal = filter("anal", { ignorecase = true, wholeword = true })
expectPattern(anal, "%f[%w\128-\255][aA][nN][aA][lL]%f[^%w\128-\255]")
expectMatch(anal, {
	"anal",
	"anal [Rupture]",
	"ANAL!",
	"lol anal",
	"(anal)",
	"anal's",
	"anal |cff71d5ff|Hspell:12345|h[Rupture]|h|r",
}, true)
expectMatch(anal, {
	"my analysis of the build",
	"canal",
	"banal",
	"analyst LF guild",
	"anal123",
	"anal\195\169", -- followed by a UTF-8 letter (e-acute)
}, false)

-- Whole word only adds a frontier on sides that start/end with a word character
expectPattern(filter("!!go", { wholeword = true }), "!!go%f[^%w\128-\255]")
expectPattern(filter("go!!", { wholeword = true }), "%f[%w\128-\255]go!!")
expectPattern(filter("!!", { wholeword = true }), "!!")
expectMatch(filter("!!go", { wholeword = true }), { "x!!go now" }, true)
expectMatch(filter("!!go", { wholeword = true }), { "x!!gone" }, false)

-- Whole word without ignore case
expectMatch(filter("anal", { wholeword = true }), { "anal" }, true)
expectMatch(filter("anal", { wholeword = true }), { "ANAL" }, false)

-- Compiled patterns also work when re-applied to just the matched text, as the
-- replacement step in match() does
check("replacement on matched substring", ("anal"):gsub(compile(anal), "***") == "***")

-- Registration follows the Enabled flag. A filter saved as disabled isn't
-- registered at load, so enabling it later must register it.
do
	local opts = filter("murloc", { ignorecase = true })

	module.modulePatterns = nil -- module disabled: nothing registers, nothing errors
	opts.enabled = true
	module:SyncPattern(opts, "inbound")
	check("no registration while module disabled", module:FindPatternInfo(opts) == nil)

	module.modulePatterns = {}
	opts.enabled = false
	module:SyncPattern(opts, "inbound")
	check("disabled filter not registered", module:FindPatternInfo(opts) == nil)

	opts.enabled = true
	module:SyncPattern(opts, "inbound")
	local info = module:FindPatternInfo(opts)
	check("enabling registers the filter", info ~= nil)
	check("registered with compiled pattern", info and info.pattern == compile(opts))

	opts.wholeword = true
	module:SyncPattern(opts, "inbound")
	info = module:FindPatternInfo(opts)
	check("editing recompiles in place", info and info.pattern == compile(opts) and #module.modulePatterns == 1)

	opts.enabled = false
	module:SyncPattern(opts, "inbound")
	check("disabling unregisters the filter", module:FindPatternInfo(opts) == nil and #module.modulePatterns == 0)
end

-- Channel scope and "Ignore My Messages", run through a registered filter's real
-- match function the way the pattern engine calls it
do
	local MY_GUID, OTHER_GUID = "Player-1-0000000A", "Player-1-0000000B"
	UnitGUID = function(unit) return unit == "player" and MY_GUID or nil end

	local opts = filter("murloc", { ignorecase = true })
	opts.enabled = true
	opts.block = true
	opts.replacewith = "%1"
	opts.ignoreself = true
	opts.inchannels = { SAY = true, YELL = true, EMOTE = true, CHANNEL = true }

	module.modulePatterns = {}
	module:RegisterPattern(opts, "inbound")
	local info = module:FindPatternInfo(opts)

	local function blocked(chatType, guid, channel)
		local message = { CHATTYPE = chatType, GUID = guid, ORG = { CHANNEL = channel } }
		Prat.SplitMessage = message
		info.matchfunc("Murloc")
		return message.DONOTPROCESS == true
	end

	check("blocks other player in Trade", blocked("CHANNEL", OTHER_GUID, "Trade"))
	check("blocks other player in /say", blocked("SAY", OTHER_GUID))
	check("ignores my own Trade message", not blocked("CHANNEL", MY_GUID, "Trade"))
	check("whispers out of scope", not blocked("WHISPER", OTHER_GUID))
	check("guild out of scope", not blocked("GUILD", OTHER_GUID))

	-- Whisper echo is mine even though it carries the recipient's GUID
	opts.inchannels.WHISPER_INFORM = true
	check("ignores my outgoing whisper echo", not blocked("WHISPER_INFORM", OTHER_GUID))
	opts.ignoreself = false
	check("whisper echo filtered when ignoreself off", blocked("WHISPER_INFORM", OTHER_GUID))
	check("own Trade message filtered when ignoreself off", blocked("CHANNEL", MY_GUID, "Trade"))
	opts.ignoreself = true
	opts.inchannels.WHISPER_INFORM = nil

	-- Per-channel overrides on top of the CHANNEL default
	opts.inchannels.Trade = false
	check("channel unticked individually", not blocked("CHANNEL", OTHER_GUID, "Trade"))
	check("other channels still follow CHANNEL", blocked("CHANNEL", OTHER_GUID, "General"))

	opts.inchannels.CHANNEL = false
	opts.inchannels.Trade = true
	check("Trade-only: Trade blocked", blocked("CHANNEL", OTHER_GUID, "Trade"))
	check("Trade-only: General not blocked", not blocked("CHANNEL", OTHER_GUID, "General"))

	module.modulePatterns = nil
end

print(("%d/%d checks passed"):format(count - failures, count))
if failures > 0 then
	os.exit(1)
end
