#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path


FEATURE = "CscFeature_Common_SupportZProjectFunctionInGlobal"

GET_INSTANCE = (
    "Lcom/samsung/android/feature/SemCscFeature;"
    "->getInstance()"
    "Lcom/samsung/android/feature/SemCscFeature;"
)

GET_BOOLEAN = (
    "Lcom/samsung/android/feature/SemCscFeature;"
    "->getBoolean(Ljava/lang/String;Z)Z"
)

GET_NETWORK_SPEED = (
    "Landroid/provider/Settings$System;"
    "->getInt("
    "Landroid/content/ContentResolver;"
    "Ljava/lang/String;I)I"
)


def abort(message: str) -> None:
    raise SystemExit(f"ERRO: {message}")


def find_one(root: Path, relative_suffix: str) -> Path:
    matches = [
        path
        for path in root.rglob(Path(relative_suffix).name)
        if path.as_posix().endswith(relative_suffix)
    ]

    if len(matches) != 1:
        abort(
            f"esperava uma classe terminando em "
            f"{relative_suffix}; encontrei {len(matches)}"
        )

    return matches[0]


def meaningful(line: str) -> bool:
    stripped = line.strip()

    return bool(
        stripped
        and not stripped.startswith("#")
        and not stripped.startswith(".line")
        and not stripped.startswith(".local")
    )


def patch_feature_checks(
    path: Path,
    expected_count: int,
) -> int:
    lines = path.read_text(
        encoding="utf-8",
        errors="strict",
    ).splitlines(keepends=True)

    feature_indexes = [
        index
        for index, line in enumerate(lines)
        if FEATURE in line
    ]

    if not feature_indexes:
        if FEATURE not in "".join(lines):
            print(f"OK: verificações CSC já removidas de {path}")
            return 0

    if len(feature_indexes) != expected_count:
        abort(
            f"{path}: esperava {expected_count} ocorrência(s) "
            f"de {FEATURE}; encontrei {len(feature_indexes)}"
        )

    replacements = 0

    for feature_index in reversed(feature_indexes):
        block_start = None

        for index in range(
            feature_index - 1,
            max(-1, feature_index - 15),
            -1,
        ):
            instruction = lines[index].strip()

            if instruction.startswith(":"):
                break

            if GET_INSTANCE in instruction:
                block_start = index
                break

        if block_start is None:
            abort(
                f"{path}: SemCscFeature.getInstance() "
                f"não encontrado antes da linha "
                f"{feature_index + 1}"
            )

        get_boolean_index = None

        for index in range(
            feature_index + 1,
            min(len(lines), feature_index + 15),
        ):
            instruction = lines[index].strip()

            if instruction.startswith(":"):
                break

            if GET_BOOLEAN in instruction:
                get_boolean_index = index
                break

        if get_boolean_index is None:
            abort(
                f"{path}: SemCscFeature.getBoolean() "
                "não encontrado"
            )

        move_result_index = None
        result_register = None

        for index in range(
            get_boolean_index + 1,
            min(len(lines), get_boolean_index + 8),
        ):
            instruction = lines[index].strip()

            if not meaningful(lines[index]):
                continue

            match = re.fullmatch(
                r"move-result(?:/from16)?\s+([vp]\d+)",
                instruction,
            )

            if not match:
                abort(
                    f"{path}: instrução inesperada após "
                    f"getBoolean(): {instruction}"
                )

            move_result_index = index
            result_register = match.group(1)
            break

        if move_result_index is None or result_register is None:
            abort(f"{path}: move-result do getBoolean ausente")

        block = "".join(
            lines[block_start:move_result_index + 1]
        )

        if FEATURE not in block or GET_BOOLEAN not in block:
            abort(f"{path}: bloco CSC identificado incorretamente")

        if any(
            line.strip().startswith(":")
            for line in lines[block_start:move_result_index + 1]
        ):
            abort(f"{path}: label encontrada dentro do bloco CSC")

        indent = lines[block_start][
            :len(lines[block_start])
            - len(lines[block_start].lstrip())
        ]

        lines[block_start:move_result_index + 1] = [
            f"{indent}const/4 {result_register}, 0x1\n"
        ]

        replacements += 1

    result = "".join(lines)

    if FEATURE in result:
        abort(f"{path}: a feature CSC antiga permaneceu")

    path.write_text(result, encoding="utf-8")

    print(
        f"OK: {replacements} verificação(ões) CSC "
        f"forçada(s) para true em {path}"
    )

    return replacements


