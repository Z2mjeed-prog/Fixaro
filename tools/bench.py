#!/usr/bin/env python3
"""Fixaro model test: runs real typos and a rephrase through each installed Ollama model,
using the same prompts Fixaro uses, and reports accuracy and speed.
Run from the repo folder:  python3 tools/bench.py      Results: tools/bench.txt"""
import json, time, urllib.request, urllib.error, re, pathlib

BASE = "http://127.0.0.1:11434"
CANDIDATES = ["qwen3.5:2b", "qwen3.5:4b", "gemma4:e2b", "gemma4:e4b", "gemma4:latest", "phi4-mini:latest", "llama3.2:3b"]
SYSTEM = ("You are a spelling corrector. The user typed a misspelled English word. Using the sentence for context, "
          "reply with ONLY the single correctly spelled word they meant. No explanation, no quotes, no punctuation.")

# (text before the word, typo, spell-checker style options, correct answer)
CASES = [
    ("I will ", "recieve", ["receive", "relieve", "reprieve"], "receive"),
    ("Can you send me the ", "reprot", ["report", "repot", "repost", "rep rot"], "report"),
    ("I spoke to ", "teh", ["the", "tech", "ten", "eh", "Te"], "the"),
    ("Please ", "chek", ["check", "cheek", "chef", "Czech"], "check"),
    ("I will see you ", "tomorow", ["tomorrow", "tomorrows"], "tomorrow"),
    ("The new ", "buisness", ["business", "businesses", "busyness"], "business"),
    ("It will ", "definately", ["definitely", "defiantly", "definitively"], "definitely"),
    ("Thank you for your ", "paitence", ["patience", "patients", "patent"], "patience"),
    ("I ", "beleive", ["believe", "belief", "relieve"], "believe"),
    ("The loan ", "aplication", ["application", "implication", "replication", "applicator"], "application"),
    ("Please review the credit ", "polciy", ["policy", "police", "polity"], "policy"),
    ("The customer did not ", "pya", ["pay", "pa", "ply", "pye", "spa"], "pay"),
    ("We need to ", "adress", ["address", "adores", "dress", "a dress"], "address"),
    ("I sent you an ", "emial", ["email", "emil", "enamel", "medial"], "email"),
    ("She is still in the ", "meting", ["meeting", "melting", "mating", "metering"], "meeting"),
    ("The project ", "comittee", ["committee", "commit tee", "committer"], "committee"),
    ("The team ", "perfromance", ["performance", "preformance", "per fromance"], "performance"),
    ("Can we ", "shedule", ["schedule", "she dule", "scheduled"], "schedule"),
]
REPHRASE = "i think we should of finished the report yesterday but we was to busy with other stuff"

def post(path, body, timeout=120):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def generate(model, system, prompt, num_predict=24):
    body = {"model": model, "system": system, "prompt": prompt, "stream": False, "keep_alive": "2m",
            "think": False, "options": {"temperature": 0, "num_predict": num_predict}}
    try:
        return post("/api/generate", body).get("response", "")
    except urllib.error.HTTPError:
        body.pop("think")
        return post("/api/generate", body).get("response", "")

def clean(raw):
    s = raw.split("</think>")[-1].strip()
    s = s.splitlines()[0] if s else ""
    s = s.strip(" \t.,!?;:\"'`*()[]{}")
    if ":" in s: s = s.rsplit(":", 1)[1].strip(" \t.,!?;:\"'`*")
    return s

def main():
    out = []
    def say(line=""):
        print(line); out.append(line)
    tags = [m["name"] for m in json.loads(urllib.request.urlopen(BASE + "/api/tags", timeout=5).read())["models"]]
    models = [m for m in CANDIDATES if m in tags]
    say(f"Installed text models tested: {', '.join(models)}")
    say(f"Not installed (skipped): {', '.join(m for m in CANDIDATES if m not in tags)}")
    summary = []
    for m in models:
        sysmsg = SYSTEM + (" /no_think" if "qwen" in m else "")
        say(f"\n=== {m} ===")
        t0 = time.time(); generate(m, sysmsg, "Say hello"); load = time.time() - t0
        ok, times, wrong = 0, [], []
        for before, typo, opts, want in CASES:
            prompt = (f"Text: {before}[{typo}]\nThe word in brackets, \"{typo}\", is misspelled. Which word did the writer mean?\n"
                      f"Options: {', '.join(opts[:6])}\nAnswer with one word only.")
            t = time.time(); raw = generate(m, sysmsg, prompt); times.append(time.time() - t)
            got = clean(raw)
            if got.lower() == want: ok += 1
            else: wrong.append(f"{typo} → {got!r} (wanted {want})")
        t = time.time()
        reph = generate(m, "You are a writing assistant that rewrites English text. Keep the same tone and roughly the same length. "
                           "Keep the original meaning, facts, names and numbers, and keep every part of the message. Fix any spelling "
                           "and grammar mistakes. Reply with ONLY the rewritten text." + (" /no_think" if "qwen" in m else ""),
                        f'Rewrite this text:\n"""\n{REPHRASE}\n"""', num_predict=200).strip()
        rt = time.time() - t
        times.sort()
        med = times[len(times) // 2] * 1000
        say(f"Word fixes: {ok}/{len(CASES)} correct · typical {med:.0f} ms per word · first load {load:.1f} s")
        for w in wrong: say(f"  ✗ {w}")
        say(f"Rephrase ({rt:.1f} s): {reph.splitlines()[0] if reph else '(empty)'}")
        summary.append((m, ok, med, rt))
    say("\n=== Summary ===")
    for m, ok, med, rt in summary:
        say(f"{m:18} {ok:2}/{len(CASES)} correct   {med:5.0f} ms/word   rephrase {rt:.1f} s")
    pathlib.Path(__file__).with_name("bench.txt").write_text("\n".join(out) + "\n")
    print("\nSaved to tools/bench.txt")

main()
