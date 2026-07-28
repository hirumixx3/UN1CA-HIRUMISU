#!/usr/bin/env bash

set -euo pipefail

: "${APKTOOL_DIR:?ERRO: APKTOOL_DIR não definido}"

SERVICES_DIR="$APKTOOL_DIR/system/framework/services.jar"

if [ ! -d "$SERVICES_DIR" ]; then
    echo "ERRO: services.jar decompilado não encontrado:"
    echo "$SERVICES_DIR"
    exit 1
fi

python3 - "$SERVICES_DIR" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

root = Path(sys.argv[1])

dar_matches = list(
    root.glob(
        "smali*/com/android/server/knox/dar/"
        "DarManagerService.smali"
    )
)

if len(dar_matches) != 1:
    raise SystemExit(
        "ERRO: esperava exatamente um DarManagerService.smali; "
        f"encontrei {len(dar_matches)}:\n"
        + "\n".join(map(str, dar_matches))
    )

dar_file = dar_matches[0]


def methods_from_text(text: str):
    """Retorna os métodos smali com limites e assinatura."""
    methods = []

    starts = list(
        re.finditer(
            r"(?m)^\.method[^\n]*$",
            text,
        )
    )

    for match in starts:
        start = match.start()
        declaration = match.group(0)

        end_match = re.search(
            r"(?m)^\.end method[ \t]*$",
            text[match.end():],
        )

        if not end_match:
            raise RuntimeError(
                f"Método sem .end method: {declaration}"
            )

        end = match.end() + end_match.end()

        if end < len(text) and text[end] == "\n":
            end += 1

        signature_match = re.search(
            r"([^\s(]+)\(([^)]*)\)(\S+)$",
            declaration,
        )

        if not signature_match:
            continue

        methods.append(
            {
                "start": start,
                "end": end,
                "declaration": declaration,
                "name": signature_match.group(1),
                "parameters": signature_match.group(2),
                "return_type": signature_match.group(3),
                "text": text[start:end],
            }
        )

    return methods


def make_stub(
    declaration: str,
    return_type: str,
    unsupported_int: bool = False,
) -> str:
    """Cria implementação smali mínima e válida."""

    lines = [declaration]

    if return_type == "V":
        lines.extend(
            [
                "    .locals 0",
                "",
                "    return-void",
                ".end method",
                "",
            ]
        )

    elif return_type in ("J", "D"):
        lines.extend(
            [
                "    .locals 2",
                "",
                "    const-wide/16 v0, 0x0",
                "",
                "    return-wide v0",
                ".end method",
                "",
            ]
        )

    elif return_type.startswith("L") or return_type.startswith("["):
        lines.extend(
            [
                "    .locals 1",
                "",
                "    const/4 v0, 0x0",
                "",
                "    return-object v0",
                ".end method",
                "",
            ]
        )

    elif return_type == "I" and unsupported_int:
        lines.extend(
            [
                "    .locals 1",
                "",
                "    const/16 v0, -0xa",
                "",
                "    return v0",
                ".end method",
                "",
            ]
        )

    else:
        # Z, B, S, C, I e F.
        lines.extend(
            [
                "    .locals 1",
                "",
                "    const/4 v0, 0x0",
                "",
                "    return v0",
                ".end method",
                "",
            ]
        )

    return "\n".join(lines)


def replace_methods(
    path: Path,
    predicate,
    unsupported_int: bool = False,
):
    text = path.read_text(encoding="utf-8")
    methods = methods_from_text(text)
    replacements = []

    for method in methods:
        if " abstract " in f" {method['declaration']} ":
            continue

        if " native " in f" {method['declaration']} ":
            continue

        if not predicate(method):
            continue

        replacement = make_stub(
            method["declaration"],
            method["return_type"],
            unsupported_int=unsupported_int,
        )

        replacements.append(
            (
                method["start"],
                method["end"],
                replacement,
                method["name"],
            )
        )

    for start, end, replacement, _ in reversed(replacements):
        text = text[:start] + replacement + text[end:]

    if replacements:
        path.write_text(text, encoding="utf-8")

    return [item[3] for item in replacements]


print("=== DarManagerService ===")
print(dar_file)

dar_text = dar_file.read_text(encoding="utf-8")

