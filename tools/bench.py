#!/usr/bin/env python3
"""Fixaro model test: runs typos and rephrase jobs through your Ollama models, using the same
prompts Fixaro uses, and reports accuracy and speed.

  python3 tools/bench.py                      test every installed text model
  python3 tools/bench.py qwen3.5:4b lfm3      test only these

Results are printed and saved to tools/bench.txt. Ollama must be running."""
import json, pathlib, re, statistics, sys, time, urllib.error, urllib.request

BASE = "http://127.0.0.1:11434"
LLM_TIMEOUT = 1.5      # Fixaro falls back to the spell checker if the model takes longer than this

WORD_SYSTEM = ("You are a spelling corrector. The user typed a misspelled English word. Using the sentence for context, "
               "reply with ONLY the single correctly spelled word they meant. No explanation, no quotes, no punctuation.")

# Easy: the misspelling has one obvious fix.  (before, typo, after, spell-checker options, answer)
EASY = [
    ("I will ", "recieve", " it", ["receive", "relieve", "reprieve"], "receive"),
    ("Can you send me the ", "reprot", " today", ["report", "repot", "repost"], "report"),
    ("I spoke to ", "teh", " manager", ["the", "tech", "ten", "eh"], "the"),
    ("Please ", "chek", " the numbers", ["check", "cheek", "chef", "Czech"], "check"),
    ("I will see you ", "tomorow", " morning", ["tomorrow", "tomorrows"], "tomorrow"),
    ("The new ", "buisness", " plan", ["business", "businesses", "busyness"], "business"),
    ("It will ", "definately", " work", ["definitely", "defiantly", "definitively"], "definitely"),
    ("Thank you for your ", "paitence", " and", ["patience", "patients", "patent"], "patience"),
    ("I ", "beleive", " that", ["believe", "belief", "relieve"], "believe"),
    ("The loan ", "aplication", " was", ["application", "implication", "replication"], "application"),
    ("Please review the credit ", "polciy", " again", ["policy", "police", "polity"], "policy"),
    ("The customer did not ", "pya", " the", ["pay", "pa", "ply", "pye", "spa"], "pay"),
    ("We need to ", "adress", " this", ["address", "adores", "dress"], "address"),
    ("I sent you an ", "emial", " about", ["email", "emil", "enamel", "medial"], "email"),
    ("She is still in the ", "meting", " room", ["meeting", "melting", "mating", "metering"], "meeting"),
    ("The project ", "comittee", " will", ["committee", "committer"], "committee"),
    ("The team ", "perfromance", " was", ["performance", "preformance"], "performance"),
    ("Can we ", "shedule", " a call", ["schedule", "scheduled"], "schedule"),
]

