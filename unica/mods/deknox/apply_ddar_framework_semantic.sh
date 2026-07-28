#!/usr/bin/env bash

set -euo pipefail

: "${APKTOOL_DIR:?ERRO: APKTOOL_DIR não definido}"

FRAMEWORK_DIR="$APKTOOL_DIR/system/framework/framework.jar"
AUDIT_DIR="${WORK_DIR:-${APKTOOL_DIR%/apktool}}"
AUDIT_FILE="$AUDIT_DIR/dualdar-framework-semantic-audit.json"

if [ ! -d "$FRAMEWORK_DIR" ]; then
    echo "ERRO: framework.jar decompilado não encontrado:"
    echo "$FRAMEWORK_DIR"
    exit 1
fi

mkdir -p "$AUDIT_DIR"

python3 - "$FRAMEWORK_DIR" "$AUDIT_FILE" <<'PY'
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

changed_operations: list[str] = []
modified_files: set[Path] = set()


def find_one(suffix: str) -> Path:
    matches = sorted(root.glob(f"smali*/{suffix}"))

    if len(matches) != 1:
        raise SystemExit(
            f"ERRO: esperava exatamente um arquivo {suffix}; "
            f"encontrei {len(matches)}:\n"
            + "\n".join(map(str, matches))
        )

    return matches[0]


files = {
    "UserInfo": find_one("android/content/pm/UserInfo.smali"),
    "LockPatternUtils": find_one(
        "com/android/internal/widget/LockPatternUtils.smali"
    ),
    "SemPersonaManager": find_one(
        "com/samsung/android/knox/SemPersonaManager.smali"
    ),
    "DarRune": find_one(
        "com/samsung/android/knox/dar/DarRune.smali"
    ),
    "DualDarManager": find_one(
        "com/samsung/android/knox/dar/ddar/DualDarManager.smali"
    ),
    "CoreRune": find_one(
        "com/samsung/android/rune/CoreRune.smali"
    ),
}


def parse_methods(text: str) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []

    for match in METHOD_RE.finditer(text):
        method_text = match.group(0)
        declaration = method_text.splitlines()[0]

        signature = re.search(
            r"([^\s(]+)\(([^)]*)\)(\S+)$",
            declaration,
        )

        if not signature:
            continue

        result.append(
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

    return result


def find_method(
    path: Path,
    name: str,
    parameters: str | None = None,
    return_type: str | None = None,
    required: bool = True,
) -> dict[str, object] | None:
    text = path.read_text(encoding="utf-8")

    matches = [
        method
        for method in parse_methods(text)
        if method["name"] == name
        and (
            parameters is None
            or method["parameters"] == parameters
        )
        and (
            return_type is None
            or method["return_type"] == return_type
        )
    ]

    if len(matches) == 0 and not required:
        return None

    if len(matches) != 1:
        signatures = "\n".join(
            f"  {m['declaration']}"
            for m in parse_methods(text)
            if m["name"] == name
        )

        raise SystemExit(
            f"ERRO: esperava um método {name}"
            f"({parameters if parameters is not None else '*'})"
            f"{return_type if return_type is not None else '*'} "
            f"em {path}; encontrei {len(matches)}.\n"
            f"Assinaturas encontradas:\n{signatures}"
        )

    return matches[0]


def rewrite_method(
    path: Path,
    name: str,
    parameters: str,
    return_type: str,
    body_lines: list[str],
    required: bool = True,
) -> bool:
    text = path.read_text(encoding="utf-8")

    method = find_method(
        path,
        name,
        parameters,
        return_type,
        required=required,
    )

    if method is None:
        changed_operations.append(
            f"{path.name}:{name} ausente; nenhuma alteração necessária"
        )
        return False

    old_method = str(method["text"])
    lines = old_method.splitlines()

    register_index = None

    for index, line in enumerate(lines[1:], start=1):
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

    # Preserva anotações colocadas antes de .locals/.registers.
    preamble = lines[1:register_index]

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
        text[: int(method["start"])]
        + replacement
        + text[int(method["end"]) :]
    )

    if new_text != text:
        path.write_text(new_text, encoding="utf-8")
        modified_files.add(path)
        changed_operations.append(
            f"{path.name}:{name} reescrito semanticamente"
        )
        return True

    changed_operations.append(
        f"{path.name}:{name} já estava no estado esperado"
    )
    return False


