#!/usr/bin/env bash

set -euo pipefail

: "${APKTOOL_DIR:?ERRO: APKTOOL_DIR não definido}"

FRAMEWORK_DIR="$APKTOOL_DIR/system/framework/framework.jar"
AUDIT_ROOT="${WORK_DIR:-${APKTOOL_DIR%/apktool}}"
AUDIT_FILE="$AUDIT_ROOT/kmxai-framework-semantic-audit.json"

if [ ! -d "$FRAMEWORK_DIR" ]; then
    echo "ERRO: framework.jar decompilado não encontrado:"
    echo "$FRAMEWORK_DIR"
    exit 1
fi

mkdir -p "$AUDIT_ROOT"

python3 - "$FRAMEWORK_DIR" "$AUDIT_FILE" <<'PY'
from pathlib import Path
import hashlib
import json
import re
import sys

root = Path(sys.argv[1])
audit_file = Path(sys.argv[2])

relative = (
    "com/samsung/android/kmxservice/ai/privacy/"
    "PermissionDataController.smali"
)

matches = sorted(root.glob(f"smali*/{relative}"))

if len(matches) != 1:
    raise SystemExit(
        "ERRO: esperava exatamente um "
        "PermissionDataController.smali; "
        f"encontrei {len(matches)}:\n"
        + "\n".join(map(str, matches))
    )

controller = matches[0]

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


def default_body(return_type: str):
    if return_type == "V":
        return [
            "    .locals 0",
            "",
            "    return-void",
        ]

    if return_type in ("J", "D"):
        return [
            "    .locals 2",
            "",
            "    const-wide/16 v0, 0x0",
            "",
            "    return-wide v0",
        ]

    if return_type.startswith("L") or return_type.startswith("["):
        return [
            "    .locals 1",
            "",
            "    const/4 v0, 0x0",
            "",
            "    return-object v0",
        ]

    return [
        "    .locals 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
    ]


text = controller.read_text(encoding="utf-8")

super_match = re.search(
    r"(?m)^\.super\s+(L[^;]+;)[ \t]*$",
    text,
)

if not super_match:
    raise SystemExit(
        "ERRO: superclasse de PermissionDataController não encontrada"
    )

super_class = super_match.group(1)

if super_class != "Ljava/lang/Object;":
    raise SystemExit(
        "ERRO: superclasse inesperada: "
        + super_class
    )

methods = parse_methods(text)

if not methods:
    raise SystemExit(
        "ERRO: nenhum método encontrado em PermissionDataController"
    )

replacements = []
patched = []

for method in methods:
    declaration = str(method["declaration"])
    name = str(method["name"])
    return_type = str(method["return_type"])

    if (
        " abstract " in f" {declaration} "
        or " native " in f" {declaration} "
    ):
        continue

    old_lines = str(method["text"]).splitlines()

    register_index = None

    for index, line in enumerate(old_lines[1:], start=1):
        stripped = line.strip()

        if (
            stripped.startswith(".locals ")
            or stripped.startswith(".registers ")
        ):
            register_index = index
            break

    if register_index is None:
        raise SystemExit(
            "ERRO: método concreto sem .locals/.registers:\n"
            + declaration
        )

    # Preserva anotações existentes antes de .locals/.registers.
    preamble = old_lines[1:register_index]

    if name == "<init>":
        body = [
            "    .locals 0",
            "",
            f"    invoke-direct {{p0}}, {super_class}-><init>()V",
            "",
            "    return-void",
        ]

    elif name == "<clinit>":
        body = [
            "    .locals 0",
            "",
            "    return-void",
        ]

    else:
        body = default_body(return_type)

    replacement = "\n".join(
        [
            declaration,
            *preamble,
            *body,
            ".end method",
            "",
        ]
    )

    replacements.append(
        (
            int(method["start"]),
            int(method["end"]),
            replacement,
        )
    )

    patched.append(declaration)

for start, end, replacement in reversed(replacements):
    text = text[:start] + replacement + text[end:]

controller.write_text(text, encoding="utf-8")

# Remove resíduos deixados pelo GNU patch parcial.
for pattern in ("*.rej", "*.orig"):
    for artifact in root.rglob(pattern):
        artifact.unlink()

final_text = controller.read_text(encoding="utf-8")
final_methods = parse_methods(final_text)

required = {
    ("flush", "", "V"),
    ("flushAsync", "", "V"),
    ("write", "IILjava/lang/String;I", "V"),
}

found = {
    (
        str(method["name"]),
        str(method["parameters"]),
        str(method["return_type"]),
    )
    for method in final_methods
}

