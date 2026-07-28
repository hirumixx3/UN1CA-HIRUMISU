#!/usr/bin/env python3

from pathlib import Path
import os
import re
import sys


def abort(message):
    print("ERRO: " + message, file=sys.stderr)
    raise SystemExit(1)


if len(sys.argv) != 2:
    abort("uso: apply_top_level_unica.py <TopLevelKeysCollector.smali>")

path = Path(sys.argv[1])

if not path.is_file():
    abort(f"arquivo não encontrado: {path}")

text = path.read_text(encoding="utf-8")

method_matches = list(re.finditer(
    r"(?ms)^\.method [^\n]*<init>\(Landroid/content/Context;\)V\n"
    r".*?"
    r"^\.end method$",
    text,
))

if len(method_matches) != 1:
    abort(
        "esperado exatamente um construtor <init>(Context); "
        f"encontrados: {len(method_matches)}"
    )

method_match = method_matches[0]
method = method_match.group(0)

locals_matches = list(re.finditer(
    r"(?m)^([ \t]*)\.locals[ \t]+(\d+)$",
    method,
))

if len(locals_matches) != 1:
    abort(
        "esperado exatamente um .locals; "
        f"encontrados: {len(locals_matches)}"
    )

locals_match = locals_matches[0]
locals_count = int(locals_match.group(2))

array_pattern = re.compile(
    r"(?m)^([ \t]*)filled-new-array/range "
    r"\{v(\d+) \.\. v(\d+)\}, "
    r"\[Ljava/lang/String;$"
)

const_pattern = re.compile(
    r'(?m)^[ \t]*const-string(?:/jumbo)? '
    r'v(\d+), "([^"]+)"$'
)

candidates = []

for array_match in array_pattern.finditer(method):
    first_register = int(array_match.group(2))
    last_register = int(array_match.group(3))

    assignments = {}

    for const_match in const_pattern.finditer(
        method,
        0,
        array_match.start(),
    ):
        register = int(const_match.group(1))
        assignments[register] = const_match.group(2)

    top_level_count = sum(
        1
        for register in range(first_register, last_register + 1)
        if assignments.get(register, "").startswith("top_level_")
    )

    if top_level_count:
        candidates.append((
            top_level_count,
            array_match,
            assignments,
        ))

if not candidates:
    abort("nenhum array com chaves top_level_* foi encontrado")

best_score = max(item[0] for item in candidates)
best_candidates = [
    item for item in candidates
    if item[0] == best_score
]

if len(best_candidates) != 1:
    abort(
        "não foi possível identificar de forma única o array "
        f"de top-level keys; candidatos: {len(best_candidates)}"
    )

_, array_match, assignments = best_candidates[0]

first_register = int(array_match.group(2))
last_register = int(array_match.group(3))

existing_registers = [
    register
    for register, value in assignments.items()
    if value == "top_level_unica"
]

if existing_registers:
    if len(existing_registers) != 1:
        abort(
            "top_level_unica está duplicado nos registradores: "
            + repr(existing_registers)
        )

    register = existing_registers[0]

    if not first_register <= register <= last_register:
        abort(
            f"top_level_unica está em v{register}, fora do array "
            f"v{first_register}..v{last_register}"
        )

    print(
        "TopLevelKeysCollector já contém top_level_unica "
        f"em v{register}"
    )
    raise SystemExit(0)

# O patch original usa o próximo local e amplia o array em uma posição.
if last_register != locals_count - 1:
    abort(
        "estrutura inesperada: "
        f".locals {locals_count}, mas o array termina em v{last_register}. "
        "Esperado que terminasse em "
        f"v{locals_count - 1}"
    )

new_register = locals_count
new_locals = locals_count + 1
indent = array_match.group(1)

insertion = (
    f'{indent}const-string v{new_register}, "top_level_unica"\n\n'
)

new_array = (
    f"{indent}filled-new-array/range "
    f"{{v{first_register} .. v{new_register}}}, "
    f"[Ljava/lang/String;"
)

patched_method = (
    method[:array_match.start()]
    + insertion
    + new_array
    + method[array_match.end():]
)

patched_method = re.sub(
    r"(?m)^([ \t]*)\.locals[ \t]+\d+$",
    rf"\1.locals {new_locals}",
    patched_method,
    count=1,
)

if patched_method.count('"top_level_unica"') != 1:
    abort("validação de top_level_unica falhou")

expected_array = (
    f"filled-new-array/range "
    f"{{v{first_register} .. v{new_register}}}, "
    f"[Ljava/lang/String;"
)

if expected_array not in patched_method:
    abort("validação do novo limite do array falhou")

result = (
    text[:method_match.start()]
    + patched_method
    + text[method_match.end():]
)

tmp = path.with_name(path.name + ".tmp")
tmp.write_text(result, encoding="utf-8")
os.replace(tmp, path)

print(
    "TopLevelKeysCollector adaptado: "
    f".locals {locals_count} -> {new_locals}; "
    f"top_level_unica em v{new_register}; "
    f"array v{first_register}..v{last_register} -> "
    f"v{first_register}..v{new_register}"
)
