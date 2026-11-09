#!/usr/bin/env python3
"""List every English string the app shows: L("en", "zh"), Onboarding's t("zh", "en") and
Translations.text("en"). Interpolations become {0}, {1}, ... in the English key."""
import json, re, sys
from pathlib import Path

def read_literal(src, i):
    """src[i] is the opening quote. Returns (template, next_index)."""
    if src[i:i+3] == '"""':
        raise ValueError("multi-line literal")
    assert src[i] == '"'
    out, n, i = [], 0, i + 1
    while src[i] != '"':
        c = src[i]
        if c == "\\":
            e = src[i+1]
            if e == "(":
                depth, j = 1, i + 2
                while depth:
                    if src[j] == '"':            # a nested literal inside \( ... )
                        _, j = read_literal(src, j)
                        continue
                    depth += {"(": 1, ")": -1}.get(src[j], 0)
                    j += 1
                out.append("{%d}" % n); n += 1; i = j
                continue
            if e == "u":
                end = src.index("}", i)
                out.append(chr(int(src[i+3:end], 16))); i = end + 1
                continue
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "0": "\0"}[e]); i += 2
            continue
        out.append(c); i += 1
    return "".join(out), i + 1

def skip_space(src, i):
    while src[i] in " \t\r\n": i += 1
    return i

def extract(root):
    found, skipped = {}, []
    for path in sorted((Path(root) / "Sources").glob("*.swift")):
        src = path.read_text(encoding="utf8")
        for m in re.finditer(r'(?<![\w.])(L|t)\(\s*(?=")|Translations\.text\(\s*(?=")', src):
            line = src.count("\n", 0, m.start()) + 1
            kind = m.group(1) or "text"
            try:
                first, i = read_literal(src, m.end())
                if kind == "text":
                    en, zh = first, None
                else:
                    i = skip_space(src, i)
                    if src[i] != ",": raise ValueError("no second argument")
                    i = skip_space(src, i + 1)
                    if src[i] != '"': raise ValueError("second argument is not a literal")
                    second, _ = read_literal(src, i)
                    en, zh = (first, second) if kind == "L" else (second, first)
            except (ValueError, IndexError, KeyError) as error:
                skipped.append(f"{path.name}:{line} {error}")
                continue
            entry = found.setdefault(en, {"zh": zh, "where": []})
            if entry["zh"] is None: entry["zh"] = zh
            entry["where"].append(f"{path.name}:{line}")
    return found, skipped

if __name__ == "__main__":
    merged, all_skipped = {}, []
    for root in sys.argv[2:]:
        found, skipped = extract(root)
        all_skipped += skipped
        for en, entry in found.items():
            target = merged.setdefault(en, {"zh": entry["zh"], "where": []})
            target["where"] += entry["where"]
            if target["zh"] is None: target["zh"] = entry["zh"]
    Path(sys.argv[1]).write_text(json.dumps(merged, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf8")
    print("strings", len(merged), "words", sum(len(k.split()) for k in merged), "skipped", len(all_skipped))
    for line in all_skipped[:20]: print(" ", line)
