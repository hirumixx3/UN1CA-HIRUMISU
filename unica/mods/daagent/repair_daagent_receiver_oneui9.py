#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path


RECEIVER_SUFFIX = (
    "com/samsung/android/da/daagent/receiver/"
    "DualAppIntentReceiver.smali"
)

PACKAGE_ADDED = "android.intent.action.PACKAGE_ADDED"
PACKAGE_REMOVED = "android.intent.action.PACKAGE_REMOVED"

UPDATE_CALL = (
    "Lcom/samsung/android/da/daagent/utils/DAUtility;"
    "->updateWhitelistAppsInSystemServer"
    "(Landroid/content/Context;)V"
)

HELPER = "unicaHandlePackageChanged"

HELPER_SIGNATURE = (
    "Lcom/samsung/android/da/daagent/receiver/"
    "DualAppIntentReceiver;"
    f"->{HELPER}("
    "Landroid/content/Context;"
    "Landroid/content/Intent;)Z"
)

MARKER = "# UN1CA_ONEUI9_DUALAPP_PACKAGE_EVENTS"


def abort(message: str) -> None:
    raise SystemExit(f"ERRO: {message}")


def find_receiver(root: Path) -> Path:
    matches = [
        path
        for path in root.rglob("DualAppIntentReceiver.smali")
        if path.as_posix().endswith(RECEIVER_SUFFIX)
    ]

    if len(matches) != 1:
        abort(
            "esperava exatamente um DualAppIntentReceiver.smali; "
            f"encontrei {len(matches)}"
        )

    return matches[0]


def method_ranges(
    lines: list[str],
) -> list[tuple[int, int, str]]:
    result: list[tuple[int, int, str]] = []
    start = None
    header = ""

    for index, line in enumerate(lines):
        stripped = line.strip()

        if stripped.startswith(".method"):
            if start is not None:
                abort("estrutura smali contém métodos aninhados")

            start = index
            header = stripped

        elif stripped == ".end method":
            if start is None:
                abort(".end method sem início")

            result.append((start, index, header))
            start = None
            header = ""

    if start is not None:
        abort("método sem .end method")

    return result


def append_helper(lines: list[str]) -> None:
    helper = f'''
.method private static {HELPER}(Landroid/content/Context;Landroid/content/Intent;)Z
    .locals 2

    if-eqz p1, :unica_not_package_event

    invoke-virtual {{p1}}, Landroid/content/Intent;->getAction()Ljava/lang/String;

    move-result-object v0

    const-string v1, "{PACKAGE_ADDED}"

    invoke-virtual {{v1, v0}}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v1

    if-nez v1, :unica_refresh_dualapp_whitelist

    const-string v1, "{PACKAGE_REMOVED}"

    invoke-virtual {{v1, v0}}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v1

    if-eqz v1, :unica_not_package_event

    :unica_refresh_dualapp_whitelist
    invoke-static {{p0}}, {UPDATE_CALL}

    const/4 v0, 0x1

    return v0

    :unica_not_package_event
    const/4 v0, 0x0

    return v0
.end method
'''

    if lines and lines[-1].strip():
        lines.append("\n")

    lines.extend(
        line + "\n"
        for line in helper.strip("\n").splitlines()
    )

    lines.append("\n")


def main() -> None:
    if len(sys.argv) != 2:
        abort(
            "uso: repair_daagent_receiver_oneui9.py "
            "<DAAgent.apk decodificado>"
        )

    root = Path(sys.argv[1])

    if not root.is_dir():
        abort(f"DAAgent decodificado não encontrado: {root}")

    receiver = find_receiver(root)

    lines = receiver.read_text(
        encoding="utf-8",
        errors="strict",
    ).splitlines(keepends=True)

    text = "".join(lines)

    if (
        PACKAGE_ADDED in text
        and PACKAGE_REMOVED in text
        and HELPER_SIGNATURE in text
        and MARKER in text
    ):
        print("OK: tratamento de eventos de pacote já instalado")
        return

    if HELPER_SIGNATURE in text or MARKER in text:
        abort(
            "patch parcial do helper encontrado; "
            "recusando duplicar código"
        )

    on_receive = [
        item
        for item in method_ranges(lines)
        if (
            "onReceive("
            "Landroid/content/Context;"
            "Landroid/content/Intent;)V"
            in item[2]
        )
    ]

    if len(on_receive) != 1:
        abort(
            "esperava exatamente um método onReceive; "
            f"encontrei {len(on_receive)}"
        )

    start, end, header = on_receive[0]

    if " static " in f" {header} ":
        abort("onReceive inesperadamente é estático")

    locals_index = None
    locals_count = None

    for index in range(start + 1, min(end, start + 15)):
        match = re.fullmatch(
            r"\s*\.locals\s+(\d+)\s*",
            lines[index],
        )

        if match:
            locals_index = index
            locals_count = int(match.group(1))
            break

    if locals_index is None or locals_count is None:
        abort(".locals do onReceive não encontrado")

    if locals_count < 1:
        lines[locals_index] = "    .locals 1\n"

    label = ":unica_dualapp_continue"

    if any(line.strip() == label for line in lines):
        abort(f"label {label} já existe")

    insertion = [
        "\n",
        f"    {MARKER}\n",
        "    invoke-static/range {p1 .. p2}, "
        f"{HELPER_SIGNATURE}\n",
        "\n",
        "    move-result v0\n",
        "\n",
        f"    if-eqz v0, {label}\n",
        "\n",
        "    return-void\n",
        "\n",
        f"    {label}\n",
    ]

    lines[locals_index + 1:locals_index + 1] = insertion

    append_helper(lines)

    receiver.write_text(
        "".join(lines),
        encoding="utf-8",
    )

    final = receiver.read_text(
        encoding="utf-8",
        errors="strict",
    )

    checks = {
        "marcador": MARKER in final,
        "PACKAGE_ADDED": PACKAGE_ADDED in final,
        "PACKAGE_REMOVED": PACKAGE_REMOVED in final,
        "chamada do helper": HELPER_SIGNATURE in final,
        "atualização da whitelist": UPDATE_CALL in final,
        "retorno antecipado": (
            f"if-eqz v0, {label}" in final
            and "return-void" in final
        ),
    }

    failures = [
        description
        for description, passed in checks.items()
        if not passed
    ]

    if failures:
        abort(
            "validação do receiver falhou: "
            + "; ".join(failures)
        )

    print(f"OK: receiver corrigido em {receiver}")
    print("OK: PACKAGE_ADDED atualiza a whitelist")
    print("OK: PACKAGE_REMOVED atualiza a whitelist")
    print("OK: tratamento de eventos do Dual Messenger validado")


if __name__ == "__main__":
    main()