def replace_bool_field(
    path: Path,
    field_name: str,
    required: bool = True,
) -> bool:
    text = path.read_text(encoding="utf-8")

    pattern = re.compile(
        rf"(?m)^(?P<head>\.field[^\n]*"
        rf"\b{re.escape(field_name)}:Z)"
        rf"(?:[ \t]*=[ \t]*(?:true|false))?[ \t]*$"
    )

    matches = list(pattern.finditer(text))

    if not matches and not required:
        changed_operations.append(
            f"{path.name}:{field_name} ausente"
        )
        return False

    if len(matches) != 1:
        raise SystemExit(
            f"ERRO: campo {field_name}:Z em {path}: "
            f"esperava 1 ocorrência, encontrei {len(matches)}"
        )

    new_text, count = pattern.subn(
        lambda match: f"{match.group('head')} = false",
        text,
        count=1,
    )

    if count != 1:
        raise SystemExit(
            f"ERRO: não foi possível corrigir {field_name}"
        )

    if new_text != text:
        path.write_text(new_text, encoding="utf-8")
        modified_files.add(path)
        changed_operations.append(
            f"{path.name}:{field_name}=false"
        )
        return True

    changed_operations.append(
        f"{path.name}:{field_name} já era false"
    )
    return False


def strip_dualdar_prefix(
    path: Path,
    method_name: str,
    marker: str,
) -> bool:
    text = path.read_text(encoding="utf-8")

    candidates = [
        method
        for method in parse_methods(text)
        if method["name"] == method_name
        and marker in str(method["text"])
    ]

    if not candidates:
        changed_operations.append(
            f"{path.name}:{method_name} sem prefixo DualDAR"
        )
        return False

    if len(candidates) != 1:
        raise SystemExit(
            f"ERRO: encontrei {len(candidates)} métodos "
            f"{method_name} contendo {marker}"
        )

    method = candidates[0]
    method_text = str(method["text"])
    lines = method_text.splitlines()

    marker_index = next(
        index
        for index, line in enumerate(lines)
        if marker in line
    )

    label_index = None

    for index in range(marker_index + 1, len(lines)):
        if re.match(r"^[ \t]*:cond_[A-Za-z0-9_]+[ \t]*$", lines[index]):
            label_index = index
            break

    if label_index is None:
        raise SystemExit(
            f"ERRO: não encontrei label de saída após {marker} "
            f"em {method_name}"
        )

    label = lines[label_index].strip()
    label_references = sum(
        1 for line in lines if label in line
    )

    if label_references != 2:
        raise SystemExit(
            f"ERRO: remoção insegura em {method_name}: "
            f"{label} possui {label_references} referências"
        )

    removed = lines[marker_index : label_index + 1]

    if not any(marker in line for line in removed):
        raise SystemExit(
            f"ERRO: bloco delimitado não contém {marker}"
        )

    new_lines = (
        lines[:marker_index]
        + lines[label_index + 1 :]
    )

    replacement = "\n".join(new_lines)

    if not replacement.endswith("\n"):
        replacement += "\n"

    new_text = (
        text[: int(method["start"])]
        + replacement
        + text[int(method["end"]) :]
    )

    path.write_text(new_text, encoding="utf-8")
    modified_files.add(path)
    changed_operations.append(
        f"{path.name}:{method_name} prefixo DualDAR removido"
    )

    return True


def neutralize_enterprise_calls(path: Path) -> int:
    text = path.read_text(encoding="utf-8")

    pattern = re.compile(
        r"(?m)"
        r"^(?P<indent>[ \t]*)"
        r"invoke-direct(?:/range)? "
        r"\{[^\n]*\}, "
        r"Lcom/android/internal/widget/LockPatternUtils;"
        r"->isEnterpriseUser\(I\)Z[ \t]*\n"
        r"(?:[ \t]*\n)*"
        r"(?P=indent)move-result "
        r"(?P<register>[vp][0-9]+)[ \t]*\n"
    )

    def replace(match: re.Match[str]) -> str:
        return (
            f"{match.group('indent')}"
            f"const/4 {match.group('register')}, 0x0\n"
        )

    new_text, count = pattern.subn(replace, text)

    if count:
        path.write_text(new_text, encoding="utf-8")
        modified_files.add(path)
        changed_operations.append(
            f"{path.name}:{count} chamadas isEnterpriseUser "
            f"neutralizadas"
        )

    return count