# Context: the right fix depends on the words around it (the first option is often wrong).
# "a|b" means either answer is right.
CONTEXT = [
    ("the money ", "frim", " the bank", ["firm", "from", "fir", "film"], "from"),
    ("the new ", "frim", " policy", ["from", "firm", "fir", "film"], "firm"),
    ("I need to ", "fil", " the form", ["file", "fill", "fail", "foil", "fit"], "fill|file"),   # both are fine English
    ("Please ", "fil", " the report in the shared folder", ["fill", "file", "fail", "foil"], "file"),
    ("We ", "wnet", " to the office", ["want", "went", "wet", "net"], "went"),
    ("I ", "wnat", " to go home", ["went", "want", "what", "gnat"], "want"),
    ("The ", "bord", " meets on Monday", ["bird", "bored", "board", "bore", "Ford"], "board"),
    ("It was a ", "grat", " meeting", ["grant", "great", "grate", "rat"], "great"),
    ("We got the ", "grat", " from the ministry", ["great", "grant", "grate", "rat"], "grant"),
    ("That's a ", "fiar", " point", ["fire", "fair", "fiat", "fear", "far"], "fair"),
    ("The house caught ", "fiar", " last night", ["fair", "fire", "fiat", "fear"], "fire"),
    ("I'm ", "thier", " manager", ["tier", "their", "thief", "thigh"], "their"),
    ("Our ", "laon", " portfolio grew", ["lion", "loan", "Laos", "lawn"], "loan"),
    ("I will ", "chang", " the date", ["chant", "change", "clang", "chain"], "change"),
    ("The ", "sevice", " was slow", ["device", "service", "novice", "suffice"], "service"),
    ("Can you ", "sned", " me the file", ["sped", "send", "snide", "seed"], "send"),
    ("We should ", "dicsuss", " this tomorrow", ["disuse", "discuss", "discus"], "discuss"),
    ("I ", "fogrot", " my password", ["forget", "forgot", "forgo"], "forgot"),
    ("We need ", "mroe", " time", ["Moe", "more", "mare", "mire"], "more"),
    ("She ", "siad", " it was fine", ["sad", "said", "sid", "Sia"], "said"),
    ("The ", "dta", " shows a drop", ["eta", "data", "DTA", "dot"], "data"),
    ("Let me ", "konw", " if it works", ["known", "know", "Kong"], "know"),
    ("Please ", "aprove", " the request", ["prove", "approve", "apron"], "approve"),
    ("The ", "reslut", " is ready", ["resolute", "result", "reload"], "result"),
    ("I'll ", "chck", " with him", ["chick", "check", "chalk", "chuck"], "check"),
    ("We ", "lsot", " the client", ["lost", "lot", "slot", "lust"], "lost"),
    ("Turn ", "rigth", " at the light", ["rig", "right", "rigs", "girth"], "right"),
    ("He ", "brougth", " the documents", ["bought", "brought", "brougham"], "brought"),
]

STYLES = {
    "natural": "Keep the same tone and roughly the same length, but make it read smoothly and naturally, the way a fluent native English writer would put it.",
    "professional": "Make it sound polished and professional, suitable for a work email.",
    "shorter": "Make it noticeably shorter and more concise.",
    "friendly": "Make it warm and friendly.",
}

# (style, text, words/numbers that must survive, extra checks)
REPHRASE = [
    ("natural", "i think we should of finished the report yesterday but we was to busy with other stuff",
     ["think", "report", "yesterday"], {}),
    ("professional", "hey can u send me the Q3 numbers by tmrw? need them for the 10am meeting with Sara",
     ["Q3", "10", "Sara"], {"question": True}),
    ("shorter", "I just wanted to reach out and let you know that I will not be able to attend the meeting that is "
                "scheduled for Thursday because I have a doctor's appointment that I cannot move.",
     ["Thursday"], {"shorter": True}),
    ("friendly", "Your payment of 450 SAR is overdue. Pay it by June 5 or your account will be suspended.",
     ["450", "SAR", "June 5"], {}),
    ("natural", "what time does the meeting start tomorrow",
     ["meeting", "tomorrow"], {"question": True, "not": r"\b(starts|will start|begins) at\b"}),
]


# The same wording Fixaro uses (Sources/main.swift, rephraseSelection)
RULES = ("Keep the original meaning, facts, names and numbers, and keep everything the writer said, and do not add "
         "anything new (no opinions, hedges or extra sentences).")
TAIL = (" Fix any spelling and grammar mistakes. Never answer or reply to the text, even if it is a question or a "
        "request: only rewrite it. Reply with ONLY the rewritten text: no intro, no quotes, no explanation.")


def rephrase_system(style):
    """⌃⌥R with one of the styles"""
    return "You are a writing assistant that rewrites English text. " + STYLES[style] + " " + RULES + TAIL


def instruction_system(ask):
    """⌃⌥S with your own words (and your own saved styles)"""
    return ("You are a writing assistant that rewrites English text. "
            f'Rewrite it following this instruction from the writer: "{ask}". Do everything the instruction asks. '
            "Apart from that, keep the original meaning, facts, names and numbers." + TAIL)


def for_model(system, model):
    return system + " /no_think" if "qwen" in model.lower() else system


