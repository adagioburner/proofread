# Proofread

Select text in any Mac app, press a hotkey, and Claude proofreads it. A panel shows every suggested change in place; you accept or reject each one, then press **Insert** to paste the result over your selection, or **Cancel** to leave everything as it was.

Your text goes straight from your Mac to Anthropic's API under your own API key. There's no account with anyone else, and nothing is changed without your say-so.

It's a [Hammerspoon](https://www.hammerspoon.org) Spoon: a small plugin for the free Mac automation app.

## How it works

1. **Hotkey.** Proofread copies your selection (it sends ⌘C) after saving whatever was on your clipboard.
2. **Claude.** The text and the instructions in [`prompt.md`](prompt.md) go to the Claude API. Claude returns the corrected text plus a short reason for each change.
3. **Review.** The panel compares your text with Claude's version word by word and marks every difference. The list of changes comes from that comparison, not from what Claude says it changed, so nothing can slip in unmarked.
4. **Insert.** Proofread switches back to your app and pastes the text with only the changes you accepted (it sends ⌘V). Then it puts your old clipboard back.

## Setup

**1. Install Hammerspoon** from [hammerspoon.org](https://www.hammerspoon.org) or with `brew install --cask hammerspoon`. Open it, and when asked, give it Accessibility access (System Settings → Privacy & Security → Accessibility). Proofread needs this to send ⌘C and ⌘V.

**2. Put this repo in Hammerspoon's Spoons folder.** The folder must be named `Proofread.spoon`:

```sh
mkdir -p ~/.hammerspoon/Spoons
git clone https://github.com/adagioburner/proofread.git ~/.hammerspoon/Spoons/Proofread.spoon
```

**3. Store your Anthropic API key in the Keychain.** Create a key at [platform.claude.com → Settings → API keys](https://platform.claude.com/settings/keys), then run this in Terminal and paste the key when asked (it may ask twice to confirm):

```sh
security add-generic-password -a "$USER" -s proofread-anthropic-api-key -w
```

To replace the key later, run the same command with `-U` added.

**4. Load the Spoon.** Click the Hammerspoon menu bar icon → *Open Config*, add these lines to `init.lua`, and save:

```lua
hs.loadSpoon("Proofread")
spoon.Proofread:bindHotkeys({ proofread = { { "ctrl", "alt" }, "p" } })
```

**5. Reload.** Click the Hammerspoon menu bar icon → *Reload Config*.

Now select some text anywhere and press **⌃⌥P**.

## Using the panel

Each change appears in the text: what you wrote crossed out in red, the suggestion in green. A rejected change shows your original highlighted in yellow and the suggestion crossed out. The bar under the text shows the current change and why Claude suggests it.

| Key | Action |
| --- | --- |
| `←` `→` | previous / next change |
| `A` | accept the current change and move to the next |
| `R` | reject the current change and move to the next |
| `space` | toggle the current change |
| `↩` | insert the result over your selection |
| `esc` | cancel: nothing is changed |

Clicking a change toggles it too. **Accept all** / **Reject all** are at the top, and **Copy** puts the result on your clipboard instead of pasting it. The letter keys work with any keyboard layout, Cyrillic included.

## Changing the instructions

Edit [`prompt.md`](prompt.md). It takes effect the next time you press the hotkey, with no reload needed. Commit your edits to keep a history of what you tried.

## Settings

Set any of these in `~/.hammerspoon/init.lua` after `hs.loadSpoon("Proofread")`, then reload:

```lua
spoon.Proofread.model = "claude-haiku-5-5"   -- default "claude-sonnet-5-5"
spoon.Proofread.effort = "medium"            -- "low" (default, fastest), "medium" or "high"
spoon.Proofread.acceptByDefault = false      -- start with every change rejected
spoon.Proofread.promptFile = "~/Documents/my-proofread-prompt.md"
spoon.Proofread.panelSize = { w = 900, h = 650 }
spoon.Proofread.debug = true                 -- Inspect Element in the panel, extra logging
```

Other settings: `maxTokens` (default 16000), `keychainService` (the Keychain item name), and `clipboardRestoreDelay` (seconds to wait before restoring your clipboard, default 0.6).

**Cost.** You pay Anthropic per use. A few paragraphs cost about a cent with Sonnet and a fraction of that with Haiku. You can set a monthly spend limit in the Claude Console.

## Updating

```sh
cd ~/.hammerspoon/Spoons/Proofread.spoon && git pull
```

Then *Reload Config*. The clone is also your working copy: edit files there, reload, test, and commit and push from the same folder.

## Troubleshooting

- **Nothing happens when I press the hotkey.** Open the Hammerspoon Console from its menu bar icon and look for errors. Check that Hammerspoon has Accessibility access, and that no other app uses the same hotkey.
- **"Select some text first," but text was selected.** The app didn't put the selection on the clipboard when sent ⌘C. Try copying manually to see whether ⌘C works there.
- **The result was pasted in the wrong place, or added instead of replacing.** The selection was lost while the panel was open, for example by clicking elsewhere in the app. Use **Copy** and paste it yourself in that case.
- **Bold, links or other formatting disappeared.** Proofread works with plain text, so pasting replaces formatted text with plain text.
- **The panel doesn't react to keys.** Click inside it once.
- **An API error appears in the panel.** The message comes from the API. A 401 means the key is wrong; check it with `security find-generic-password -s proofread-anthropic-api-key -w`.

## Privacy

- The selected text goes only to `api.anthropic.com`, over HTTPS, under your API key. Anthropic doesn't use API inputs for model training by default (see its [commercial terms](https://www.anthropic.com/legal/commercial-terms)).
- The API key is read from your Keychain on each use and never written to a file.
- Your text isn't saved anywhere. With `debug = true`, API responses are written to the Hammerspoon Console.

## Files

| File | What it is |
| --- | --- |
| `init.lua` | the Spoon: hotkey, clipboard, Claude API call, paste-back |
| `panel.html` | the review panel: word diff, per-change accept/reject |
| `prompt.md` | the instructions sent to Claude |
| `tests/` | tests: `lua tests/test_flow.lua` runs the Spoon against a simulated Hammerspoon (needs Lua 5.4, e.g. `brew install lua`); `python3 tests/panel_test.py` tests the panel in a headless browser (needs Python Playwright) |
