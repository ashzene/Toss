#!/usr/bin/env python3
"""Every language file has every string the app shows, with the same placeholders and line count."""
import importlib.util, json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("extract", root / "scripts/extract-strings.py")
extract = importlib.util.module_from_spec(spec); spec.loader.exec_module(extract)
keys = dict(extract.extract(root)[0])
folder = root / "Assets/Localization"
extras = folder / "extra-keys.json"
if extras.exists():
    keys.update({k: {} for k in json.loads(extras.read_text(encoding="utf8"))})
codes = ["az", "es", "fr", "gl", "hi", "ja", "ko", "pt-BR", "tr"]
KEEP = ["Toss", "iPad", "iPhone", "ChatGPT", "Codex", "Claude", "USB", "Wi-Fi", "macOS"]
problems = 0
def report(code, key, why):
    global problems
    problems += 1
    print(f"{code}: {why}: {key!r}"[:200])
for code in codes:
    path = folder / f"{code}.json"
    if not path.exists():
        report(code, "", "file missing"); continue
    table = json.loads(path.read_text(encoding="utf8"))
    for key in keys:
        text = table.get(key)
        if not isinstance(text, str) or not text.strip():
            report(code, key, "missing"); continue
        if sorted(re.findall(r"\{\d+\}", key)) != sorted(re.findall(r"\{\d+\}", text)):
            report(code, key, "placeholders differ")
        if key.count("\n") != text.count("\n"):
            report(code, key, "line count differs")
        for word in KEEP:
            if word in key and word not in text:
                report(code, key, f"lost {word}")
        if re.search(r"[()（）]", text) and not re.search(r"[()（）]", key):
            report(code, key, "added parentheses")
print(f"Localization: {len(keys)} strings, {len(codes)} languages, {problems} problems.")
sys.exit(1 if problems else 0)
