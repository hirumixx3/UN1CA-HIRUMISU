#!/usr/bin/env bash

set -euo pipefail

: "${APKTOOL_DIR:?ERRO: APKTOOL_DIR não definido}"

KNOXSDK_DIR="$APKTOOL_DIR/system/framework/knoxsdk.jar"
AUDIT_DIR="${WORK_DIR:-${APKTOOL_DIR%/apktool}}"
AUDIT_FILE="$AUDIT_DIR/knoxsdk-dualdar-semantic-audit.json"

if [ ! -d "$KNOXSDK_DIR" ]; then
    echo "ERRO: knoxsdk.jar decompilado não encontrado:"
    echo "$KNOXSDK_DIR"
    exit 1
fi

mkdir -p "$AUDIT_DIR"

python3 - "$KNOXSDK_DIR" "$AUDIT_FILE" <<'PY'
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


def find_one(relative_path: str) -> Path:
    matches = sorted(root.glob(f"smali*/{relative_path}"))

    if len(matches) != 1:
        raise SystemExit(
            f"ERRO: esperava exatamente um {relative_path}; "
            f"encontrei {len(matches)}:\n"
            + "\n".join(map(str, matches))
        )

    return matches[0]


container_file = find_one(
    "com/samsung/android/knox/container/"
    "KnoxContainerManager.smali"
)

policy_file = find_one(
    "com/samsung/android/knox/ddar/"
    "DualDARPolicy.smali"
)


def parse_methods(text: str):
    methods = []

    for match in METHOD_RE.finditer(text):
        method_text = match.group(0)
        declaration = method_text.splitlines()[0]

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
                "text": method_text,
            }
        )

    return methods


def find_exact_method(
    path: Path,
    name: str,
    parameters: str,
    return_type: str,
):
    text = path.read_text(encoding="utf-8")

    matches = [
        method
        for method in parse_methods(text)
        if method["name"] == name
        and method["parameters"] == parameters
        and method["return_type"] == return_type
    ]

    if len(matches) != 1:
        available = "\n".join(
            f"  {method['declaration']}"
            for method in parse_methods(text)
            if method["name"] == name
        )

        raise SystemExit(
            f"ERRO: esperava exatamente um método "
            f"{name}({parameters}){return_type} em {path}; "
            f"encontrei {len(matches)}.\n"
            f"Assinaturas encontradas:\n{available}"
        )

    return text, matches[0]


def rewrite_method(
    path: Path,
    name: str,
    parameters: str,
    return_type: str,
    body_lines: list[str],
):
    text, method = find_exact_method(
        path,
        name,
        parameters,
        return_type,
    )

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
            f"ERRO: método concreto sem .locals/.registers: "
            f"{method['declaration']}"
        )

    # Preserva anotações existentes antes de .locals/.registers.
    preamble = old_lines[1:register_index]

    replacement = "\n".join(
        [
            str(method["declaration"]),
            *preamble,
            *body_lines,
            ".end method",
            "",
        ]
    )

    new_text = (
        text[:method["start"]]
        + replacement
        + text[method["end"]:]
    )

    path.write_text(new_text, encoding="utf-8")


print("=== KnoxSDK DualDAR ===")
print("KnoxContainerManager:", container_file)
print("DualDARPolicy:       ", policy_file)

rewrite_method(
    container_file,
    "getDualDARPolicy",
    "",
    "Lcom/samsung/android/knox/ddar/DualDARPolicy;",
    [
        "    .locals 1",
        "",
        "    iget-object v0, p0, "
        "Lcom/samsung/android/knox/container/"
        "KnoxContainerManager;"
        "->mDualDARPolicy:"
        "Lcom/samsung/android/knox/ddar/DualDARPolicy;",
        "",
        "    return-object v0",
    ],
)

rewrite_method(
    policy_file,
    "getDualDARVersion",
    "",
    "Ljava/lang/String;",
    [
        "    .locals 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return-object v0",
    ],
)

rewrite_method(
    policy_file,
    "isDualDarSupportedForManagedDevice",
    "",
    "Z",
    [
        "    .locals 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
    ],
)

# Remove rejeitos da tentativa parcial com GNU patch.
for pattern in ("*.rej", "*.orig"):
    for artifact in root.rglob(pattern):
        artifact.unlink()


def read_exact_method(
    path: Path,
    name: str,
    parameters: str,
    return_type: str,
) -> str:
    _, method = find_exact_method(
        path,
        name,
        parameters,
        return_type,
    )

    return str(method["text"])


get_policy = read_exact_method(
    container_file,
    "getDualDARPolicy",
    "",
    "Lcom/samsung/android/knox/ddar/DualDARPolicy;",
)

get_version = read_exact_method(
    policy_file,
    "getDualDARVersion",
    "",
    "Ljava/lang/String;",
)

is_supported = read_exact_method(
    policy_file,
    "isDualDarSupportedForManagedDevice",
    "",
    "Z",
)

if "new-instance" in get_policy:
    raise SystemExit(
        "ERRO: getDualDARPolicy ainda instancia DualDARPolicy"
    )

if "mDualDARPolicy:" not in get_policy:
    raise SystemExit(
        "ERRO: getDualDARPolicy não acessa mDualDARPolicy"
    )

if "return-object v0" not in get_policy:
    raise SystemExit(
        "ERRO: getDualDARPolicy não retorna o campo"
    )

if "const/4 v0, 0x0" not in get_version:
    raise SystemExit(
        "ERRO: getDualDARVersion não carrega null"
    )

if "return-object v0" not in get_version:
    raise SystemExit(
        "ERRO: getDualDARVersion não retorna null"
    )

if re.search(r"const-string[^\n]*", get_version):
    raise SystemExit(
        "ERRO: getDualDARVersion ainda contém versão textual"
    )

if "const/4 v0, 0x0" not in is_supported:
    raise SystemExit(
        "ERRO: isDualDarSupportedForManagedDevice "
        "não carrega false"
    )

if "return v0" not in is_supported:
    raise SystemExit(
        "ERRO: isDualDarSupportedForManagedDevice "
        "não retorna false"
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

files = {
    "KnoxContainerManager": container_file,
    "DualDARPolicy": policy_file,
}

hashes = {
    name: {
        "path": str(path.relative_to(root)),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
    for name, path in files.items()
}

audit = {
    "status": "semantic_patch_validated",
    "target": str(root),
    "validations": {
        "getDualDARPolicy_does_not_instantiate": True,
        "getDualDARVersion_returns_null": True,
        "managed_device_support_returns_false": True,
        "reject_files_remaining": 0,
    },
    "files": hashes,
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

print()
print("VALIDADO: getDualDARPolicy não instancia DualDARPolicy")
print("VALIDADO: getDualDARVersion retorna null")
print(
    "VALIDADO: isDualDarSupportedForManagedDevice retorna false"
)
print("VALIDADO: nenhum .rej ou .orig permanece")

for name, data in hashes.items():
    print(f"SHA-256 {name}: {data['sha256']}")

print(f"AUDIT: {audit_file}")
PY

echo "OK: patch semântico DualDAR do knoxsdk.jar concluído"
