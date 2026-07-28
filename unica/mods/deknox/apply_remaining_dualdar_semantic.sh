#!/usr/bin/env bash

set -euo pipefail

: "${APKTOOL_DIR:?ERRO: APKTOOL_DIR não definido}"

if [ "$#" -ne 3 ]; then
    echo "Uso:"
    echo "$0 <partição> <caminho relativo> <modo>"
    exit 1
fi

PARTITION="$1"
RELATIVE_PATH="$2"
MODE="$3"

case "$MODE" in
    embedded|knoxcore|secsettings)
        ;;
    *)
        echo "ERRO: modo inválido: $MODE"
        exit 1
        ;;
esac

WITHOUT_PARTITION="${RELATIVE_PATH#"$PARTITION"/}"
ARTIFACT_DIR="$APKTOOL_DIR/$PARTITION/$WITHOUT_PARTITION"

AUDIT_ROOT="${WORK_DIR:-${APKTOOL_DIR%/apktool}}"
AUDIT_NAME="$(
    printf '%s' "$RELATIVE_PATH" |
    tr '/.' '__'
)"
AUDIT_FILE="$AUDIT_ROOT/${AUDIT_NAME}-dualdar-audit.json"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "ERRO: artefato decompilado não encontrado:"
    echo "$ARTIFACT_DIR"
    exit 1
fi

mkdir -p "$AUDIT_ROOT"

python3 - \
    "$ARTIFACT_DIR" \
    "$MODE" \
    "$AUDIT_FILE" <<'PY'
from pathlib import Path
import hashlib
import json
import re
import sys

root = Path(sys.argv[1])
mode = sys.argv[2]
audit_file = Path(sys.argv[3])

METHOD_RE = re.compile(
    r"(?ms)^\.method[^\n]*\n.*?^\.end method[ \t]*(?:\n|$)"
)

operations = []
touched = set()


def parse_methods(text):
    result = []

    for match in METHOD_RE.finditer(text):
        body = match.group(0)
        declaration = body.splitlines()[0]

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
                "text": body,
            }
        )

    return result


def find_one(relative, required=True):
    matches = sorted(root.glob(f"smali*/{relative}"))

    if not matches and not required:
        return None

    if len(matches) != 1:
        raise SystemExit(
            f"ERRO: esperava exatamente um {relative}; "
            f"encontrei {len(matches)}:\n"
            + "\n".join(map(str, matches))
        )

    return matches[0]


def build_method(method, body_lines):
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
        raise RuntimeError(
            "Método concreto sem .locals/.registers: "
            + str(method["declaration"])
        )

    # Preserva anotações existentes antes de .locals.
    preamble = old_lines[1:register_index]

    return "\n".join(
        [
            str(method["declaration"]),
            *preamble,
            *body_lines,
            ".end method",
            "",
        ]
    )


def rewrite_methods(path, predicate, body_factory, required=False):
    text = path.read_text(encoding="utf-8")
    replacements = []

    for method in parse_methods(text):
        declaration = str(method["declaration"])

        if (
            " abstract " in f" {declaration} "
            or " native " in f" {declaration} "
        ):
            continue

        if not predicate(method):
            continue

        replacement = build_method(
            method,
            body_factory(method),
        )

        replacements.append(
            (
                int(method["start"]),
                int(method["end"]),
                replacement,
                declaration,
            )
        )

    if required and not replacements:
        raise SystemExit(
            f"ERRO: nenhum método correspondente em {path}"
        )

    changed = False

    for start, end, replacement, declaration in reversed(replacements):
        if text[start:end] != replacement:
            text = text[:start] + replacement + text[end:]
            changed = True

        operations.append(
            f"{path.relative_to(root)}: {declaration}"
        )

    if changed:
        path.write_text(text, encoding="utf-8")
        touched.add(path)

    return len(replacements)


def rewrite_exact(
    path,
    name,
    parameters,
    return_type,
    body,
    required=True,
):
    return rewrite_methods(
        path,
        lambda method: (
            method["name"] == name
            and method["parameters"] == parameters
            and method["return_type"] == return_type
        ),
        lambda method: body,
        required=required,
    )


