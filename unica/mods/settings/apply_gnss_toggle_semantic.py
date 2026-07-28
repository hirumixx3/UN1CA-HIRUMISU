#!/usr/bin/env python3
from pathlib import Path
import os
import re
import sys

def abort(message):
    raise SystemExit("ERRO: " + message)

if len(sys.argv) != 2:
    abort("informe o diretório decompilado de services.jar")

root = Path(sys.argv[1])

if not root.is_dir():
    abort(f"diretório não encontrado: {root}")

method_re = re.compile(
    r"(?ms)^\.method [^\n]*\(\)V\n.*?^\.end method$"
)

location_re = re.compile(
    r"(?m)^(?P<i>[ \t]*)iget-object "
    r"(?P<dst>[vp]\d+), (?P<src>[vp]\d+), "
    r"L(?P<class>com/android/server/location/gnss/"
    r"GnssLocationProvider\$\$ExternalSyntheticLambda[^;]*);"
    r"->f\$\d+:Landroid/location/Location;$"
)

anchor = (
    "Lcom/android/server/location/gnss/GnssLocationProvider;"
    "->PROPERTIES:Landroid/location/provider/ProviderProperties;"
)

candidates = []

for path in sorted(
    root.glob(
        "smali*/com/android/server/location/gnss/"
        "GnssLocationProvider$$ExternalSyntheticLambda*.smali"
    )
):
    text = path.read_text(encoding="utf-8")

    for method_match in method_re.finditer(text):
        method = method_match.group(0)
        location_match = location_re.search(method)

        if not location_match:
            continue

        if anchor not in method:
            continue

        if '"GnssLocationProvider"' not in method:
            continue

        class_name = re.escape(location_match.group("class"))

        provider_re = re.compile(
            r"(?m)^[ \t]*iget-object (?P<dst>[vp]\d+), "
            r"[vp]\d+, L"
            + class_name
            + r";->f\$\d+:Lcom/android/server/location/gnss/"
            r"GnssLocationProvider;$"
        )

        providers = list(
            provider_re.finditer(
                method[:location_match.start()]
            )
        )

        if not providers:
            continue

        candidates.append(
            (
                path,
                text,
                method_match,
                method,
                location_match,
                providers[-1].group("dst"),
            )
        )

if len(candidates) != 1:
    print(
        f"Candidatos encontrados: {len(candidates)}",
        file=sys.stderr,
    )

    for candidate in candidates:
        print(candidate[0], file=sys.stderr)

    abort("lambda GNSS não identificada de forma única")

path, text, method_match, method, location_match, provider_reg = (
    candidates[0]
)

if "unica_mock_location" in method:
    required = [
        "Settings$System;->getInt",
        ":cond_unica_gnss_allowed",
        "return-void",
    ]

    for item in required:
        if item not in method:
            abort(f"aplicação parcial; ausente: {item}")

    print(
        "GNSS toggle já aplicado em "
        + str(path.relative_to(root))
    )
    raise SystemExit(0)

directive = re.search(
    r"(?m)^(?P<i>[ \t]*)\."
    r"(?P<kind>locals|registers)[ \t]+"
    r"(?P<count>\d+)$",
    method,
)

if not directive:
    abort(".locals/.registers não encontrado")

kind = directive.group("kind")
count = int(directive.group("count"))

if kind == "locals":
    local_count = count
else:
    # run()V de instância possui somente p0.
    local_count = count - 1

    explicit_registers = [
        int(value)
        for value in re.findall(r"\bv(\d+)\b", method)
    ]

    if any(value >= local_count for value in explicit_registers):
        abort(
            ".registers referencia parâmetros como vN; "
            "adaptação automática insegura"
        )

new_count = count + 3

temp0 = f"v{local_count}"
temp1 = f"v{local_count + 1}"
temp2 = f"v{local_count + 2}"
indent = location_match.group("i")

block = (
    f"\n{indent}iget-object {temp0}, {provider_reg}, "
    "Lcom/android/server/location/gnss/GnssLocationProvider;"
    "->mContext:Landroid/content/Context;\n\n"
    f"{indent}invoke-virtual {{{temp0}}}, "
    "Landroid/content/Context;->getContentResolver()"
    "Landroid/content/ContentResolver;\n\n"
    f"{indent}move-result-object {temp0}\n\n"
    f'{indent}const-string {temp1}, "unica_mock_location"\n\n'
    f"{indent}const/4 {temp2}, 0x0\n\n"
    f"{indent}invoke-static "
    f"{{{temp0}, {temp1}, {temp2}}}, "
    "Landroid/provider/Settings$System;->getInt"
    "(Landroid/content/ContentResolver;"
    "Ljava/lang/String;I)I\n\n"
    f"{indent}move-result {temp0}\n\n"
    f"{indent}if-eqz {temp0}, :cond_unica_gnss_allowed\n\n"
    f"{indent}return-void\n\n"
    f"{indent}:cond_unica_gnss_allowed\n"
)

insert_at = location_match.end()

patched_method = (
    method[:insert_at]
    + block
    + method[insert_at:]
)

patched_method = (
    patched_method[:directive.start("count")]
    + str(new_count)
    + patched_method[directive.end("count"):]
)

if patched_method.count('"unica_mock_location"') != 1:
    abort("toggle GNSS duplicado")

if patched_method.count(":cond_unica_gnss_allowed") != 2:
    abort("label GNSS incompleto ou duplicado")

result = (
    text[:method_match.start()]
    + patched_method
    + text[method_match.end():]
)

tmp = path.with_name(path.name + ".tmp")
tmp.write_text(result, encoding="utf-8")
os.replace(tmp, path)

print(
    "GNSS toggle aplicado em "
    + str(path.relative_to(root))
    + f"; .{kind} {count} -> {new_count}; "
    + f"temporários {temp0}, {temp1}, {temp2}"
)
