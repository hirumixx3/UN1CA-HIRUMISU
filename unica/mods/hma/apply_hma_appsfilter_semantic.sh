#!/usr/bin/env bash

set -euo pipefail

: "${APKTOOL_DIR:?ERRO: APKTOOL_DIR não definido}"

SERVICES_DIR="$APKTOOL_DIR/system/framework/services.jar"
AUDIT_ROOT="${WORK_DIR:-${APKTOOL_DIR%/apktool}}"
AUDIT_FILE="$AUDIT_ROOT/hma-appsfilter-semantic-audit.json"

if [ ! -d "$SERVICES_DIR" ]; then
    echo "ERRO: services.jar decompilado não encontrado:"
    echo "$SERVICES_DIR"
    exit 1
fi

mkdir -p "$AUDIT_ROOT"

python3 - \
    "$SERVICES_DIR" \
    "$AUDIT_FILE" <<'PY'
from pathlib import Path
import hashlib
import json
import re
import sys

root = Path(sys.argv[1])
audit_file = Path(sys.argv[2])

apps_filter_relative = (
    "com/android/server/pm/AppsFilterBase.smali"
)

computer_relative = (
    "com/android/server/pm/ComputerEngine.smali"
)

apps_matches = sorted(
    root.glob(f"smali*/{apps_filter_relative}")
)

computer_matches = sorted(
    root.glob(f"smali*/{computer_relative}")
)

if len(apps_matches) != 1:
    raise SystemExit(
        "ERRO: esperava exatamente um AppsFilterBase.smali; "
        f"encontrei {len(apps_matches)}:\n"
        + "\n".join(map(str, apps_matches))
    )

if len(computer_matches) != 1:
    raise SystemExit(
        "ERRO: esperava exatamente um ComputerEngine.smali; "
        f"encontrei {len(computer_matches)}:\n"
        + "\n".join(map(str, computer_matches))
    )

apps_path = apps_matches[0]
computer_path = computer_matches[0]

METHOD_RE = re.compile(
    r"(?ms)^\.method[^\n]*\n.*?^\.end method[ \t]*(?:\n|$)"
)


def parse_methods(text: str):
    methods = []

    for match in METHOD_RE.finditer(text):
        body = match.group(0)
        declaration = body.splitlines()[0]

        signature = re.search(
            r"([^\s(]+)\(([^)]*)\)(\S+)$",
            declaration,
        )

        if not signature:
            continue

        methods.append(
            {
                "start": match.start(),
                "end": match.end(),
                "declaration": declaration,
                "name": signature.group(1),
                "parameters": signature.group(2),
                "return_type": signature.group(3),
                "text": body,
            }
        )

    return methods


bridge_name = "shouldFilterApplicationCustom"
bridge_parameters = (
    "Lcom/android/server/pm/snapshot/PackageDataSnapshot;"
    "I"
    "Lcom/android/server/pm/pkg/PackageStateInternal;"
    "I"
)
bridge_return = "Z"

main_name = "shouldFilterApplication"
main_parameters = (
    "Lcom/android/server/pm/snapshot/PackageDataSnapshot;"
    "I"
    "Ljava/lang/Object;"
    "Lcom/android/server/pm/pkg/PackageStateInternal;"
    "I"
)
main_return = "Z"

computer_parameters = (
    "Lcom/android/server/pm/pkg/PackageStateInternal;"
    "II"
)

bridge_method = """.method public static shouldFilterApplicationCustom(Lcom/android/server/pm/snapshot/PackageDataSnapshot;ILcom/android/server/pm/pkg/PackageStateInternal;I)Z
    .locals 2

    const/4 v0, 0x0

    instance-of v1, p0, Lcom/android/server/pm/ComputerEngine;

    if-eqz v1, :cond_0

    check-cast p0, Lcom/android/server/pm/ComputerEngine;

    invoke-virtual {p0, p2, p1, p3}, Lcom/android/server/pm/ComputerEngine;->shouldFilterApplicationCustom(Lcom/android/server/pm/pkg/PackageStateInternal;II)Z

    move-result p0

    return p0

    :cond_0
    return v0
.end method

"""

