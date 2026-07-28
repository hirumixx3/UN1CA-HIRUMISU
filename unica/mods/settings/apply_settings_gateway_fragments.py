#!/usr/bin/env python3
from pathlib import Path
import os
import re
import sys

FRAGMENTS = [
    "io.mesalabs.unica.settings.UnicaSettingsFragment",
    "io.mesalabs.unica.settings.extra.ExtraSettingsFragment",
    "io.mesalabs.unica.settings.hma.HideMyApplistFragment",
    "io.mesalabs.unica.settings.spoof.HideDeveloperStatusFragment",
    "io.mesalabs.unica.settings.spoof.SpoofSettingsFragment",
    "io.mesalabs.unica.settings.ui.UISettingsFragment",
    "io.mesalabs.unica.settings.spoof.CameraFeatureFragment",
    "io.mesalabs.unica.settings.extra.ScpmAllowlistFragment",
    "com.samsung.android.settings.bpd.PdCustomAppsSettings",
]

def abort(message):
    raise SystemExit("ERRO: " + message)

if len(sys.argv) != 2:
    abort("informe SettingsGateway.smali")

path = Path(sys.argv[1])
if not path.is_file():
    abort(f"arquivo não encontrado: {path}")

text = path.read_text(encoding="utf-8")

method_match = re.search(
    r"(?ms)^\.method [^\n]*<clinit>\(\)V\n.*?^\.end method$",
    text,
)
if not method_match:
    abort("<clinit>()V não encontrado")

method = method_match.group(0)

array_pattern = re.compile(
    r"(?m)^([ \t]*)filled-new-array/range "
    r"\{v(\d+) \.\. v(\d+)\}, "
    r"\[Ljava/lang/String;$"
)

candidates = []
for match in array_pattern.finditer(method):
    context = method[match.end():match.end() + 400]
    if (
        "->SAMSUNG_ENTRY_FRAGMENTS:[Ljava/lang/String;"
        in context
    ):
        candidates.append(match)

if len(candidates) != 1:
    abort(
        "esperado um array SAMSUNG_ENTRY_FRAGMENTS; "
        f"encontrados: {len(candidates)}"
    )

array_match = candidates[0]
indent = array_match.group(1)
range_start = int(array_match.group(2))
range_end = int(array_match.group(3))

counts = {
    fragment: method.count(f'"{fragment}"')
    for fragment in FRAGMENTS
}

present = [name for name, count in counts.items() if count]

if present:
    invalid = {
        name: count
        for name, count in counts.items()
        if count != 1
    }

    if invalid:
        abort(
            "aplicação parcial ou duplicada: "
            + repr(invalid)
        )

    print(
        "SettingsGateway já contém os nove fragmentos; "
        f"array atual v{range_start}..v{range_end}"
    )
    raise SystemExit(0)

new_first = range_end + 1
new_end = range_end + len(FRAGMENTS)

insertions = ""
for register, fragment in enumerate(
    FRAGMENTS,
    start=new_first,
):
    insertions += (
        f'{indent}const-string v{register}, '
        f'"{fragment}"\n\n'
    )

new_array = (
    f"{indent}filled-new-array/range "
    f"{{v{range_start} .. v{new_end}}}, "
    f"[Ljava/lang/String;"
)

patched_method = (
    method[:array_match.start()]
    + insertions
    + new_array
    + method[array_match.end():]
)

directive = re.search(
    r"(?m)^([ \t]*)\.(registers|locals)\s+(\d+)$",
    patched_method,
)

if not directive:
    abort(".registers/.locals não encontrado")

capacity = int(directive.group(3))
required = new_end + 1

if capacity < required:
    replacement = (
        f"{directive.group(1)}."
        f"{directive.group(2)} {required}"
    )
    patched_method = (
        patched_method[:directive.start()]
        + replacement
        + patched_method[directive.end():]
    )

for fragment in FRAGMENTS:
    if patched_method.count(f'"{fragment}"') != 1:
        abort(f"validação falhou para {fragment}")

expected_array = (
    f"filled-new-array/range "
    f"{{v{range_start} .. v{new_end}}}, "
    f"[Ljava/lang/String;"
)

if expected_array not in patched_method:
    abort("limite final do array não foi atualizado")

result = (
    text[:method_match.start()]
    + patched_method
    + text[method_match.end():]
)

tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(result, encoding="utf-8")
os.replace(tmp, path)

print(
    "SettingsGateway adaptado: nove fragmentos em "
    f"v{new_first}..v{new_end}; "
    f"array ampliado de v{range_end} para v{new_end}"
)
