#!/usr/bin/env python3
from pathlib import Path
import hashlib
import re
import sys


def die(msg: str, code: int = 1) -> None:
    print(f"ERRO: {msg}", file=sys.stderr)
    raise SystemExit(code)


def main() -> None:
    if len(sys.argv) != 2:
        die("uso: apply_settingsprovider_ead_android17.py <SettingsProvider.apk decompilado>")

    decoded = Path(sys.argv[1]).resolve()
    if not decoded.is_dir():
        die(f"SettingsProvider decompilado não encontrado: {decoded}")

    matches = [
        p for p in decoded.rglob("SecUpgradeController.smali")
        if p.as_posix().endswith("com/android/providers/settings/SecUpgradeController.smali")
    ]
    if len(matches) != 1:
        die(f"esperado um SecUpgradeController.smali; encontrados {len(matches)}")

    target = matches[0]
    text = target.read_text(encoding="utf-8", errors="strict")

    methods = []
    for m in re.finditer(r"^\.method[^\n]*$", text, flags=re.MULTILINE):
        end = text.find("\n.end method", m.end())
        if end < 0:
            continue
        end += len("\n.end method")
        body = text[m.start():end]
        if (
            '"vividness_intensity"' in body
            and "SettingsState;->insertSettingOverrideableByRestoreLocked" in body
        ):
            methods.append((m.start(), end, body))

    if len(methods) != 1:
        die(f"método de inicialização com vividness_intensity encontrado {len(methods)} vezes")

    start, end, method = methods[0]

    if '"ead_enabled"' in method:
        required = [
            'const-string v5, "ead_enabled"',
            'const-string v6, "0"',
            "SettingsState;->insertSettingOverrideableByRestoreLocked",
        ]
        missing = [token for token in required if token not in method]
        if missing:
            die("ead_enabled já existe, mas o bloco está incompleto: " + ", ".join(missing))
        print("SettingsProvider EAD: bloco já aplicado e validado.")
    else:
        lines = method.splitlines(keepends=True)
        vivid = next((i for i, line in enumerate(lines) if '"vividness_intensity"' in line), None)
        if vivid is None:
            die("âncora vividness_intensity não encontrada")

        sem_start = None
        for i in range(vivid, max(-1, vivid - 80), -1):
            if "SemFloatingFeature;->getInstance()" in lines[i]:
                sem_start = i
                break
        if sem_start is None:
            die("início do bloco SemFloatingFeature antes de vividness_intensity não encontrado")

        prior = "".join(lines[max(0, sem_start - 140):sem_start])
        if not re.search(
            r"invoke-virtual/range \{v4 \.\. v9\}, "
            r"Lcom/android/providers/settings/SettingsState;->"
            r"insertSettingOverrideableByRestoreLocked",
            prior,
        ):
            die("v4..v9 não foram validados como registradores do SettingsState no ponto de inserção")

        if ":cond_unica_ead_setting_exists" in method:
            die("label UN1CA EAD já existe sem o bloco ead_enabled completo")

        block = '''    const-string v1, "ead_enabled"\n\n    invoke-virtual {v4, v1}, Lcom/android/providers/settings/SettingsState;->getSettingLocked(Ljava/lang/String;)Lcom/android/providers/settings/SettingsState$Setting;\n\n    move-result-object v1\n\n    invoke-virtual {v1}, Lcom/android/providers/settings/SettingsState$Setting;->isNull()Z\n\n    move-result v1\n\n    if-eqz v1, :cond_unica_ead_setting_exists\n\n    const/4 v8, 0x1\n\n    const-string v9, "android"\n\n    const-string v5, "ead_enabled"\n\n    const-string v6, "0"\n\n    const/4 v7, 0x0\n\n    invoke-virtual/range {v4 .. v9}, Lcom/android/providers/settings/SettingsState;->insertSettingOverrideableByRestoreLocked(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ZLjava/lang/String;)Z\n\n    :cond_unica_ead_setting_exists\n'''
        lines.insert(sem_start, block)
        new_method = "".join(lines)
        text = text[:start] + new_method + text[end:]
        target.write_text(text, encoding="utf-8")
        print("SettingsProvider EAD: default ead_enabled=0 inserido com label próprio.")

    final = target.read_text(encoding="utf-8", errors="strict")
    if final.count('"ead_enabled"') < 2:
        die("validação final não encontrou as duas referências a ead_enabled")
    if len(re.findall(r"^\s*:cond_unica_ead_setting_exists\s*$", final, re.MULTILINE)) != 1:
        die("declaração do label EAD inválida")
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    print(f"SettingsProvider EAD SHA-256: {digest}")


if __name__ == "__main__":
    main()
