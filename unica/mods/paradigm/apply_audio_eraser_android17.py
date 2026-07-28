#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ACTIVE = "->activePlaybacks:Ljava/util/Map;"
SERVER = "->isServerAppList:Z"
KEY = "unica_scpm_allowlist_packages"
CHECK = ":cond_unica_local_audio_eraser_check"
ALLOW = ":cond_unica_local_audio_eraser_allow"
NEXT = ":cond_unica_local_audio_eraser_next"
LOOP = ":goto_unica_local_audio_eraser"

root = Path(sys.argv[1])

if not root.is_dir():
    raise SystemExit("ERRO: SystemUI decompilado não encontrado")

candidates = []

for path in root.rglob("*.smali"):
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue

    if ACTIVE not in text or SERVER not in text:
        continue

    for method_match in re.finditer(
        r"(?ms)^\.method[^\n]*\n.*?^\.end method",
        text,
    ):
        method = method_match.group()
        lines = method.splitlines(True)

        if ACTIVE not in method or SERVER not in method:
            continue

        if KEY in method and CHECK in method and ALLOW in method:
            print("OK: Audio Eraser Android 17 já aplicado")
            raise SystemExit(0)

        for active_index, line in enumerate(lines):
            active = re.match(
                r"(?P<indent>\s*)iget-object\s+"
                r"(?P<map>[vp]\d+),\s*"
                r"(?P<owner>[vp]\d+),.*"
                r"->activePlaybacks:Ljava/util/Map;",
                line,
            )

            if not active:
                continue

            branch_index = None
            branch = None

            for index in range(
                active_index - 1,
                max(-1, active_index - 25),
                -1,
            ):
                match = re.match(
                    r"(?P<indent>\s*)if-eqz\s+"
                    r"(?P<reg>[vp]\d+),\s*"
                    r"(?P<label>:cond_[A-Za-z0-9_$]+)\s*$",
                    lines[index].rstrip("\n"),
                )

                if match:
                    branch_index = index
                    branch = match
                    break

            if branch is None:
                continue

            fallback = branch.group("label")

            fallback_index = next(
                (
                    index
                    for index in range(active_index + 1, len(lines))
                    if lines[index].strip() == fallback
                ),
                None,
            )

            if fallback_index is None:
                continue

            if not any(
                SERVER in current
                for current in lines[
                    fallback_index:
                    min(len(lines), fallback_index + 50)
                ]
            ):
                continue

            package_register = None

            for current in lines[active_index:fallback_index]:
                put = re.search(
                    r"invoke-interface(?:/range)?\s+\{([^}]+)\},\s*"
                    r"Ljava/util/Map;->put",
                    current,
                )

                if not put:
                    continue

                registers = [
                    item.strip()
                    for item in put.group(1).split(",")
                ]

                if (
                    len(registers) >= 2
                    and registers[0] == active.group("map")
                ):
                    package_register = registers[1]
                    break

            if package_register:
                score = (
                    active_index - branch_index
                    + fallback_index - active_index
                )

                candidates.append(
                    (
                        score,
                        path,
                        text,
                        method_match,
                        lines,
                        branch_index,
                        active_index,
                        fallback_index,
                        branch,
                        active,
                        package_register,
                    )
                )

if not candidates:
    raise SystemExit("ERRO: fluxo correto do Audio Eraser não encontrado")

(
    _,
    path,
    text,
    method_match,
    lines,
    branch_index,
    active_index,
    fallback_index,
    branch,
    active,
    package_register,
) = min(candidates, key=lambda item: item[0])

fallback = branch.group("label")
condition_register = branch.group("reg")
owner_register = active.group("owner")
indent = active.group("indent")

lines[branch_index] = (
    f"{branch.group('indent')}if-eqz "
    f"{condition_register}, {CHECK}\n"
)

lines.insert(active_index, f"{indent}{ALLOW}\n")
fallback_index += 1

block = f"""\
{indent}{CHECK}
{indent}iget-object v0, {owner_register}, Lcom/android/systemui/samsung/quicksetting/ui/banner/AudioEraserAudioPlaybackStartable;->context:Landroid/content/Context;
{indent}if-eqz v0, {fallback}
{indent}invoke-virtual {{v0}}, Landroid/content/Context;->getContentResolver()Landroid/content/ContentResolver;
{indent}move-result-object v0
{indent}const-string/jumbo v9, "{KEY}"
{indent}invoke-static {{v0, v9}}, Landroid/provider/Settings$System;->getString(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;
{indent}move-result-object v0
{indent}if-eqz v0, {fallback}
{indent}const-string v9, "\\n"
{indent}invoke-virtual {{v0, v9}}, Ljava/lang/String;->split(Ljava/lang/String;)[Ljava/lang/String;
{indent}move-result-object v0
{indent}const/4 v9, 0x0
{indent}{LOOP}
{indent}array-length v10, v0
{indent}if-ge v9, v10, {fallback}
{indent}aget-object v10, v0, v9
{indent}invoke-virtual {{v10}}, Ljava/lang/String;->trim()Ljava/lang/String;
{indent}move-result-object v10
{indent}invoke-virtual {{v10, {package_register}}}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z
{indent}move-result v10
{indent}if-eqz v10, {NEXT}
{indent}goto {ALLOW}
{indent}{NEXT}
{indent}add-int/lit8 v9, v9, 0x1
{indent}goto {LOOP}
"""

lines.insert(fallback_index, block)

new_method = "".join(lines)

if new_method.count(CHECK) != 2:
    raise SystemExit("ERRO: branch/check inválido")

if new_method.count(ALLOW) != 2:
    raise SystemExit("ERRO: branch/allow inválido")

if KEY not in new_method:
    raise SystemExit("ERRO: chave da allowlist não foi inserida")

result = (
    text[:method_match.start()]
    + new_method
    + text[method_match.end():]
)

path.write_text(result, encoding="utf-8")

print(
    "OK: Audio Eraser Android 17 aplicado; "
    f"fallback={fallback}; pacote={package_register}"
)