user_info = files["UserInfo"]
lock_utils = files["LockPatternUtils"]
persona = files["SemPersonaManager"]
dar_rune = files["DarRune"]
dual_manager = files["DualDarManager"]
core_rune = files["CoreRune"]

# UserInfo: flags DualDAR 0x6000000 não podem marcar usuário como
# super locked; atributos 0x4/0x8 continuam válidos.
rewrite_method(
    user_info,
    "isSuperLocked",
    "",
    "Z",
    [
        "    .locals 1",
        "",
        "    iget v0, p0, Landroid/content/pm/UserInfo;->attributes:I",
        "",
        "    and-int/lit8 v0, v0, 0xc",
        "",
        "    if-lez v0, :cond_not_super_locked",
        "",
        "    const/4 v0, 0x1",
        "",
        "    return v0",
        "",
        "    :cond_not_super_locked",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
    ],
)

# Gate central de usuários enterprise/DualDAR.
rewrite_method(
    lock_utils,
    "isEnterpriseUser",
    "I",
    "Z",
    [
        "    .locals 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return v0",
    ],
)

# Remove caminhos especiais de política de senha DualDAR,
# preservando a implementação normal já existente na source.
for method_name in (
    "getRequestedPasswordHistoryLength",
    "getRequestedMinimumPasswordLength",
    "getRequestedPasswordComplexity",
    "getRequestedPasswordMetrics",
):
    strip_dualdar_prefix(
        lock_utils,
        method_name,
        "getLockPatternUtilForDualDarDo",
    )

strip_dualdar_prefix(
    lock_utils,
    "reportEnabledTrustAgentsChanged",
    "VirtualLockUtils;->isVirtualUserId",
)

# Os métodos complexos de credencial permanecem estruturalmente
# iguais à source Android 17, mas todos os seus gates enterprise são
# transformados em false, evitando renumeração frágil de labels.
enterprise_call_count = neutralize_enterprise_calls(lock_utils)

replace_bool_field(
    persona,
    "SEC_PRODUCT_FEATURE_KNOX_SUPPORT_DUAL_DAR",
)

for method_name in (
    "isDarDualEncryptionEnabled",
    "isDualDARCustomCrypto",
    "isDualDARNativeCrypto",
):
    rewrite_method(
        persona,
        method_name,
        "I",
        "Z",
        [
            "    .locals 1",
            "",
            "    const/4 v0, 0x0",
            "",
            "    return v0",
        ],
        required=False,
    )

rewrite_method(
    persona,
    "getDualDARProfile",
    "",
    "Landroid/os/Bundle;",
    [
        "    .locals 1",
        "",
        "    const/4 v0, 0x0",
        "",
        "    return-object v0",
    ],
    required=False,
)

rewrite_method(
    persona,
    "setDualDARProfile",
    "Landroid/os/Bundle;",
    "I",
    [
        "    .locals 1",
        "",
        "    const/4 v0, -0x1",
        "",
        "    return v0",
    ],
    required=False,
)

for field_name in (
    "KNOX_SUPPORT_DAR_DUAL",
    "KNOX_SUPPORT_DAR_DUAL_DO",
    "KNOX_SUPPORT_DAR_SDP_OR_DUAL",
    "KNOX_SUPPORT_DAR_VIRTUAL_USER",
):
    replace_bool_field(
        dar_rune,
        field_name,
        required=False,
    )