def rewrite_unique_name_return(
    path,
    name,
    return_type,
    body,
    required=True,
):
    return rewrite_methods(
        path,
        lambda method: (
            method["name"] == name
            and method["return_type"] == return_type
        ),
        lambda method: body,
        required=required,
    )


FALSE_BODY = [
    "    .locals 1",
    "",
    "    const/4 v0, 0x0",
    "",
    "    return v0",
]

NULL_BODY = [
    "    .locals 1",
    "",
    "    const/4 v0, 0x0",
    "",
    "    return-object v0",
]

UNAVAILABLE_BODY = [
    "    .locals 1",
    "",
    "    const/4 v0, 0x4",
    "",
    "    return v0",
]

PREREQUISITE_FAILURE_BODY = [
    "    .locals 1",
    "",
    "    const/4 v0, 0x5",
    "",
    "    return v0",
]


def apply_embedded_knox():
    container = find_one(
        "com/samsung/android/knox/container/"
        "KnoxContainerManager.smali"
    )

    policy = find_one(
        "com/samsung/android/knox/ddar/"
        "DualDARPolicy.smali"
    )

    rewrite_exact(
        container,
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

    rewrite_exact(
        policy,
        "getDualDARVersion",
        "",
        "Ljava/lang/String;",
        NULL_BODY,
    )

    rewrite_exact(
        policy,
        "isDualDarSupportedForManagedDevice",
        "",
        "Z",
        FALSE_BODY,
    )

    return container, policy


validation_files = []

if mode == "knoxcore":
    service = find_one(
        "com/samsung/android/knox/containercore/"
        "provisioning/DualDarStartedService.smali"
    )

    rewrite_unique_name_return(
        service,
        "validatePrerequisiteForDualDar",
        "I",
        PREREQUISITE_FAILURE_BODY,
    )

    validation_files.append(service)

elif mode == "embedded":
    container, policy = apply_embedded_knox()
    validation_files.extend((container, policy))

elif mode == "secsettings":
    container, policy = apply_embedded_knox()
    validation_files.extend((container, policy))

    # Todos os gates concretos cujo próprio nome identifica DualDAR.
    for path in sorted(root.glob("smali*/**/*.smali")):
        if not path.is_file():
            continue

        rewrite_methods(
            path,
            lambda method: (
                method["return_type"] == "Z"
                and (
                    "dualdar" in str(method["name"]).lower()
                    or "dardual" in str(method["name"]).lower()
                )
            ),
            lambda method: FALSE_BODY,
        )

    # Gate central da classe DualDarManager não possui DualDAR no
    # nome do método, portanto é tratado explicitamente.
    managers = sorted(
        root.glob(
            "smali*/com/samsung/android/knox/dar/ddar/"
            "DualDarManager.smali"
        )
    )

    for manager in managers:
        rewrite_exact(
            manager,
            "isOnDeviceOwnerEnabled",
            "",
            "Z",
            FALSE_BODY,
            required=False,
        )

        validation_files.append(manager)

    # Esconde o controlador de lockscreen DualDAR.
    controller = find_one(
        "com/samsung/android/settings/lockscreen/controller/"
        "DualDarDoScreenLockTypePreferenceController.smali",
        required=False,
    )

    if controller is not None:
        rewrite_exact(
            controller,
            "getAvailabilityStatus",
            "",
            "I",
            UNAVAILABLE_BODY,
        )

        validation_files.append(controller)

# Remove resíduos produzidos por tentativas parciais do GNU patch.
for pattern in ("*.rej", "*.orig"):
    for artifact in root.rglob(pattern):
        artifact.unlink()


def exact_method(path, name, parameters, return_type):
    matches = [
        method
        for method in parse_methods(
            path.read_text(encoding="utf-8")
        )
        if method["name"] == name
        and method["parameters"] == parameters
        and method["return_type"] == return_type
    ]

    if len(matches) != 1:
        raise SystemExit(
            f"ERRO: validação encontrou {len(matches)} métodos "
            f"{name}({parameters}){return_type} em {path}"
        )

    return str(matches[0]["text"])


if mode in ("embedded", "secsettings"):
    container = find_one(
        "com/samsung/android/knox/container/"
        "KnoxContainerManager.smali"
    )

    policy = find_one(
        "com/samsung/android/knox/ddar/"
        "DualDARPolicy.smali"
    )

    get_policy = exact_method(
        container,
        "getDualDARPolicy",
        "",
        "Lcom/samsung/android/knox/ddar/DualDARPolicy;",
    )

    get_version = exact_method(
        policy,
        "getDualDARVersion",
        "",
        "Ljava/lang/String;",
    )

    supported = exact_method(
        policy,
        "isDualDarSupportedForManagedDevice",
        "",
        "Z",
    )

    if "new-instance" in get_policy:
        raise SystemExit(
            "ERRO: getDualDARPolicy ainda instancia DualDARPolicy"
        )

    if (
        "const/4 v0, 0x0" not in get_version
        or "return-object v0" not in get_version
    ):
        raise SystemExit(
            "ERRO: getDualDARVersion não retorna null"
        )

    if (
        "const/4 v0, 0x0" not in supported
        or "return v0" not in supported
    ):
        raise SystemExit(
            "ERRO: suporte DualDAR ainda retorna true"
        )

if mode == "knoxcore":
    service = validation_files[0]

    methods = [
        method
        for method in parse_methods(
            service.read_text(encoding="utf-8")
        )
        if method["name"] == "validatePrerequisiteForDualDar"
        and method["return_type"] == "I"
    ]

    if len(methods) != 1:
        raise SystemExit(
            "ERRO: validatePrerequisiteForDualDar não é único"
        )

    body = str(methods[0]["text"])

    if (
        "const/4 v0, 0x5" not in body
        or "return v0" not in body
    ):
        raise SystemExit(
            "ERRO: validatePrerequisiteForDualDar "
            "não retorna erro 5"
        )

if mode == "secsettings":
    invalid_gates = []

    for path in sorted(root.glob("smali*/**/*.smali")):
        if not path.is_file():
            continue

        for method in parse_methods(
            path.read_text(encoding="utf-8")
        ):
            declaration = str(method["declaration"])

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
                    invalid_gates.append(
                        f"{path}: {declaration}"
                    )

    if invalid_gates:
        raise SystemExit(
            "ERRO: gates DualDAR restantes:\n"
            + "\n".join(invalid_gates)
        )

    controller = find_one(
        "com/samsung/android/settings/lockscreen/controller/"
        "DualDarDoScreenLockTypePreferenceController.smali",
        required=False,
    )

    if controller is not None:
        availability = exact_method(
            controller,
            "getAvailabilityStatus",
            "",
            "I",
        )

        if (
            "const/4 v0, 0x4" not in availability
            or "return v0" not in availability
        ):
            raise SystemExit(
                "ERRO: controlador DualDAR ainda está disponível"
            )

rejects = sorted(
    [
        *root.rglob("*.rej"),
        *root.rglob("*.orig"),
    ]
)

if rejects:
    raise SystemExit(
        "ERRO: rejeitos restantes:\n"
        + "\n".join(map(str, rejects))
    )

hashes = {}

files_to_hash = set(validation_files)
files_to_hash.update(touched)

for path in sorted(files_to_hash):
    hashes[str(path.relative_to(root))] = hashlib.sha256(
        path.read_bytes()
    ).hexdigest()

audit = {
    "status": "semantic_patch_validated",
    "mode": mode,
    "artifact": str(root),
    "operations": operations,
    "files": hashes,
    "validations": {
        "dualdar_disabled": True,
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

print(f"=== DualDAR semântico: {root.name} ===")

for operation in operations:
    print("  -", operation)

if mode == "knoxcore":
    print(
        "VALIDADO: validatePrerequisiteForDualDar "
        "retorna erro 5"
    )
else:
    print("VALIDADO: getDualDARPolicy não instancia a política")
    print("VALIDADO: getDualDARVersion retorna null")
    print("VALIDADO: suporte DualDAR retorna false")

if mode == "secsettings":
    print("VALIDADO: gates DualDAR do SecSettings retornam false")
    print("VALIDADO: controlador de lockscreen está indisponível")

print("VALIDADO: nenhum .rej ou .orig permanece")

for relative, digest in hashes.items():
    print(f"SHA-256 {relative}: {digest}")

print(f"AUDIT: {audit_file}")
PY