hook = """\
    invoke-static {p1, p2, p4, p5}, Lcom/android/server/pm/AppsFilterBase;->shouldFilterApplicationCustom(Lcom/android/server/pm/snapshot/PackageDataSnapshot;ILcom/android/server/pm/pkg/PackageStateInternal;I)Z

    move-result v0

    if-eqz v0, :cond_hma_apps_filter_continue

    const/4 v0, 0x1

    return v0

    :cond_hma_apps_filter_continue

"""

text = apps_path.read_text(encoding="utf-8")
methods = parse_methods(text)


def select_method(
    methods,
    name,
    parameters,
    return_type,
):
    return [
        method
        for method in methods
        if method["name"] == name
        and method["parameters"] == parameters
        and method["return_type"] == return_type
    ]


bridge_matches = select_method(
    methods,
    bridge_name,
    bridge_parameters,
    bridge_return,
)

main_matches = select_method(
    methods,
    main_name,
    main_parameters,
    main_return,
)

if len(main_matches) != 1:
    raise SystemExit(
        "ERRO: esperava um método principal "
        f"{main_name}({main_parameters}){main_return}; "
        f"encontrei {len(main_matches)}"
    )

bridge_inserted = False
hook_inserted = False

if len(bridge_matches) == 0:
    main = main_matches[0]

    text = (
        text[:int(main["start"])]
        + bridge_method
        + text[int(main["start"]):]
    )

    bridge_inserted = True

elif len(bridge_matches) != 1:
    raise SystemExit(
        "ERRO: ponte HMA duplicada em AppsFilterBase"
    )

# Reanalisa após eventual inserção da ponte.
methods = parse_methods(text)

main_matches = select_method(
    methods,
    main_name,
    main_parameters,
    main_return,
)

if len(main_matches) != 1:
    raise SystemExit(
        "ERRO: método shouldFilterApplication desapareceu"
    )

main = main_matches[0]
main_body = str(main["text"])

hook_call = (
    "Lcom/android/server/pm/AppsFilterBase;"
    "->shouldFilterApplicationCustom("
    "Lcom/android/server/pm/snapshot/PackageDataSnapshot;"
    "ILcom/android/server/pm/pkg/PackageStateInternal;I)Z"
)

has_call = hook_call in main_body
has_label = ":cond_hma_apps_filter_continue" in main_body

if has_call != has_label:
    raise SystemExit(
        "ERRO: hook HMA parcialmente aplicado em "
        "AppsFilterBase.shouldFilterApplication"
    )

if not has_call:
    body_lines = main_body.splitlines(keepends=True)

    register_index = None

    for index, line in enumerate(body_lines[1:], start=1):
        stripped = line.strip()

        if (
            stripped.startswith(".locals ")
            or stripped.startswith(".registers ")
        ):
            register_index = index
            break

    if register_index is None:
        raise SystemExit(
            "ERRO: shouldFilterApplication sem "
            ".locals/.registers"
        )

    insertion_index = register_index + 1

    body_lines[
        insertion_index:insertion_index
    ] = [
        "\n",
        hook,
    ]

    new_main_body = "".join(body_lines)

    text = (
        text[:int(main["start"])]
        + new_main_body
        + text[int(main["end"]):]
    )

    hook_inserted = True

apps_path.write_text(text, encoding="utf-8")

# Remove resíduos do patch posicional que falhou.
for pattern in ("*.rej", "*.orig"):
    for artifact in root.rglob(pattern):
        artifact.unlink()

# Validação final do AppsFilterBase.
final_text = apps_path.read_text(encoding="utf-8")
final_methods = parse_methods(final_text)

bridge_final = select_method(
    final_methods,
    bridge_name,
    bridge_parameters,
    bridge_return,
)

main_final = select_method(
    final_methods,
    main_name,
    main_parameters,
    main_return,
)

if len(bridge_final) != 1:
    raise SystemExit(
        "ERRO: ponte HMA final ausente ou duplicada"
    )

