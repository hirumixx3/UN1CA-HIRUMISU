#!/usr/bin/env python3

from pathlib import Path
import os
import re
import sys

ADDED_FRAGMENTS = 9
GATEWAY_FIELD = (
    "Lcom/android/settings/core/gateway/SettingsGateway;"
    "->SAMSUNG_ENTRY_FRAGMENTS:[Ljava/lang/String;"
)


def abort(message):
    print("ERRO: " + message, file=sys.stderr)
    raise SystemExit(1)


def extract_method(text, signature):
    pattern = re.compile(
        r"(?ms)^\.method [^\n]*"
        + re.escape(signature)
        + r"\n.*?^\.end method$"
    )

    matches = list(pattern.finditer(text))

    if len(matches) != 1:
        abort(
            f'esperado exatamente um método "{signature}"; '
            f"encontrados: {len(matches)}"
        )

    return matches[0]


if len(sys.argv) != 3:
    abort(
        "uso: apply_settings_activity_fragment_count.py "
        "<SettingsGateway.smali> <SettingsActivity.smali>"
    )

gateway_path = Path(sys.argv[1])
activity_path = Path(sys.argv[2])

if not gateway_path.is_file():
    abort(f"SettingsGateway não encontrado: {gateway_path}")

if not activity_path.is_file():
    abort(f"SettingsActivity não encontrado: {activity_path}")

gateway_text = gateway_path.read_text(
    encoding="utf-8",
    errors="strict",
)

gateway_method_match = extract_method(
    gateway_text,
    "<clinit>()V",
)

gateway_method = gateway_method_match.group(0)

array_pattern = re.compile(
    r"(?m)^[ \t]*filled-new-array/range "
    r"\{v(\d+) \.\. v(\d+)\}, "
    r"\[Ljava/lang/String;$"
)

arrays = []

for match in array_pattern.finditer(gateway_method):
    context = gateway_method[match.end():match.end() + 400]

    if GATEWAY_FIELD in context:
        arrays.append(match)

if len(arrays) != 1:
    abort(
        "esperado exatamente um array para "
        "SAMSUNG_ENTRY_FRAGMENTS; "
        f"encontrados: {len(arrays)}"
    )

range_start = int(arrays[0].group(1))
new_limit = int(arrays[0].group(2))
old_limit = new_limit - ADDED_FRAGMENTS

if range_start != 1:
    abort(
        f"início inesperado do array: v{range_start}"
    )

activity_text = activity_path.read_text(
    encoding="utf-8",
    errors="strict",
)

activity_method_match = extract_method(
    activity_text,
    "isValidFragment(Ljava/lang/String;)Z",
)

method = activity_method_match.group(0)

const_pattern = re.compile(
    r"(?m)^([ \t]*const(?:/4|/16)?[ \t]+v\d+,[ \t]+)"
    r"(-?0x[0-9a-fA-F]+|-?\d+)$"
)

old_matches = []
new_matches = []

for match in const_pattern.finditer(method):
    literal = match.group(2)
    value = int(literal, 0)

    if value == old_limit:
        old_matches.append(match)

    if value == new_limit:
        new_matches.append(match)

if len(old_matches) == 0 and len(new_matches) == 1:
    print(
        "SettingsActivity já usa o limite correto: "
        f"{new_limit} (0x{new_limit:x})"
    )
    raise SystemExit(0)

if len(old_matches) != 1 or len(new_matches) != 0:
    print(
        "Estrutura de isValidFragment() não reconhecida.",
        file=sys.stderr,
    )
    print(
        f"Limite antigo esperado: {old_limit} "
        f"(0x{old_limit:x})",
        file=sys.stderr,
    )
    print(
        f"Limite novo esperado: {new_limit} "
        f"(0x{new_limit:x})",
        file=sys.stderr,
    )
    print(method, file=sys.stderr)

    abort(
        f"ocorrências antigas={len(old_matches)}, "
        f"novas={len(new_matches)}"
    )

old_match = old_matches[0]

patched_method = (
    method[:old_match.start(2)]
    + f"0x{new_limit:x}"
    + method[old_match.end(2):]
)

remaining_old = [
    match
    for match in const_pattern.finditer(patched_method)
    if int(match.group(2), 0) == old_limit
]

final_new = [
    match
    for match in const_pattern.finditer(patched_method)
    if int(match.group(2), 0) == new_limit
]

if remaining_old or len(final_new) != 1:
    abort("validação final do limite falhou")

result = (
    activity_text[:activity_method_match.start()]
    + patched_method
    + activity_text[activity_method_match.end():]
)

tmp = activity_path.with_name(
    activity_path.name + ".tmp"
)

tmp.write_text(result, encoding="utf-8")
os.replace(tmp, activity_path)

register = old_match.group(1).split(",")[0].split()[-1]

print(
    "SettingsActivity fragment bound adaptado: "
    f"{register} 0x{old_limit:x} ({old_limit}) -> "
    f"0x{new_limit:x} ({new_limit})"
)
