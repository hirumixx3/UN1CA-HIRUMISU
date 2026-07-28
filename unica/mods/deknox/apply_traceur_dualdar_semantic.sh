#!/usr/bin/env bash

set -euo pipefail

: "${APKTOOL_DIR:?ERRO: APKTOOL_DIR não definido}"

MOD_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd
)"

REPO_ROOT="$(
    cd "$MOD_DIR/../../.."
    pwd
)"

TRACEUR_PARTITION="system"
TRACEUR_RELATIVE_PATH="system/app/Traceur/Traceur.apk"
TRACEUR_DIR="$APKTOOL_DIR/system/app/Traceur/Traceur.apk"

# scripts/apktool.sh precisa dessas variáveis no ambiente.
export SRC_DIR="$REPO_ROOT"
export WORK_DIR="${WORK_DIR:-${APKTOOL_DIR%/apktool}}"
export TOOLS_DIR="${TOOLS_DIR:-$REPO_ROOT/tools}"

TRACEUR_SOURCE_APK="$WORK_DIR/system/$TRACEUR_RELATIVE_PATH"

if [ ! -f "$TRACEUR_SOURCE_APK" ]; then
    echo "ERRO: APK original do Traceur não encontrado:"
    echo "$TRACEUR_SOURCE_APK"
    exit 1
fi

if [ ! -d "$TRACEUR_DIR" ]; then
    echo "    - Decoding /system/system/app/Traceur/Traceur.apk"

    "$REPO_ROOT/scripts/apktool.sh" \
        d \
        "$TRACEUR_PARTITION" \
        "$TRACEUR_RELATIVE_PATH"
fi

if [ ! -d "$TRACEUR_DIR" ]; then
    echo "ERRO: apktool terminou sem criar o diretório:"
    echo "$TRACEUR_DIR"
    exit 1
fi

if ! find "$TRACEUR_DIR" \
    -type f \
    -name 'DualDARPolicy.smali' \
    -print -quit |
    grep -q .
then
    echo "ERRO: Traceur foi decompilado, mas DualDARPolicy.smali não existe"
    exit 1
fi

python3 - "$TRACEUR_DIR" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

root = Path(sys.argv[1])

targets = {
    "container": list(
        root.glob(
            "smali*/com/samsung/android/knox/container/"
            "KnoxContainerManager.smali"
        )
    ),
    "policy": list(
        root.glob(
            "smali*/com/samsung/android/knox/ddar/"
            "DualDARPolicy.smali"
        )
    ),
}

for name, matches in targets.items():
    if len(matches) != 1:
        raise SystemExit(
            f"ERRO: esperava exatamente um arquivo {name}; "
            f"encontrei {len(matches)}:\n"
            + "\n".join(map(str, matches))
        )

container_file = targets["container"][0]
policy_file = targets["policy"][0]


def parse_methods(text: str):
    methods = []

    pattern = re.compile(
        r"(?ms)^\.method[^\n]*\n.*?^\.end method[ \t]*\n?"
    )

    for match in pattern.finditer(text):
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


def replace_exact_method(
    path: Path,
    name: str,
    parameters: str,
    return_type: str,
    body_lines: list[str],
):
    text = path.read_text(encoding="utf-8")
    methods = parse_methods(text)

    matches = [
        method for method in methods
        if method["name"] == name
        and method["parameters"] == parameters
        and method["return_type"] == return_type
    ]

    if len(matches) != 1:
        available = "\n".join(
            f"  {m['name']}({m['parameters']}){m['return_type']}"
            for m in methods
            if m["name"] == name
        )

        raise SystemExit(
            f"ERRO: esperava exatamente um método "
            f"{name}({parameters}){return_type} em {path}; "
            f"encontrei {len(matches)}.\n"
            f"Assinaturas com mesmo nome:\n{available}"
        )

    method = matches[0]

    replacement = (
        method["declaration"]
        + "\n"
        + "\n".join(body_lines)
        + "\n.end method\n"
    )

    new_text = (
        text[:method["start"]]
        + replacement
        + text[method["end"]:]
    )

    path.write_text(new_text, encoding="utf-8")


print("=== Arquivos ===")
print(container_file)
print(policy_file)

replace_exact_method(
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

replace_exact_method(
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

replace_exact_method(
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

# Remove resíduos das tentativas anteriores.
for path in root.rglob("*.rej"):
    path.unlink()

for path in root.rglob("*.orig"):
    path.unlink()


def get_method(
    path: Path,
    name: str,
    parameters: str,
    return_type: str,
):
    text = path.read_text(encoding="utf-8")

    matches = [
        method for method in parse_methods(text)
        if method["name"] == name
        and method["parameters"] == parameters
        and method["return_type"] == return_type
    ]

    if len(matches) != 1:
        raise SystemExit(
            f"ERRO: falha na validação de "
            f"{name}({parameters}){return_type}"
        )

    return matches[0]["text"]


get_policy = get_method(
    container_file,
    "getDualDARPolicy",
    "",
    "Lcom/samsung/android/knox/ddar/DualDARPolicy;",
)

get_version = get_method(
    policy_file,
    "getDualDARVersion",
    "",
    "Ljava/lang/String;",
)

is_supported = get_method(
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
        "ERRO: getDualDARPolicy não retorna o campo existente"
    )

if "return-object" not in get_policy:
    raise SystemExit(
        "ERRO: getDualDARPolicy não possui return-object"
    )

if "const/4 v0, 0x0" not in get_version:
    raise SystemExit(
        "ERRO: getDualDARVersion não carrega null"
    )

if "return-object v0" not in get_version:
    raise SystemExit(
        "ERRO: getDualDARVersion não retorna null"
    )

if re.search(r'const-string[^\n]*"', get_version):
    raise SystemExit(
        "ERRO: getDualDARVersion ainda retorna uma versão textual"
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

if list(root.rglob("*.rej")):
    raise SystemExit("ERRO: ainda existem arquivos .rej no Traceur")

print()
print("VALIDADO: getDualDARPolicy não instancia DualDARPolicy")
print("VALIDADO: getDualDARVersion retorna null")
print(
    "VALIDADO: isDualDarSupportedForManagedDevice retorna false"
)

for path in (container_file, policy_file):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"SHA-256 {path.name}: {digest}")
PY

echo "OK: patch semântico DualDAR do Traceur concluído"