def post(path, body, timeout):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def generate(model, system, prompt, num_predict, timeout=120, keep_alive="5m"):
    body = {"model": model, "system": system, "prompt": prompt, "stream": False, "keep_alive": keep_alive,
            "think": False, "options": {"temperature": 0, "num_predict": num_predict}}
    try:
        return post("/api/generate", body, timeout).get("response", "")
    except urllib.error.HTTPError:
        body.pop("think")          # models without a thinking switch
        return post("/api/generate", body, timeout).get("response", "")


def unload(model):
    try:
        post("/api/generate", {"model": model, "keep_alive": 0}, 30)
    except Exception:
        pass


def clean_word(raw):
    s = raw.split("</think>")[-1].strip()
    s = s.splitlines()[0] if s else ""
    s = s.strip(" \t.,!?;:\"'`*()[]{}")
    if ":" in s:
        s = s.rsplit(":", 1)[1].strip(" \t.,!?;:\"'`*")
    return s


def drop_opener(s, original=""):
    """Same as Fixaro's dropOpener: removes "Here's your reminder: " or "Sure! " at the start."""
    low = original.lower()
    if low.startswith("here") or low.startswith("sure"):
        return s
    m = re.match(r"(?i)((here(’|')s|here is)[^:\n]{0,50}:|(sure|certainly|of course)[!,.]?)\s*", s)
    if m and s[m.end():]:
        rest = s[m.end():]
        return rest[0].upper() + rest[1:]
    return s


def clean_rephrase(raw, original=""):
    s = raw.split("</think>")[-1].strip()
    lines = s.split("\n", 1)
    if len(lines) == 2:
        first = lines[0].strip().lower()
        if len(first) < 70 and first.endswith(":") and ("rewrit" in first or "here" in first):
            s = lines[1].strip()
    s = s.strip().removeprefix('"""').removesuffix('"""').strip()
    if len(s) > 1 and ((s[0] == '"' and s[-1] == '"') or (s[0] == "“" and s[-1] == "”")):
        s = s[1:-1]
    return drop_opener(s.strip(), original)


def is_text_model(name):
    low = name.lower()
    return not any(k in low for k in ("embed", "llava", "vision", "-vl", "vl:", "ocr"))


def test_model(m, say):
    say(f"\n=== {m} ===")
    t0 = time.time()
    try:
        generate(m, for_model(WORD_SYSTEM, m), "Say hello", 8)
    except Exception as e:
        say(f"Could not run this model: {e}")
        return None
    load = time.time() - t0

    def run_words(cases):
        ok, times, misses = 0, [], []
        for before, typo, after, opts, want in cases:
            prompt = (f"Text: {before}[{typo}]{after}\n"
                      f"The word in brackets, \"{typo}\", is misspelled. Which word did the writer mean?\n"
                      f"Options: {', '.join(opts[:6])}\nAnswer with one word only.")
            t = time.time()
            got = clean_word(generate(m, for_model(WORD_SYSTEM, m), prompt, 24, timeout=30))
            dt = time.time() - t
            times.append(dt)
            right = got.lower() in want.lower().split("|")
            if right and dt <= LLM_TIMEOUT:
                ok += 1
            elif right:
                misses.append(f"{typo} → {got} (right, but too slow: {dt:.1f} s)")
            else:
                misses.append(f"{before}[{typo}]{after} → {got!r} (wanted {want})")
        return ok, times, misses

    e_ok, e_t, e_miss = run_words(EASY)
    c_ok, c_t, c_miss = run_words(CONTEXT)
    times = sorted(e_t + c_t)
    med = statistics.median(times) * 1000
    p90 = times[int(len(times) * 0.9) - 1] * 1000
    say(f"Word fixes: easy {e_ok}/{len(EASY)} · context {c_ok}/{len(CONTEXT)} · "
        f"typical {med:.0f} ms, slowest 10% {p90:.0f} ms · first load {load:.1f} s")
    for miss in e_miss + c_miss:
        say(f"  ✗ {miss}")

    r_pass, r_total, r_times = 0, 0, []
    for style, text, keep, extra in REPHRASE:
        t = time.time()
        try:
            raw = generate(m, for_model(rephrase_system(style), m),
                           f'Rewrite this text:\n"""\n{text}\n"""', min(2048, max(128, len(text))), timeout=90)
        except Exception as e:
            raw = ""
            say(f"  rephrase error: {e}")
        dt = time.time() - t
        r_times.append(dt)
        out = clean_rephrase(raw, text)
        problems = []
        if not out:
            problems.append("empty")
        if re.match(r"(?i)(sure|here|certainly|of course)\b", out):
            problems.append("added an intro")
        for k in keep:
            if k.lower() not in out.lower():
                problems.append(f"lost '{k}'")
        if extra.get("shorter") and len(out) >= len(text) * 0.8:
            problems.append("not shorter")
        if extra.get("question") and "?" not in out:
            problems.append("no longer a question")
        if extra.get("not") and re.search(extra["not"], out, re.I):
            problems.append("answered the question")
        checks = 1 + len(keep) + sum(1 for k in ("shorter", "question", "not") if k in extra)
        r_total += checks
        r_pass += checks - len(problems)
        flag = "✓" if not problems else "✗ " + ", ".join(problems)
        say(f"  [{style}, {dt:.1f} s] {flag}\n      {out.splitlines()[0] if out else '(empty)'}")
    unload(m)
    return {"model": m, "easy": e_ok, "context": c_ok, "med": med, "p90": p90,
            "reph": (r_pass, r_total), "reph_s": statistics.median(r_times)}