missing = required - found

if missing:
    raise SystemExit(
        "ERRO: métodos obrigatórios ausentes após correção:\n"
        + "\n".join(
            f"{name}({parameters}){return_type}"
            for name, parameters, return_type in sorted(missing)
        )
    )

invalid = []

for method in final_methods:
    declaration = str(method["declaration"])
    name = str(method["name"])
    body = str(method["text"])

    if (
        " abstract " in f" {declaration} "
        or " native " in f" {declaration} "
    ):
        continue

    if name == "<init>":
        expected = (
            "invoke-direct {p0}, "
            "Ljava/lang/Object;-><init>()V"
        )

        if expected not in body:
            invalid.append(
                f"{declaration}: construtor não chama Object.<init>"
            )

        invokes = re.findall(
            r"(?m)^[ \t]*invoke-[^\n]+",
            body,
        )

        if invokes != [
            "    invoke-direct {p0}, "
            "Ljava/lang/Object;-><init>()V"
        ]:
            invalid.append(
                f"{declaration}: construtor contém chamadas extras"
            )

        continue

    # Analisa somente instruções executáveis. Tipos presentes na
    # assinatura, em .param, .annotation, .local ou labels preservam
    # a ABI e não significam que a lógica KMX ainda está ativa.
    executable_lines = []

    for line in body.splitlines()[1:]:
        stripped = line.strip()

        if not stripped:
            continue

        if stripped.startswith((".", ":", "#")):
            continue

        executable_lines.append(line)

    executable_body = "\n".join(executable_lines)

    # Nenhum método KMX AI Privacy pode executar trabalho real.
    forbidden = (
        r"(?m)^[ \t]*invoke-",
        r"(?m)^[ \t]*new-instance",
        r"(?m)^[ \t]*iget",
        r"(?m)^[ \t]*iput",
        r"(?m)^[ \t]*sget",
        r"(?m)^[ \t]*sput",
        r"PermissionData;",
        r"PermissionDataController\$1;",
        r"PermissionDataController\$2;",
    )

    for pattern in forbidden:
        if re.search(pattern, executable_body):
            invalid.append(
                f"{declaration}: ainda contém lógica KMX executável "
                f"({pattern})"
            )

if invalid:
    raise SystemExit(
        "ERRO: validação semântica KMX falhou:\n"
        + "\n".join(invalid)
    )


def require_noop(
    name: str,
    parameters: str,
    return_type: str,
):
    selected = [
        method
        for method in final_methods
        if method["name"] == name
        and method["parameters"] == parameters
        and method["return_type"] == return_type
    ]

    if len(selected) != 1:
        raise SystemExit(
            f"ERRO: validação encontrou {len(selected)} métodos "
            f"{name}({parameters}){return_type}"
        )

    body = str(selected[0]["text"])

    if "return-void" not in body:
        raise SystemExit(
            f"ERRO: {name}({parameters}) não é no-op"
        )


require_noop("flush", "", "V")
require_noop("flushAsync", "", "V")
require_noop(
    "write",
    "IILjava/lang/String;I",
    "V",
)

rejects = sorted(
    [
        *root.rglob("*.rej"),
        *root.rglob("*.orig"),
    ]
)

if rejects:
    raise SystemExit(
        "ERRO: ainda existem rejeitos:\n"
        + "\n".join(map(str, rejects))
    )

digest = hashlib.sha256(controller.read_bytes()).hexdigest()

audit = {
    "status": "semantic_patch_validated",
    "artifact": str(root),
    "controller": str(controller.relative_to(root)),
    "super_class": super_class,
    "patched_method_count": len(patched),
    "patched_methods": patched,
    "sha256": digest,
    "validations": {
        "controller_neutralized": True,
        "flush_noop": True,
        "flush_async_noop": True,
        "write_noop": True,
        "permission_data_references_in_executable_methods": 0,
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

print("=== Knox Matrix AI Privacy ===")
print("Controller:", controller.relative_to(root))
print("Métodos neutralizados:", len(patched))

for declaration in patched:
    print("  -", declaration)

print()
print("VALIDADO: PermissionDataController neutralizado")
print("VALIDADO: flush() é no-op")
print("VALIDADO: flushAsync() é no-op")
print("VALIDADO: write(...) é no-op")
print("VALIDADO: nenhuma lógica PermissionData permanece executável")
print("VALIDADO: nenhum .rej ou .orig permanece")
print(f"SHA-256: {digest}")
print(f"AUDIT: {audit_file}")
PY

echo "OK: patch semântico KMX AI Privacy concluído"
