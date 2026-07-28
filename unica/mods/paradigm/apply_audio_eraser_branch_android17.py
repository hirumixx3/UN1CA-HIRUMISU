#!/usr/bin/env python3

from pathlib import Path
import re
import sys
import hashlib

CHECK = ":cond_unica_local_audio_eraser_check"
ALLOW = ":cond_unica_local_audio_eraser_allow"
KEY = "unica_scpm_allowlist_packages"

NAME = (
    "AudioEraserAudioPlaybackStartable$audioPlaybackCallback$1"
    "$onPlaybackConfigChanged$1.smali"
)

if len(sys.argv) != 2:
    raise SystemExit("Uso: helper <diretório SystemUI.apk>")

apk = Path(sys.argv[1])

matches = list(apk.rglob(NAME))

if len(matches) != 1:
    raise SystemExit(
        f"ERRO: smali encontrado {len(matches)} vez(es)"
    )

path = matches[0]
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)

check_indexes = [
    i for i, line in enumerate(lines)
    if line.strip() == CHECK
]

if len(check_indexes) != 1:
    raise SystemExit(
        f"ERRO: label check encontrado {len(check_indexes)} vez(es)"
    )

check = check_indexes[0]

method_start = next(
    (
        i for i in range(check, -1, -1)
        if lines[i].startswith(".method ")
    ),
    None,
)

method_end = next(
    (
        i for i in range(check, len(lines))
        if lines[i].startswith(".end method")
    ),
    None,
)

if method_start is None or method_end is None:
    raise SystemExit("ERRO: limites do método não encontrados")

method = "".join(lines[method_start:method_end + 1])

if KEY not in method:
    raise SystemExit("ERRO: chave local não encontrada no método")

branch_to_check = re.compile(
    r"^\s*if-eqz\s+[vp]\d+,\s*"
    + re.escape(CHECK)
    + r"\s*$"
)

allow_exists = any(
    line.strip() == ALLOW
    for line in lines[method_start:method_end + 1]
)

check_branch_exists = any(
    branch_to_check.match(line.rstrip("\n"))
    for line in lines[method_start:method_end + 1]
)

if allow_exists and check_branch_exists:
    print("Audio Eraser branch já estava corrigido.")
    print(f"SHA-256: {hashlib.sha256(path.read_bytes()).hexdigest()}")
    raise SystemExit(0)

fallback = None

for line in lines[check + 1:method_end + 1]:
    match = re.match(
        r"^\s*if-eqz\s+[vp]\d+,\s*"
        r"(?P<label>:cond_[A-Za-z0-9_$]+)\s*$",
        line.rstrip("\n"),
    )

    if match:
        fallback = match.group("label")
        break

if fallback is None:
    raise SystemExit(
        "ERRO: fallback stock não encontrado dentro do bloco local"
    )

candidates = []

pattern = re.compile(
    r"^(?P<indent>\s*)if-eqz\s+"
    r"(?P<register>[vp]\d+),\s*"
    + re.escape(fallback)
    + r"\s*$"
)

for i in range(method_start, check):
    match = pattern.match(lines[i].rstrip("\n"))

    if not match:
        continue

    window = "".join(lines[i + 1:min(i + 15, check)])

    if "->activePlaybacks:Ljava/util/Map;" in window:
        candidates.append((i, match))

if len(candidates) != 1:
    raise SystemExit(
        "ERRO: branch do activePlaybacks encontrado "
        f"{len(candidates)} vez(es)"
    )

branch_index, match = candidates[0]
indent = match.group("indent")
register = match.group("register")

lines[branch_index] = (
    f"{indent}if-eqz {register}, {CHECK}\n"
)

if not allow_exists:
    lines.insert(
        branch_index + 1,
        f"{indent}{ALLOW}\n",
    )

result = "".join(lines)

if result.count(CHECK) < 2:
    raise SystemExit("ERRO: branch para o check não foi criado")

if result.count(ALLOW) < 2:
    raise SystemExit("ERRO: label allow não foi criado")

if KEY not in result:
    raise SystemExit("ERRO: chave local desapareceu")

path.write_text(result, encoding="utf-8")

print("Audio Eraser Android 17 corrigido.")
print(f"Fallback stock: {fallback}")
print(f"Branch: if-eqz {register}, {CHECK}")
print(f"SHA-256: {hashlib.sha256(path.read_bytes()).hexdigest()}")
