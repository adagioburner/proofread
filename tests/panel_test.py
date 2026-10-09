import json, sys, pathlib
from playwright.sync_api import sync_playwright

# Browser tests for panel.html. Needs Python Playwright:
#   pip install playwright && playwright install chromium
# Run from the repo folder:  python3 tests/panel_test.py [screenshot-dir]
PANEL = (pathlib.Path(__file__).resolve().parent.parent / "panel.html").as_uri()
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None

ORIGINAL = '''Hi, Carl—

A very good translation, let me go directly to the nits I wanted to pick.

- you can cut me into pieces, but I dont see how bee is rhymed with sachet. They don't even end in the same sound!

- "The stuffy smell is from the old sachet". To me the way it is phrased sounds like "we were looking for the source of the bad smell, and voila! it's from the old sachet!". The effect (on me) is somewhat comical. Maybe this needs rephrasing.

- Do the words "appear"? It's not even rhymed, so maybe it makes sense to change this and not risk getting the image of these words magically appearing in mid-air?

Thanks — Andrei
'''
CORRECTED = '''Hi, Carl—

A very good translation! Let me go directly to the nits I wanted to pick.

- You can cut me into pieces, but I don't see how "bee" rhymes with "sachet". They don't even end in the same sound!

- "The stuffy smell is from the old sachet". To me, the way it is phrased sounds like "we were looking for the source of the bad smell, and voilà! It's from the old sachet!". The effect (on me) is somewhat comical. Maybe this needs rephrasing.

- Do the words "appear"? It's not even rhymed, so maybe it makes sense to change this and not risk getting the image of these words magically appearing in mid-air?

Thanks — Andrei
'''
NOTES = [
  {"original": "translation, let", "replacement": "translation! Let", "reason": "Comma splice: split into two sentences."},
  {"original": "you can", "replacement": "You can", "reason": "Capitalize the first word of the point."},
  {"original": "dont", "replacement": "don't", "reason": "Missing apostrophe."},
  {"original": "how bee is rhymed with sachet", "replacement": "how \"bee\" rhymes with \"sachet\"", "reason": "\"Rhymes with\" is the idiomatic form; quote words used as words."},
  {"original": "To me the way", "replacement": "To me, the way", "reason": "Comma after an introductory phrase."},
  {"original": "voila! it's", "replacement": "voilà! It's", "reason": "Accent on voilà; capitalize after an exclamation mark."},
]

STUB = "window.__posted = []; window.webkit = {messageHandlers: {proofread: {postMessage: m => window.__posted.push(JSON.parse(JSON.stringify(m)))}}};"

failures = []
def shot(page, name):
    if OUT: page.screenshot(path=str(OUT / name))

def check(cond, label):
    print(("PASS " if cond else "FAIL ") + label)
    if not cond: failures.append(label)