# Remove a inicialização do SdpManagerImpl no construtor.
constructor_pattern = re.compile(
    r"""
    (?mx)
    ^[ \t]*new-instance[ \t]+
        (?P<reg>[vp][0-9]+),
        [ \t]*Lcom/android/server/knox/dar/sdp/SdpManagerImpl;
        [ \t]*\n
    (?:^[ \t]*\n)*
    ^[ \t]*invoke-direct[ \t]+
        \{(?P=reg),[ \t]*[^}]+\},
        [ \t]*Lcom/android/server/knox/dar/sdp/SdpManagerImpl;
        -><init>\(
            Lcom/android/server/knox/dar/
            DarManagerService\$Injector;
        \)V
        [ \t]*\n
    (?:^[ \t]*\n)*
    ^[ \t]*iput-object[ \t]+
        (?P=reg),[ \t]*p0,
        [ \t]*Lcom/android/server/knox/dar/
        DarManagerService;
        ->mSdpManagerImpl:
        Lcom/android/server/knox/dar/sdp/SdpManagerImpl;
        [ \t]*\n?
    (?:^[ \t]*\n)*
    """,
)

dar_text, constructor_removals = constructor_pattern.subn(
    "",
    dar_text,
)

dar_file.write_text(dar_text, encoding="utf-8")

remaining_new_instances = re.findall(
    r"new-instance[^\n]*"
    r"Lcom/android/server/knox/dar/sdp/SdpManagerImpl;",
    dar_text,
)

if remaining_new_instances:
    raise SystemExit(
        "ERRO: ainda existe criação de SdpManagerImpl em "
        "DarManagerService.smali"
    )

print(
    "Inicializações de SdpManagerImpl removidas:",
    constructor_removals,
)

# Neutraliza métodos de DarManagerService que acessam o manager SDP.
manager_methods = replace_methods(
    dar_file,
    lambda method: (
        method["name"] not in ("<init>", "<clinit>")
        and "mSdpManagerImpl" in method["text"]
    ),
    unsupported_int=True,
)

print(
    "Métodos que acessavam mSdpManagerImpl neutralizados:",
    len(manager_methods),
)

for name in manager_methods:
    print("  -", name)

# Força os gates SDP booleanos em todo o namespace Knox DAR.
gate_files = sorted(
    path
    for path in root.glob(
        "smali*/com/android/server/knox/dar/**/*.smali"
    )
    if path.is_file()
)

patched_gates = []

for path in gate_files:
    names = replace_methods(
        path,
        lambda method: (
            method["return_type"] == "Z"
            and (
                method["name"].lower().startswith("issdp")
                or method["name"].lower() == "issupporteddevice"
            )
        ),
    )

    for name in names:
        patched_gates.append((path, name))

if not any(
    path == dar_file and name == "isSdpSupported"
    for path, name in patched_gates
):
    raise SystemExit(
        "ERRO: DarManagerService.isSdpSupported(...)Z "
        "não foi encontrado ou não foi corrigido"
    )

print("Gates SDP forçados para false:", len(patched_gates))

for path, name in patched_gates:
    print(f"  - {path.relative_to(root)} -> {name}")

# Remove rejeitos antigos.
for suffix in (".rej", ".orig"):
    for artifact in root.rglob(f"*{suffix}"):
        artifact.unlink()

# Validação final do DarManagerService.
final_text = dar_file.read_text(encoding="utf-8")
final_methods = methods_from_text(final_text)

gates = [
    method
    for method in final_methods
    if method["name"] == "isSdpSupported"
    and method["return_type"] == "Z"
]

if not gates:
    raise SystemExit(
        "ERRO: gate isSdpSupported()Z desapareceu após a correção"
    )

for method in gates:
    body = method["text"]

    if "const/4 v0, 0x0" not in body or "return v0" not in body:
        raise SystemExit(
            "ERRO: isSdpSupported()Z não retorna false"
        )

if re.search(
    r"new-instance[^\n]*"
    r"Lcom/android/server/knox/dar/sdp/SdpManagerImpl;",
    final_text,
):
    raise SystemExit(
        "ERRO: SdpManagerImpl ainda é instanciado"
    )

# Referências ao field dentro de métodos não podem permanecer.
unsafe_methods = []

for method in final_methods:
    if (
        method["name"] not in ("<init>", "<clinit>")
        and "mSdpManagerImpl" in method["text"]
    ):
        unsafe_methods.append(method["name"])

if unsafe_methods:
    raise SystemExit(
        "ERRO: métodos ainda acessam mSdpManagerImpl:\n"
        + "\n".join(unsafe_methods)
    )

digest = hashlib.sha256(dar_file.read_bytes()).hexdigest()

print()
print("VALIDADO: DarManagerService.isSdpSupported retorna false")
print("VALIDADO: SdpManagerImpl não é mais inicializado")
print("VALIDADO: nenhum método executável acessa mSdpManagerImpl")
print(f"SHA-256: {digest}")
PY

echo "OK: patch SDP semântico do services.jar concluído"
