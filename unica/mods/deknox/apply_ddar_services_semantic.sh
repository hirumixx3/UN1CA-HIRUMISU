#!/usr/bin/env bash

set -euo pipefail

: "${APKTOOL_DIR:?ERRO: APKTOOL_DIR não definido}"

SERVICES_DIR="$APKTOOL_DIR/system/framework/services.jar"
AUDIT_DIR="${WORK_DIR:-${APKTOOL_DIR%/apktool}}"
AUDIT_FILE="$AUDIT_DIR/dualdar-services-semantic-audit.json"

if [ ! -d "$SERVICES_DIR" ]; then
    echo "ERRO: services.jar decompilado não encontrado:"
    echo "$SERVICES_DIR"
    exit 1
fi

mkdir -p "$AUDIT_DIR"

python3 - "$SERVICES_DIR" "$AUDIT_FILE" <<'PY'
from __future__ import annotations

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

operations: list[str] = []
modified_files: set[Path] = set()


def parse_methods(text: str) -> list[dict]:
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


def find_one(relative_path: str, required: bool = True) -> Path | None:
    matches = sorted(root.glob(f"smali*/{relative_path}"))

    if not matches and not required:
        return None

    if len(matches) != 1:
        raise SystemExit(
            f"ERRO: esperava exatamente um {relative_path}; "
            f"encontrei {len(matches)}:\n"
            + "\n".join(map(str, matches))
        )

    return matches[0]


def replacement_method(
    declaration: str,
    body: list[str],
) -> str:
    return "\n".join(
        [
            declaration,
            *body,
            ".end method",
            "",
        ]
    )


def rewrite_matching(
    path: Path,
    predicate,
    body_factory,
    required: bool = False,
) -> int:
    text = path.read_text(encoding="utf-8")
    methods = parse_methods(text)

    replacements = []

    for method in methods:
        declaration = str(method["declaration"])

        if " abstract " in f" {declaration} ":
            continue

        if " native " in f" {declaration} ":
            continue

        if not predicate(method):
            continue

        body = body_factory(method)

        replacements.append(
            (
                int(method["start"]),
                int(method["end"]),
                replacement_method(declaration, body),
                declaration,
            )
        )

    if required and not replacements:
        raise SystemExit(
            f"ERRO: nenhum método correspondente encontrado em {path}"
        )

    for start, end, replacement, declaration in reversed(replacements):
        text = text[:start] + replacement + text[end:]
        operations.append(f"{path.name}: {declaration}")

    if replacements:
        path.write_text(text, encoding="utf-8")
        modified_files.add(path)

    return len(replacements)


def rewrite_exact(
    path: Path,
    name: str,
    parameters: str,
    return_type: str,
    body: list[str],
    required: bool = False,
) -> int:
    return rewrite_matching(
        path,
        lambda method: (
            method["name"] == name
            and method["parameters"] == parameters
            and method["return_type"] == return_type
        ),
        lambda method: body,
        required=required,
    )


def rewrite_name_and_return(
    path: Path,
    name: str,
    return_type: str,
    body: list[str],
    required: bool = False,
) -> int:
    return rewrite_matching(
        path,
        lambda method: (
            method["name"] == name
            and method["return_type"] == return_type
        ),
        lambda method: body,
        required=required,
    )


def false_body() -> list[str]:
    return [
        "    .locals 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
    ]


def true_body() -> list[str]:
    return [
        "    .locals 1",
        "",
        "    const/4 v0, 0x1",
        "",
        "    return v0",
    ]


def zero_body() -> list[str]:
    return [
        "    .locals 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
    ]


def minus_one_body() -> list[str]:
    return [
        "    .locals 1",
        "",
        "    const/4 v0, -0x1",
        "",
        "    return v0",
    ]


def invalid_user_body() -> list[str]:
    return [
        "    .locals 1",
        "",
        "    const/16 v0, -0x2710",
        "",
        "    return v0",
    ]


def null_body() -> list[str]:
    return [
        "    .locals 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return-object v0",
    ]


def void_body() -> list[str]:
    return [
        "    .locals 0",
        "",
        "    return-void",
    ]


def optional_empty_body() -> list[str]:
    return [
        "    .locals 1",
        "",
        "    invoke-static {}, "
        "Ljava/util/Optional;->empty()Ljava/util/Optional;",
        "",
        "    move-result-object v0",
        "",
        "    return-object v0",
    ]


dar = find_one(
    "com/android/server/knox/dar/DarManagerService.smali"
)

enterprise = find_one(
    "com/android/server/enterprise/"
    "EnterpriseDeviceManagerServiceImpl.smali"
)

persona = find_one(
    "com/android/server/pm/PersonaServiceHelper.smali"
)

lock_settings = find_one(
    "com/android/server/locksettings/LockSettingsService.smali",
    required=False,
)