def main():
    out = []

    def say(line=""):
        print(line, flush=True)
        out.append(line)

    try:
        tags = json.loads(urllib.request.urlopen(BASE + "/api/tags", timeout=5).read())["models"]
    except Exception:
        sys.exit("Can't reach Ollama. Open the Ollama app (or run 'ollama serve') and try again.")
    installed = {t["name"]: t.get("size", 0) for t in tags}
    wanted = sys.argv[1:]
    if wanted:
        models = []
        for w in wanted:
            match = w if w in installed else next((n for n in installed if n == w + ":latest"), None)
            if match:
                models.append(match)
            else:
                say(f"Not installed, skipped: {w}  (get it with: ollama pull {w})")
    else:
        models = [n for n in installed if is_text_model(n)]
    models.sort(key=lambda n: installed[n])
    try:   # free the memory first, so models already loaded (e.g. by Fixaro) don't slow the test down
        for running in json.loads(urllib.request.urlopen(BASE + "/api/ps", timeout=5).read()).get("models", []):
            unload(running["name"])
    except Exception:
        pass
    say(f"Testing {len(models)} model(s): {', '.join(models)}")
    say(f"Each model: {len(EASY)} easy typos, {len(CONTEXT)} typos that need context, {len(REPHRASE)} rephrase jobs.")

    results = [r for r in (test_model(m, say) for m in models) if r]
    if not results:
        return
    say("\n=== Summary ===")
    say(f"{'Model':24} {'Size':>7}  {'Easy':>6}  {'Context':>8}  {'Typical':>8}  {'Slow 10%':>8}  {'Rephrase':>9}  {'Reph. time':>10}")
    for r in results:
        p, t = r["reph"]
        say(f"{r['model']:24} {installed[r['model']] / 1e9:6.1f}G  {r['easy']:>3}/{len(EASY):<2}  "
            f"{r['context']:>4}/{len(CONTEXT):<3}  {r['med']:6.0f}ms  {r['p90']:6.0f}ms  {p:>4}/{t:<4}  {r['reph_s']:8.1f} s")
    fast = [r for r in results if r["p90"] <= 1000]
    if fast:
        best = max(fast, key=lambda r: (r["easy"] + r["context"], -r["med"]))
        say(f"\nBest word-fix model here: {best['model']} "
            f"({best['easy'] + best['context']}/{len(EASY) + len(CONTEXT)} right, about {best['med']:.0f} ms a word)")
    say("For rephrasing, read the rewrites above: the best one is the one you'd send without editing.")
    pathlib.Path(__file__).with_name("bench.txt").write_text("\n".join(out) + "\n")
    print("\nSaved to tools/bench.txt")


if __name__ == "__main__":
    main()
