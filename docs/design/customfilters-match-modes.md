# CustomFilters: match modes (ignore case, whole word)

Status: phase 1 implemented, not yet tested in game
Branch: `feature/customfilters-case-insensitive`

## Problem

Trade chat gets flooded with spam that repeats a few keywords. The user wants
to block any message that matches a simple rule, for example:

| Rule     | Case       | Scope       | Should block                              | Should not block               |
|----------|------------|-------------|-------------------------------------------|--------------------------------|
| `murloc` | ignore     | anywhere    | `MURLOC`, `Murlocs`, `xXmUrLoCXx`         | n/a                            |
| `anal`   | ignore     | whole word  | `anal [Rupture]`, `ANAL!`, `lol anal`     | `my analysis`, `canal`, `banal` |

The CustomFilters module can already block messages, limited to particular
chat types and channels. It can't express these rules easily, because the
search text is passed straight to Lua `string.gsub` as a pattern:

- matching is case-sensitive (`murloc` doesn't match `Murloc`)
- there's no whole-word option
- characters such as `.`, `-`, `%`, `(` and `[` are pattern syntax, so typing
  plain text can quietly misbehave

The Bayesian `Filtering` module (`useai`) solves a different problem and isn't
affected by this work.

## Goals

Phase 1 (this branch):

1. **Plain text** match type: the search text is taken literally.
2. **Ignore case** option.
3. **Whole word** option: the match must not have a word character directly
   before or after it.
4. Existing filters behave exactly as they do today, and saved settings need
   no migration.

Later phases (out of scope here, but the design must leave room for them):

- Phase 2: ignore case and whole word for **Lua pattern** filters, which means
  rewriting the pattern so letters match either case.
- Phase 3: a **regex** match type using a small pure-Lua regex engine
  (alternation, groups, `{n,m}`, `\b`, `(?i)`). WoW's Lua 5.1 has no regex.
- Exceptions list for each filter (words that cancel a match).
- Handling link text (see [Known limitations](#known-limitations)).

## Current architecture (relevant parts)

- `modules/CustomFilters.lua`: each filter is a saved table under
  `profile.inbound[key]` or `profile.outbound[key]`, with `searchfor`,
  `replacewith`, `block`, `inchannels` and other fields. `RegisterPattern`
  wraps each enabled filter in a `patterninfo` table and registers it with the
  pattern engine at priority 46.
- `services/patterns.lua`: `MatchPatterns` runs
  `text:gsub(v.pattern, matchfunc)` for each registered pattern in priority
  order, on `m.MESSAGE`. If a filter sets `DONOTPROCESS`, the message is
  blocked (`addon/addon.lua`, around line 243).
- `match()` in CustomFilters runs once per match. It checks the channel scope,
  then applies the replacement, highlight, sink, sound and block actions.

## Design

### Data model

Add two new fields to each filter, and use the existing `searchfor` field
differently depending on the match type:

| Field        | Type   | Default     | Meaning                                    |
|--------------|--------|-------------|--------------------------------------------|
| `matchtype`  | string | `"pattern"` | `"pattern"` (Lua pattern, legacy) or `"text"` |
| `ignorecase` | bool   | `false`     | match letters in either case              |
| `wholeword`  | bool   | `false`     | match only at word boundaries             |

Defaults go in the existing `patterndefaults["*"]` table. AceDB doesn't write
default values to SavedVariables, so existing filters read as
`matchtype = "pattern"` with both options off, which is today's behaviour.
Phase 3 adds `"regex"` as a third `matchtype` value.

In phase 1, the `ignorecase` and `wholeword` toggles are disabled in the UI
unless `matchtype == "text"`. Phase 2 enables them for `"pattern"` too.

### Compiling the pattern

Add a pure function that builds the Lua pattern the engine actually uses:

```lua
-- returns a Lua pattern string, or nil + error message
function module:CompileFilter(matchopts)
```

It runs when a filter is registered or changed, never once per message. The
result goes in `patterninfo.pattern`, a runtime table, and **not** in
`matchopts`, so compiled patterns are never saved to SavedVariables.

For `matchtype == "text"`:

1. **Escape** every character that is special in Lua patterns:
   `^$()%.[]*+-?` each get a `%` in front.
2. **Ignore case**: replace each ASCII letter `c` with `[cC]`. Escaped
   characters are never letters, so steps 1 and 2 can't interfere with each
   other.
3. **Whole word**: wrap the result in frontier patterns:

   ```lua
   local WORD = "%w\128-\255"            -- ASCII letters/digits + any UTF-8 byte
   pattern = "%f[" .. WORD .. "]" .. pattern .. "%f[^" .. WORD .. "]"
   ```

   - `%f` (frontier) works in WoW's Lua 5.1 even though the 5.1 manual doesn't
     document it. The start and end of the string count as `\0`, which is
     never a word character, so `anal` at the start or end of a message still
     matches.
   - Treating bytes `\128-\255` as word characters keeps multi-byte UTF-8
     letters together, so `anal` followed by an accented letter is not counted
     as a whole word.
   - Underscore and apostrophe are **not** word characters, so `murloc's`
     contains the whole word `murloc`. That seems right for chat.
   - Whole word applies to the edges of the search text only. If the search
     text itself starts or ends with punctuation (for example `!!anal`), the
     frontier on that side may never match. In that case we skip the frontier
     on that side.

Examples:

| Input    | ignorecase | wholeword | Compiled pattern                                        |
|----------|------------|-----------|---------------------------------------------------------|
| `murloc` | yes        | no        | `[mM][uU][rR][lL][oO][cC]`                              |
| `anal`   | yes        | yes       | `%f[%w\128-\255][aA][nN][aA][lL]%f[^%w\128-\255]`       |
| `1.5k`   | no         | no        | `1%.5k`                                                 |

For `matchtype == "pattern"` (phase 1), `searchfor` is returned unchanged.

### Fixing the replacement step

`match()` currently re-runs `textout:gsub(matchopts.searchfor, ...)` to apply
the replacement. Once the compiled pattern differs from `searchfor`, that's
wrong. `match()` must use the compiled pattern instead, passed in from the
`patterninfo` closure. Frontier patterns still work when re-applied to the
matched substring on its own, because its ends count as string boundaries.

### Keeping the pattern up to date

`UpdatePattern(matchopts)` already rebuilds `patterninfo` when `searchfor`
changes. It also needs to:

- recompile through `CompileFilter`
- run when `matchtype`, `ignorecase` or `wholeword` change. Their option `set`
  must be `UpdatePatternValue`, not `SetPatternValue`.

`RegisterPattern` compiles in the same way.

### Validation

Plain text filters compile to valid patterns by construction.

Lua pattern filters can currently throw an error inside `gsub` at chat time
if the pattern is malformed, and they'll do so for every message.

**Deferred to phase 2.** The obvious check, `pcall(string.find, "", pattern)`,
isn't reliable. Lua 5.1 reads the pattern only as far as it needs to, so on an
empty subject `abc[` fails at `a` and never reaches the unclosed `[`. Proper
validation needs a small pattern syntax checker. Phase 2 needs a pattern
parser for case folding anyway, so validation belongs there.

### Options UI

The per-filter group currently looks like this: Name, Enabled, *Pattern Info*
(Search Pattern, Replacement Text), *Match Options* (Block, Secondary Output,
Sound, Hilight, ...), channels, output.

Add the new controls next to Search Pattern:

- **Match Type** (select): "Lua pattern" or "Plain text"
- **Ignore Case** (toggle)
- **Whole Word** (toggle)

"Search Pattern" stays as the field label, and its description changes
depending on the match type.

New strings go in `locales/enUS.lua` under the `CustomFilters/` prefix. The
other locale files currently contain no `CustomFilters/` strings, so nothing
else needs updating.

### Defaults for newly added filters

**Decision:** new filters default to **plain text, ignore case on, whole word
off**. Most players aren't programmers, and a plain-text search that ignores
case is what they'll expect. Anyone who wants a Lua pattern can switch the
match type.

Existing filters must keep working exactly as before, so these defaults are
**not** put in `patterndefaults["*"]`. Existing saved filters have no
`matchtype`, and changing the stored default would silently turn them into
plain-text filters. Instead, `AddPattern` sets `matchtype = "text"` and
`ignorecase = true` explicitly on each filter it creates. Because those values
differ from the stored defaults, AceDB saves them.

### Channel scope and own messages for new filters

In testing, a new `murloc` filter also hid the tester's own outgoing whispers.
A new inbound filter used to start with almost every chat type ticked,
including the echo of your own outgoing whisper (`WHISPER_INFORM`). The
whisper was still sent; only the local copy was hidden.

**Decision:** new inbound filters (set in `AddPattern`, with the stored
defaults unchanged for the same reason as above) start with:

- **Public chat only:** `SAY`, `YELL`, `EMOTE` and `CHANNEL` ticked, and every
  other default chat type explicitly unticked. `CHANNEL` covers all numbered
  channels (Trade, General, ...), and each one can be overridden individually.
  Ticking only Trade works because the per-channel keys and the message's
  `ORG.CHANNEL` both use the base name ("Trade", without the "- City" part).
- **Ignore My Messages** (`ignoreself = true`, a new field with stored default
  `false`). A message is yours if its `CHATTYPE` is `WHISPER_INFORM` or
  `BN_WHISPER_INFORM`, or if its sender GUID equals `UnitGUID("player")`.
  - The whisper echo carries the *recipient's* GUID, which is why the chat
    type check is needed.
  - Secret GUIDs are treated as not yours, matching `Filtering`.
  - The option is hidden for outbound filters, since every outbound message is
    yours.

Possible follow-up: All / None / Public preset buttons above the channel list.

### Fixes to existing behaviour (found during in-game testing)

1. **Enabling a disabled filter did nothing until `/reload`.**
   - `OnModuleEnable` only registers filters that are enabled.
   - Ticking Enabled later only changed the saved flag. `UpdatePattern` quietly
     ignores filters that aren't registered.
   - So a filter saved as disabled stayed inactive, whatever you edited. This
     is what made the tester's pre-existing filters appear broken.
   - Fix: every per-filter setting now goes through `SyncPattern(matchopts,
     mode)`. It registers, updates or unregisters the filter to match its
     Enabled flag.
   - `RegisterPattern`, `UnregisterPattern` and `UpdatePattern` also no longer
     error when the module is disabled (`modulePatterns == nil`). Previously,
     editing a filter while the module was off threw an error.
2. **A filter could only be deleted from the Inbound/Outbound page**, using the
   "Remove Pattern" dropdown, which is hard to find.
   - Fix: each filter's own page now has a **Delete Filter** button, with a
     confirmation prompt.
   - After deleting, the options dialog goes back to the parent page, since the
     filter's page no longer exists.
   - The dropdown remains, and both share `DeletePattern(mode, key)`.

## Known limitations

1. **Link text.** Filters run against `m.MESSAGE`, which contains raw
   hyperlinks such as `|cff...|Hitem:1234::...|h[Murloc Fin]|h|r`.
   - With ignore case, a `murloc` filter will block people selling
     `[Murloc Fin]`-type items.
   - Link payloads (`item:1234:...`) are also searched, so a whole-word
     filter on a number could hit item IDs.
   - The result also depends on other modules. If LinkInfoIcons or the player
     name modules are on, they register patterns at a higher priority (41–45)
     that swap some of this text for `@##N##@` tokens before CustomFilters
     (46) sees it.

   Future work: a per-filter "ignore link text" option that matches against a
   copy of the message with link markup removed (or reduced to the visible
   `[label]`). Blocking would still act on the original message. **Deferred.**

2. **Only ASCII letters ignore case.** Accented Latin, Cyrillic and CJK
   letters are matched exactly as typed. Lua 5.1 has no Unicode case tables.
   Supporting this would need a small folding table, which can be added later.

3. **Whole word uses a fixed definition of "word character":** ASCII
   letters/digits plus any non-ASCII byte. Text such as `anal123` is not a
   whole-word match for `anal`.

4. **The scope check runs only after a match.** The channel check happens
   inside `match()`, after `gsub` has found something, so every enabled filter
   runs its pattern on every message type. That's fine for a handful of
   filters, and it's how things already work.

## Testing

There's no automated test harness in the repo, and the dev machine has no
Lua interpreter.

- **Unit:** `tests/customfilters_compile.lua` loads the real
  `modules/CustomFilters.lua` with minimal Prat stubs and tests
  `CompileFilter`. It covers:
  - the examples in [Problem](#problem)
  - legacy pass-through
  - magic characters and the empty string
  - leading or trailing punctuation with whole word
  - UTF-8 neighbours
  - links next to a word
  - re-applying the compiled pattern to the matched text
  - registration following the Enabled flag, including while the module is
    disabled
  - channel scope (including per-channel overrides and Trade-only) and Ignore
    My Messages, run through a registered filter's real match function

  Run it from the repo root with `lua tests/customfilters_compile.lua`
  (Lua 5.1). A non-zero exit code means a failure. It isn't wired into CI yet.
  `docs/` and `tests/` are excluded from the addon package in `.pkgmeta`.
- **Static:** luacheck passes (`.luacheckrc`).
- **In game:** test on Mainline and WoW Forever.
  - Add a `murloc` (text, ignore case) filter and an `anal` (text, ignore
    case, whole word) filter, both set to Block, scoped to Trade.
  - Use `/run` with `ChatFrame_MessageEventHandler`, or a second character,
    to confirm the expected blocking.
  - Confirm that existing Lua pattern filters behave exactly as before.

## Phase plan

1. **Phase 1:** `matchtype` text, `ignorecase`, `wholeword`, compile step,
   replacement fix, UI, enUS strings, and new filters defaulting to plain
   text with ignore case.
2. **Phase 2:** ignore case and whole word for Lua pattern filters
   (case-folding pattern rewriter that understands `%x` escapes and `[...]`
   sets, including ranges), plus pattern validation when a filter is saved.
3. **Phase 3:** regex match type (pure-Lua engine, bundled or written here),
   compiled to a matcher function instead of a Lua pattern. `MatchPatterns`
   would need a hook for non-gsub matchers.
4. **Later:** link-text handling, per-filter exceptions list, Unicode case
   folding.