injector = find_one(
    "com/android/server/locksettings/"
    "LockSettingsService$Injector$1.smali",
    required=False,
)

common_service = find_one(
    "com/android/server/knox/dar/ddar/proxy/"
    "DualDARComnService.smali",
    required=False,
)

# DarManagerService: mesmos valores neutros usados pelo patch original.
rewrite_exact(
    dar,
    "getInnerAuthUserId",
    "I",
    "I",
    invalid_user_body(),
    required=True,
)

rewrite_exact(
    dar,
    "getMainUserId",
    "I",
    "I",
    invalid_user_body(),
    required=True,
)

rewrite_exact(
    dar,
    "getPackageListForDualDarPolicy",
    "Ljava/lang/String;",
    "Ljava/util/List;",
    null_body(),
)

rewrite_exact(
    dar,
    "getPasswordMinimumLengthForInner",
    "",
    "I",
    zero_body(),
)

rewrite_exact(
    dar,
    "isDualDarDoSupported",
    "",
    "Z",
    false_body(),
)

rewrite_exact(
    dar,
    "isInnerAuthRequired",
    "I",
    "Z",
    false_body(),
    required=True,
)

rewrite_exact(
    dar,
    "setDualDarInfo",
    "II",
    "Z",
    false_body(),
    required=True,
)

rewrite_exact(
    dar,
    "setInnerAuthUserId",
    "II",
    "V",
    void_body(),
)

rewrite_exact(
    dar,
    "setMainUserId",
    "II",
    "V",
    void_body(),
)

# PersonaServiceHelper: mantém ABI, mas desativa a funcionalidade.
rewrite_name_and_return(
    persona,
    "getDualDARPolicyService",
    "Ljava/util/Optional;",
    optional_empty_body(),
)

rewrite_name_and_return(
    persona,
    "getDualDARUser",
    "I",
    minus_one_body(),
)

rewrite_name_and_return(
    persona,
    "getDualDARType",
    "I",
    zero_body(),
    required=True,
)

rewrite_name_and_return(
    persona,
    "isDualDAREnabled",
    "Z",
    false_body(),
)

rewrite_name_and_return(
    persona,
    "isPackageAllowlistedForDEAccessForDualDAR",
    "Z",
    true_body(),
)

rewrite_name_and_return(
    persona,
    "verifyPackageForDualDAR",
    "Z",
    true_body(),
)

# Impede o registro dos dois serviços DualDAR no EDM.
enterprise_text = enterprise.read_text(encoding="utf-8")
enterprise_methods = parse_methods(enterprise_text)

create_matches = [
    method
    for method in enterprise_methods
    if method["name"] == "createDeferredServices"
    and method["parameters"] == ""
    and method["return_type"] == "V"
]

if len(create_matches) != 1:
    raise SystemExit(
        "ERRO: createDeferredServices()V não encontrado de forma única"
    )

create_method = create_matches[0]
create_text = str(create_method["text"])
create_lines = create_text.splitlines()

descriptors = (
    "Lcom/android/server/knox/dar/ddar/proxy/"
    "DualDARComnService;",
    "Lcom/android/server/enterprise/dualdar/"
    "DualDARPolicy;",
)

removed_services = []

for descriptor in descriptors:
    while True:
        instance_index = next(
            (
                index
                for index, line in enumerate(create_lines)
                if "new-instance" in line
                and descriptor in line
            ),
            None,
        )

        if instance_index is None:
            break

        register_match = re.search(
            r"new-instance\s+([vp][0-9]+),",
            create_lines[instance_index],
        )

        if not register_match:
            raise SystemExit(
                f"ERRO: registrador não identificado para {descriptor}"
            )

        register = register_match.group(1)
        end_index = None

        for index in range(
            instance_index,
            min(len(create_lines), instance_index + 30),
        ):
            line = create_lines[index]

            if (
                "->addSystemService(" in line
                and register in line
            ):
                end_index = index
                break

        if end_index is None:
            raise SystemExit(
                f"ERRO: addSystemService não encontrado para {descriptor}"
            )

        removed = create_lines[instance_index:end_index + 1]

        del create_lines[instance_index:end_index + 1]

        removed_services.append(descriptor)

        operations.append(
            "EnterpriseDeviceManagerServiceImpl: "
            f"registro removido para {descriptor}"
        )

new_create_text = "\n".join(create_lines)

if not new_create_text.endswith("\n"):
    new_create_text += "\n"

enterprise_text = (
    enterprise_text[:int(create_method["start"])]
    + new_create_text
    + enterprise_text[int(create_method["end"]):]
)

enterprise.write_text(enterprise_text, encoding="utf-8")
modified_files.add(enterprise)