with sync_playwright() as p:
    browser = p.chromium.launch()
    for scheme in ["light", "dark"]:
        page = browser.new_page(viewport={"width": 760, "height": 560}, color_scheme=scheme)
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.add_init_script(STUB)
        page.goto(PANEL)
        posted = page.evaluate("window.__posted")
        check(posted == [{"action": "ready"}], f"[{scheme}] posts ready on load")

        if scheme == "light":
            # ---- Core: randomized diff round-trip ----
            res = page.evaluate("""() => {
              const C = window.ProofreadCore; let bad = 0; const N = 3000;
              const words = ['a','b','c','dont',"don't",' ','  ','\\n',',','.','!','the','The','x','é','мир','“','”'];
              const rnd = n => Array.from({length: Math.floor(Math.random()*n)}, () => words[Math.floor(Math.random()*words.length)]).join('');
              for (let i = 0; i < N; i++) {
                const a = rnd(40), b = Math.random() < .5 ? rnd(40) : a.replace(/a/g, 'b').replace(/dont/g, "don't");
                const ta = C.tokenize(a), tb = C.tokenize(b);
                if (ta.join('') !== a || tb.join('') !== b) { bad++; continue; }
                const ops = C.diffTokens(ta, tb);
                const ra = ops.filter(o => o[0] !== '+').map(o => o[1]).join('');
                const rb = ops.filter(o => o[0] !== '-').map(o => o[1]).join('');
                if (ra !== a || rb !== b) { bad++; continue; }
                const segs = C.buildSegments(a, b);
                segs.forEach(s => { if (s.type === 'chg') s.accepted = true; });
                if (C.finalText(segs) !== b) { bad++; continue; }
                segs.forEach(s => { if (s.type === 'chg') s.accepted = false; });
                if (C.finalText(segs) !== a) { bad++; continue; }
              }
              return {bad, N};
            }""")
            check(res["bad"] == 0, f"diff/segments round-trip on {res['N']} random pairs (bad={res['bad']})")

            # Diff is minimal for a simple case
            ops = page.evaluate("""() => window.ProofreadCore.diffTokens(
                window.ProofreadCore.tokenize('I dont see it'), window.ProofreadCore.tokenize("I don't see it"))""")
            check([o for o in ops if o[0] != '='] == [['-', 'dont'], ['+', "don't"]], "single-word change is one replace")

            # Large near-identical text stays fast
            ms = page.evaluate("""() => { const C = window.ProofreadCore;
              const a = Array.from({length: 4000}, (_, i) => 'word' + (i % 50)).join(' ');
              const b = a.replace(/word7 /g, 'wörd7 ');
              const t = performance.now(); C.buildSegments(a, b); return performance.now() - t; }""")
            check(ms < 1500, f"8k-token text with ~80 edits diffs in {ms:.0f} ms")

        # ---- The user's forum text ----
        page.evaluate("p => window.proofread.update(p)", {"state": "loading", "original": ORIGINAL, "model": "claude-sonnet-5-5"})
        shot(page, f"panel-loading-{scheme}.png")
        page.evaluate("p => window.proofread.update(p)", {
            "state": "result", "original": ORIGINAL, "corrected": CORRECTED, "changes": NOTES,
            "acceptByDefault": True, "model": "claude-sonnet-5-5"})
        changes = page.evaluate("window.proofread.state.changes.map(c => ({del: c.del, ins: c.ins, note: c.note}))")
        if scheme == "light":
            print(json.dumps(changes, ensure_ascii=False, indent=1))
        check(all(c["note"] for c in changes), f"[{scheme}] every change got a reason ({sum(1 for c in changes if c['note'])}/{len(changes)})")
        check(page.evaluate("window.proofread.result()") == CORRECTED, f"[{scheme}] all accepted -> corrected text")
        shot(page, f"panel-result-{scheme}.png")

        if scheme == "light":
            # Keyboard review: reject the 2nd change (R on it), check result
            page.keyboard.press("ArrowRight")
            cur = page.evaluate("window.proofread.state.current")
            check(cur == 1, "→ moves to the next change")
            second = changes[1]
            page.keyboard.press("KeyR")
            st = page.evaluate("window.proofread.state.changes.map(c => c.accepted)")
            check(st[1] is False and page.evaluate("window.proofread.state.current") == 2, "R rejects current and advances")
            expected = CORRECTED.replace(second["ins"], second["del"], 1) if second["ins"] else None
            check(page.evaluate("window.proofread.result()") == expected, "result keeps original for the rejected change")
            # Click a chip toggles it
            page.click(".chg >> nth=0")
            check(page.evaluate("window.proofread.state.changes[0].accepted") is False and page.evaluate("window.proofread.state.current") == 0, "clicking a change selects and toggles it")
            page.keyboard.press("Space")
            check(page.evaluate("window.proofread.state.changes[0].accepted") is True, "Space toggles current change back")
            shot(page, "panel-reviewing-light.png")
            # Reject all -> result == original
            page.click("#reject-all")
            check(page.evaluate("window.proofread.result()") == ORIGINAL, "Reject all -> original text")
            page.click("#accept-all")
            # Enter inserts
            page.evaluate("window.__posted = []")
            page.keyboard.press("Enter")
            posted = page.evaluate("window.__posted")
            check(posted == [{"action": "insert", "text": CORRECTED}], "Enter posts insert with the accepted text")
            page.evaluate("window.__posted = []")
            page.click("#copy")
            check(page.evaluate("window.__posted")[0]["action"] == "copy", "Copy button posts copy")
            page.evaluate("window.__posted = []")
            page.keyboard.press("Escape")
            check(page.evaluate("window.__posted") == [{"action": "cancel"}], "Esc posts cancel")

            # Clean (no changes)
            page.evaluate("p => window.proofread.update(p)", {"state": "result", "original": "All good here.", "corrected": "All good here.", "changes": {}})
            check(page.evaluate("window.proofread.state.phase") == "clean", "identical text -> 'No changes needed'")
            page.evaluate("window.__posted = []"); page.keyboard.press("Enter")
            check(page.evaluate("window.__posted") == [{"action": "cancel"}], "Enter closes when clean")
            shot(page, "panel-clean-light.png")

            # Error with code
            page.evaluate("p => window.proofread.update(p)", {"state": "error", "original": ORIGINAL,
                "message": "No Anthropic API key found in your Keychain. Store it by running this in Terminal and pasting the key when asked:",
                "code": "security add-generic-password -a \"$USER\" -s proofread-anthropic-api-key -w"})
            shot(page, "panel-error-light.png")
            page.evaluate("window.__posted = []"); page.keyboard.press("Enter")
            check(page.evaluate("window.__posted") == [{"action": "retry"}], "Enter retries on error")

            # Whitespace-only change and HTML-looking text are shown safely
            page.evaluate("p => window.proofread.update(p)", {"state": "result", "original": "a  b <b>x</b>\n\n\nc", "corrected": "a b <b>x</b>\n\nc", "changes": []})
            html = page.inner_html("#text")
            check("<b>x</b>" not in html and "&lt;b&gt;" in html, "text is escaped, never parsed as HTML")
            check(page.evaluate("window.proofread.result()") == "a b <b>x</b>\n\nc", "whitespace-only changes round-trip")

            # Russian text + physical-key shortcuts
            page.evaluate("p => window.proofread.update(p)", {"state": "result", "original": "Я не знаю что делать.", "corrected": "Я не знаю, что делать.", "changes": [{"original": "знаю что", "replacement": "знаю, что", "reason": "Запятая перед «что»."}]})
            ch = page.evaluate("window.proofread.state.changes.map(c => [c.del, c.ins, c.note])")
            check(ch == [["", ",", "Запятая перед «что»."]], f"Cyrillic text diffs to a single comma insertion {ch}")

        check(not errors, f"[{scheme}] no page errors {errors}")
        page.close()
    browser.close()

print("\nFAILURES:", failures if failures else "none")
sys.exit(1 if failures else 0)