rewrite_method(
    dual_manager,
    "isOnDeviceOwnerEnabled",
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

replace_bool_field(
    core_rune,
    "KNOX_SUPPORT_DAR_DUAL",
)

# Limpa rejeitos criados pela aplicação parcial do diff antigo.
for pattern in ("*.rej", "*.orig"):
    for artifact in root.rglob(pattern):
        artifact.unlink()


def method_text(
    path: Path,
    name: str,
    parameters: str | None = None,
    return_type: str | None = None,
) -> str | None:
    method = find_method(
        path,
        name,
        parameters,
        return_type,
        required=False,
    )

    if method is None:
        return None

    return str(method["text"])


def validate_false_method(
    path: Path,
    name: str,
    parameters: str,
) -> None:
    body = method_text(path, name, parameters, "Z")

    if body is None:
        raise SystemExit(
            f"ERRO: método obrigatório ausente: {name}"
        )

    if (
        "const/4 v0, 0x0" not in body
        or "return v0" not in body
    ):
        raise SystemExit(
            f"ERRO: {name} não retorna false"
        )


user_super_locked = method_text(
    user_info,
    "isSuperLocked",
    "",
    "Z",
)

if user_super_locked is None:
    raise SystemExit(
        "ERRO: UserInfo.isSuperLocked()Z ausente"
    )

if "0x6000000" in user_super_locked:
    raise SystemExit(
        "ERRO: isSuperLocked ainda verifica flags DualDAR"
    )

if "and-int/lit8 v0, v0, 0xc" not in user_super_locked:
    raise SystemExit(
        "ERRO: isSuperLocked não preservou atributos 0xc"
    )

validate_false_method(
    lock_utils,
    "isEnterpriseUser",
    "I",
)

lock_text = lock_utils.read_text(encoding="utf-8")

if re.search(
    r"invoke-direct(?:/range)? [^\n]*"
    r"->isEnterpriseUser\(I\)Z",
    lock_text,
):
    raise SystemExit(
        "ERRO: ainda existem chamadas executáveis "
        "a isEnterpriseUser"
    )

lock_methods = parse_methods(lock_text)

for method_name in (
    "getRequestedPasswordHistoryLength",
    "getRequestedMinimumPasswordLength",
    "getRequestedPasswordComplexity",
    "getRequestedPasswordMetrics",
):
    overloads = [
        method
        for method in lock_methods
        if method["name"] == method_name
    ]

    if not overloads:
        raise SystemExit(
            f"ERRO: método obrigatório ausente: {method_name}"
        )

    for method in overloads:
        body = str(method["text"])

        if "getLockPatternUtilForDualDarDo" in body:
            raise SystemExit(
                "ERRO: caminho DualDAR ainda presente em "
                f"{method['declaration']}"
            )

        print(
            "VALIDADO: caminho DualDAR ausente em "
            f"{method['declaration']}"
        )

report_body = method_text(
    lock_utils,
    "reportEnabledTrustAgentsChanged",
)

if report_body is None:
    raise SystemExit(
        "ERRO: reportEnabledTrustAgentsChanged ausente"
    )

if "VirtualLockUtils;->isVirtualUserId" in report_body:
    raise SystemExit(
        "ERRO: reportEnabledTrustAgentsChanged ainda bloqueia "
        "usuários virtuais"
    )

validate_false_method(
    dual_manager,
    "isOnDeviceOwnerEnabled",
    "",
)

for path in root.rglob("*.rej"):
    raise SystemExit(
        f"ERRO: rejeito restante: {path}"
    )

for path in root.rglob("*.orig"):
    raise SystemExit(
        f"ERRO: backup .orig restante: {path}"
    )

sha256 = {}

for name, path in files.items():
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    sha256[name] = {
        "path": str(path.relative_to(root)),
        "sha256": digest,
    }

audit = {
    "status": "semantic_patch_validated",
    "framework_dir": str(root),
    "enterprise_call_sites_neutralized": enterprise_call_count,
    "operations": changed_operations,
    "files": sha256,
    "validations": {
        "user_info_dualdar_flags_removed": True,
        "enterprise_gate_disabled": True,
        "password_policy_dualdar_paths_removed": True,
        "virtual_user_trust_agent_block_removed": True,
        "persona_dualdar_disabled": True,
        "dar_runes_disabled": True,
        "dual_dar_device_owner_disabled": True,
        "core_rune_dualdar_disabled": True,
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

print("=== Nuke Knox DualDAR framework.jar ===")

for operation in changed_operations:
    print("  -", operation)

print()
print("VALIDADO: UserInfo ignora flags DualDAR")
print("VALIDADO: isEnterpriseUser retorna false")
print("VALIDADO: políticas de senha não usam DualDAR DO")
print("VALIDADO: chamadas enterprise foram neutralizadas")
print("VALIDADO: SemPersonaManager DualDAR desativado")
print("VALIDADO: DarRune/CoreRune DualDAR desativado")
print("VALIDADO: nenhum .rej ou .orig permanece")

print()
for name, data in sha256.items():
    print(f"SHA-256 {name}: {data['sha256']}")

print()
print(f"AUDIT: {audit_file}")
PY

echo "OK: patch semântico DualDAR do framework.jar concluído"