# Todo gate booleano cujo nome referencia DualDAR retorna false.
for path in root.glob("smali*/**/*.smali"):
    if not path.is_file():
        continue

    def is_dualdar_gate(method):
        name = str(method["name"]).lower()

        return (
            method["return_type"] == "Z"
            and (
                "dualdar" in name
                or "dardual" in name
            )
        )

    rewrite_matching(
        path,
        is_dualdar_gate,
        lambda method: false_body(),
    )

# Métodos específicos do LockSettings, caso existam nesta versão.
for path in (lock_settings, injector):
    if path is None:
        continue

    rewrite_name_and_return(
        path,
        "isDualDarAuthUserId",
        "Z",
        false_body(),
    )

    rewrite_name_and_return(
        path,
        "isDualDARUser",
        "Z",
        false_body(),
    )

# Serviço comum não deve alterar estado de unlock.
if common_service is not None:
    rewrite_name_and_return(
        common_service,
        "setDeviceUnlockedForUserIfUnsecured",
        "V",
        void_body(),
    )

# Limpa resíduos deixados pelo GNU patch.
for pattern in ("*.rej", "*.orig"):
    for artifact in root.rglob(pattern):
        artifact.unlink()

# Validação.
enterprise_final = enterprise.read_text(encoding="utf-8")

create_final = [
    method
    for method in parse_methods(enterprise_final)
    if method["name"] == "createDeferredServices"
    and method["parameters"] == ""
    and method["return_type"] == "V"
][0]

for descriptor in descriptors:
    if descriptor in str(create_final["text"]):
        raise SystemExit(
            "ERRO: createDeferredServices ainda referencia "
            + descriptor
        )

dar_final = dar.read_text(encoding="utf-8")


def require_stub(
    path: Path,
    name: str,
    parameters: str,
    return_type: str,
    required_fragments: tuple[str, ...],
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
        raise SystemExit(
            f"ERRO: validação encontrou {len(matches)} métodos "
            f"{name}({parameters}){return_type}"
        )

    body = str(matches[0]["text"])

    for fragment in required_fragments:
        if fragment not in body:
            raise SystemExit(
                f"ERRO: {name} não contém: {fragment}"
            )


require_stub(
    dar,
    "getInnerAuthUserId",
    "I",
    "I",
    ("const/16 v0, -0x2710", "return v0"),
)

require_stub(
    dar,
    "isInnerAuthRequired",
    "I",
    "Z",
    ("const/4 v0, 0x0", "return v0"),
)

require_stub(
    dar,
    "setDualDarInfo",
    "II",
    "Z",
    ("const/4 v0, 0x0", "return v0"),
)

remaining_gates = []

for path in root.glob("smali*/**/*.smali"):
    if not path.is_file():
        continue

    for method in parse_methods(path.read_text(encoding="utf-8")):
        declaration = str(method["declaration"])

        # Métodos abstract/native são somente contratos de API/Binder.
        # Eles não possuem corpo smali e não podem retornar false
        # diretamente. As implementações concretas continuam sendo
        # neutralizadas e validadas.
        if (
            " abstract " in f" {declaration} "
            or " native " in f" {declaration} "
        ):
            continue

        name = str(method["name"]).lower()

        if (
            method["return_type"] == "Z"
            and (
                "dualdar" in name
                or "dardual" in name
            )
        ):
            body = str(method["text"])

            if (
                "const/4 v0, 0x0" not in body
                or "return v0" not in body
            ):
                remaining_gates.append(
                    f"{path}: {method['declaration']}"
                )

if remaining_gates:
    raise SystemExit(
        "ERRO: gates DualDAR não neutralizados:\n"
        + "\n".join(remaining_gates)
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

hashes = {}

for path in sorted(modified_files):
    relative = str(path.relative_to(root))

    hashes[relative] = hashlib.sha256(
        path.read_bytes()
    ).hexdigest()

audit = {
    "status": "semantic_patch_validated",
    "services_dir": str(root),
    "removed_service_registrations": removed_services,
    "operations": operations,
    "modified_files": hashes,
    "validations": {
        "dualdar_common_service_not_registered": True,
        "dualdar_policy_not_registered": True,
        "dar_inner_auth_disabled": True,
        "dar_set_info_disabled": True,
        "all_boolean_dualdar_gates_false": True,
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

print("=== Nuke Knox DualDAR services.jar ===")

for operation in operations:
    print("  -", operation)

print()
print("VALIDADO: DualDARComnService não é registrado")
print("VALIDADO: DualDARPolicy não é registrado")
print("VALIDADO: isInnerAuthRequired retorna false")
print("VALIDADO: setDualDarInfo retorna false")
print("VALIDADO: todos os gates booleanos DualDAR retornam false")
print("VALIDADO: nenhum .rej ou .orig permanece")

print()
for relative, digest in hashes.items():
    print(f"SHA-256 {relative}: {digest}")

print()
print(f"AUDIT: {audit_file}")
PY

echo "OK: patch semântico DualDAR do services.jar concluído"
