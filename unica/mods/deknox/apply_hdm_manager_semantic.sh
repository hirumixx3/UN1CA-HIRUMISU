#!/usr/bin/env bash

set -euo pipefail

: "${APKTOOL_DIR:?ERRO: APKTOOL_DIR não definido}"

if [ "$#" -ne 2 ]; then
    echo "Uso: $0 <partição> <caminho relativo>"
    exit 1
fi

PARTITION="$1"
RELATIVE_PATH="$2"

case "$RELATIVE_PATH" in
    "$PARTITION"/*)
        ARTIFACT_RELATIVE="${RELATIVE_PATH#"$PARTITION"/}"
        ;;
    *)
        ARTIFACT_RELATIVE="$RELATIVE_PATH"
        ;;
esac

ARTIFACT_DIR="$APKTOOL_DIR/$PARTITION/$ARTIFACT_RELATIVE"

AUDIT_ROOT="${WORK_DIR:-${APKTOOL_DIR%/apktool}}"

AUDIT_NAME="$(
    printf '%s' "${PARTITION}_${RELATIVE_PATH}" |
    tr '/.' '__'
)"

AUDIT_FILE="$AUDIT_ROOT/${AUDIT_NAME}-hdm-semantic-audit.json"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "ERRO: artefato decompilado não encontrado:"
    echo "$ARTIFACT_DIR"
    exit 1
fi

mkdir -p "$AUDIT_ROOT"

python3 - \
    "$ARTIFACT_DIR" \
    "$AUDIT_FILE" <<'PY'
from pathlib import Path
import hashlib
import json
import re
import sys

root = Path(sys.argv[1])
audit_file = Path(sys.argv[2])

METHOD_RE = re.compile(
    r"(?ms)^\.method[^\n]*\n.*?^\.end method[ \t]*(?:\n|$)"
)

matches = sorted(
    root.glob(
        "smali*/com/samsung/android/knox/hdm/"
        "HdmManager.smali"
    )
)

if len(matches) != 1:
    raise SystemExit(
        "ERRO: esperava exatamente um HdmManager.smali; "
        f"encontrei {len(matches)}:\n"
        + "\n".join(map(str, matches))
    )

path = matches[0]


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


def stub_body(return_type: str):
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

    if return_type == "Z":
        return [
            "    .locals 1",
            "",
            "    const/4 v0, 0x0",
            "",
            "    return v0",
        ]

    if return_type == "F":
        return [
            "    .locals 1",
            "",
            "    const/4 v0, 0x0",
            "",
            "    return v0",
        ]

    # I, B, S e C: falha/não suportado.
    return [
        "    .locals 1",
        "",
        "    const/4 v0, -0x1",
        "",
        "    return v0",
    ]


text = path.read_text(encoding="utf-8")
methods = parse_methods(text)

replacements = []
patched = []

for method in methods:
    declaration = str(method["declaration"])
    name = str(method["name"])

    if name in ("<init>", "<clinit>"):
        continue

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
            "ERRO: método concreto sem .locals/.registers: "
            + declaration
        )

    # Preserva anotações antes de .locals/.registers.
    preamble = old_lines[1:register_index]

    replacement = "\n".join(
        [
            declaration,
            *preamble,
            *stub_body(str(method["return_type"])),
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

path.write_text(text, encoding="utf-8")

# Remove resíduos de patches posicionais anteriores.
for pattern in ("*.rej", "*.orig"):
    for artifact in root.rglob(pattern):
        artifact.unlink()

# Validação final.
final_text = path.read_text(encoding="utf-8")
final_methods = parse_methods(final_text)

invalid = []

for method in final_methods:
    declaration = str(method["declaration"])
    name = str(method["name"])

    if name in ("<init>", "<clinit>"):
        continue

    if (
        " abstract " in f" {declaration} "
        or " native " in f" {declaration} "
    ):
        continue

    body = str(method["text"])

    if re.search(
        r"invoke-(?:virtual|interface|static|direct|super)",
        body,
    ):
        invalid.append(
            f"{declaration}: ainda contém invoke"
        )

    return_type = str(method["return_type"])

    if return_type == "V":
        if "return-void" not in body:
            invalid.append(
                f"{declaration}: sem return-void"
            )

    elif return_type in ("J", "D"):
        if "return-wide v0" not in body:
            invalid.append(
                f"{declaration}: sem return-wide"
            )

    elif return_type.startswith("L") or return_type.startswith("["):
        if "return-object v0" not in body:
            invalid.append(
                f"{declaration}: sem return-object null"
            )

    else:
        if "return v0" not in body:
            invalid.append(
                f"{declaration}: sem return v0"
            )

if invalid:
    raise SystemExit(
        "ERRO: validação HDM falhou:\n"
        + "\n".join(invalid)
    )

rejects = sorted(
    [
        *root.rglob("*.rej"),
        *root.rglob("*.orig"),
    ]
)

if rejects:
    raise SystemExit(
        "ERRO: resíduos restantes:\n"
        + "\n".join(map(str, rejects))
    )

digest = hashlib.sha256(path.read_bytes()).hexdigest()

audit = {
    "status": "semantic_patch_validated",
    "artifact": str(root),
    "hdm_manager": str(path.relative_to(root)),
    "patched_methods": patched,
    "patched_method_count": len(patched),
    "sha256": digest,
    "validations": {
        "constructors_preserved": True,
        "concrete_hdm_methods_neutralized": True,
        "remote_service_invocations_remaining": 0,
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

print(f"=== HDM semântico: {root.name} ===")
print(f"HdmManager: {path.relative_to(root)}")
print(f"Métodos neutralizados: {len(patched)}")

for declaration in patched:
    print("  -", declaration)

print()
print("VALIDADO: construtores preservados")
print("VALIDADO: métodos concretos HDM neutralizados")
print("VALIDADO: nenhuma chamada ao serviço HDM permanece")
print("VALIDADO: nenhum .rej ou .orig permanece")
print(f"SHA-256: {digest}")
print(f"AUDIT: {audit_file}")
PY