def initialize_network_speed_default(path: Path) -> int:
    lines = path.read_text(
        encoding="utf-8",
        errors="strict",
    ).splitlines(keepends=True)

    insertions = 0

    key_indexes = [
        index
        for index, line in enumerate(lines)
        if re.search(
            r'const-string\s+([vp]\d+),\s*"network_speed"',
            line.strip(),
        )
    ]

    for key_index in reversed(key_indexes):
        key_match = re.search(
            r'const-string\s+([vp]\d+),\s*"network_speed"',
            lines[key_index].strip(),
        )

        if key_match is None:
            continue

        key_register = key_match.group(1)
        invoke_index = None
        invoke_registers: list[str] = []

        for index in range(
            key_index + 1,
            min(len(lines), key_index + 20),
        ):
            instruction = lines[index].strip()

            if GET_NETWORK_SPEED not in instruction:
                continue

            register_match = re.search(
                r"\{([^}]*)\}",
                instruction,
            )

            if register_match is None:
                abort(
                    f"{path}: registradores de Settings.getInt "
                    "não reconhecidos"
                )

            invoke_registers = [
                register.strip()
                for register in register_match.group(1).split(",")
                if register.strip()
            ]

            invoke_index = index
            break

        if invoke_index is None:
            continue

        if len(invoke_registers) != 3:
            abort(
                f"{path}: Settings.getInt deveria receber três "
                f"registradores; recebeu {len(invoke_registers)}"
            )

        if invoke_registers[1] != key_register:
            abort(
                f"{path}: o registrador da chave network_speed "
                "não corresponde ao getInt"
            )

        default_register = invoke_registers[2]

        assignment_pattern = re.compile(
            rf"^(?:const(?:/4|/16)?|move(?:/from16)?|"
            rf"move-result(?:/from16)?)\s+"
            rf"{re.escape(default_register)}(?:,|\s|$)"
        )

        initialized = any(
            assignment_pattern.search(lines[index].strip())
            for index in range(key_index + 1, invoke_index)
        )

        if initialized:
            continue

        indent = lines[invoke_index][
            :len(lines[invoke_index])
            - len(lines[invoke_index].lstrip())
        ]

        lines[invoke_index:invoke_index] = [
            f"{indent}const/4 {default_register}, 0x0\n",
            "\n",
        ]

        insertions += 1

    path.write_text(
        "".join(lines),
        encoding="utf-8",
    )

    return insertions


def validate(root: Path, paths: list[Path]) -> None:
    for path in paths:
        text = path.read_text(
            encoding="utf-8",
            errors="strict",
        )

        if FEATURE in text:
            abort(f"feature CSC antiga ainda existe em {path}")

    status_text = paths[1].read_text(
        encoding="utf-8",
        errors="strict",
    )

    if (
        "StatusBarNetworkSpeedController;"
        "->SUPPORT_NETWORK_SPEED:Z"
        not in status_text
    ):
        abort("campo SUPPORT_NETWORK_SPEED não encontrado")

    notifications_text = paths[2].read_text(
        encoding="utf-8",
        errors="strict",
    )

    if '"network_speed"' not in notifications_text:
        abort("chave network_speed não encontrada")

    rejects = list(root.rglob("*.rej"))

    if rejects:
        abort(
            "arquivos .rej restantes:\n"
            + "\n".join(str(path) for path in rejects)
        )

    print("OK: mod de velocidade de rede completamente validado")


def main() -> None:
    if len(sys.argv) != 2:
        abort(
            "uso: patch_network_speed_oneui9.py "
            "<SecSettings.apk decodificado>"
        )

    root = Path(sys.argv[1])

    if not root.is_dir():
        abort(f"diretório não encontrado: {root}")

    configure = find_one(
        root,
        "com/samsung/android/settings/notification/"
        "ConfigureNotificationMoreSettings$1.smali",
    )

    controller = find_one(
        root,
        "com/samsung/android/settings/notification/"
        "StatusBarNetworkSpeedController.smali",
    )

    notifications = find_one(
        root,
        "com/samsung/android/settings/eternal/provider/items/"
        "NotificationsItem.smali",
    )

    print(f"ConfigureNotificationMoreSettings: {configure}")
    print(f"StatusBarNetworkSpeedController: {controller}")
    print(f"NotificationsItem: {notifications}")

    patch_feature_checks(configure, 1)
    patch_feature_checks(controller, 1)
    patch_feature_checks(notifications, 2)

    inserted = initialize_network_speed_default(
        notifications
    )

    print(
        "OK: inicializações do valor padrão network_speed "
        f"adicionadas: {inserted}"
    )

    for reject in root.rglob("*.rej"):
        reject.unlink()

    validate(
        root,
        [configure, controller, notifications],
    )


if __name__ == "__main__":
    main()