if len(main_final) != 1:
    raise SystemExit(
        "ERRO: shouldFilterApplication final ausente "
        "ou duplicado"
    )

bridge_body = str(bridge_final[0]["text"])
main_body = str(main_final[0]["text"])

required_bridge_fragments = (
    "instance-of v1, p0, Lcom/android/server/pm/ComputerEngine;",
    "check-cast p0, Lcom/android/server/pm/ComputerEngine;",
    (
        "Lcom/android/server/pm/ComputerEngine;"
        "->shouldFilterApplicationCustom("
        "Lcom/android/server/pm/pkg/"
        "PackageStateInternal;II)Z"
    ),
)

for fragment in required_bridge_fragments:
    if fragment not in bridge_body:
        raise SystemExit(
            "ERRO: ponte AppsFilterBase incompleta: "
            + fragment
        )

if main_body.count(hook_call) != 1:
    raise SystemExit(
        "ERRO: hook HMA deve aparecer exatamente uma vez "
        "em shouldFilterApplication"
    )

if (
    main_body.count(
        ":cond_hma_apps_filter_continue"
    )
    != 1
):
    raise SystemExit(
        "ERRO: label HMA ausente ou duplicada"
    )

# Confirma que o destino instalado pelo patch de ComputerEngine existe.
computer_text = computer_path.read_text(encoding="utf-8")
computer_methods = parse_methods(computer_text)

computer_target = select_method(
    computer_methods,
    bridge_name,
    computer_parameters,
    "Z",
)

if len(computer_target) != 1:
    raise SystemExit(
        "ERRO: ComputerEngine não contém exatamente um "
        "shouldFilterApplicationCustom("
        "PackageStateInternal;II)Z. "
        "O patch ComputerEngine-only não foi aplicado corretamente."
    )

rejects = sorted(
    [
        *root.rglob("*.rej"),
        *root.rglob("*.orig"),
    ]
)

if rejects:
    raise SystemExit(
        "ERRO: ainda existem resíduos de patch:\n"
        + "\n".join(map(str, rejects))
    )

apps_digest = hashlib.sha256(
    apps_path.read_bytes()
).hexdigest()

computer_digest = hashlib.sha256(
    computer_path.read_bytes()
).hexdigest()

audit = {
    "status": "semantic_patch_validated",
    "artifact": str(root),
    "apps_filter_base": str(
        apps_path.relative_to(root)
    ),
    "computer_engine": str(
        computer_path.relative_to(root)
    ),
    "bridge_inserted_this_run": bridge_inserted,
    "hook_inserted_this_run": hook_inserted,
    "sha256": {
        "AppsFilterBase.smali": apps_digest,
        "ComputerEngine.smali": computer_digest,
    },
    "validations": {
        "apps_filter_bridge_present": True,
        "apps_filter_early_hook_present": True,
        "computer_engine_target_present": True,
        "reject_files_remaining": 0,
    },
}

audit_file.write_text(
    json.dumps(
        audit,
        indent=2,
        ensure_ascii=False,
    )
    + "\n",
    encoding="utf-8",
)

print("=== HMA AppsFilterBase semântico ===")
print(
    "AppsFilterBase:",
    apps_path.relative_to(root),
)
print(
    "ComputerEngine:",
    computer_path.relative_to(root),
)
print()
print(
    "Ponte inserida nesta execução:",
    bridge_inserted,
)
print(
    "Hook inserido nesta execução:",
    hook_inserted,
)
print()
print(
    "VALIDADO: shouldFilterApplicationCustom bridge presente"
)
print(
    "VALIDADO: hook inicial em shouldFilterApplication presente"
)
print(
    "VALIDADO: destino ComputerEngine.shouldFilterApplicationCustom presente"
)
print(
    "VALIDADO: nenhum .rej ou .orig permanece"
)
print(
    "SHA-256 AppsFilterBase:",
    apps_digest,
)
print(
    "SHA-256 ComputerEngine:",
    computer_digest,
)
print(
    "AUDIT:",
    audit_file,
)
PY
