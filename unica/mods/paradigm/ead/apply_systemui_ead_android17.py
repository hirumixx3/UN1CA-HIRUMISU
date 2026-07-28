#!/usr/bin/env python3
from pathlib import Path
import hashlib
import os
import re
import subprocess
import sys
import tempfile


def die(msg: str, code: int = 1) -> None:
    print(f"ERRO: {msg}", file=sys.stderr)
    raise SystemExit(code)


def locate(decoded: Path, suffix: str) -> Path:
    name = Path(suffix).name
    matches = [p for p in decoded.rglob(name) if p.as_posix().endswith(suffix)]
    if len(matches) != 1:
        die(f"{suffix}: esperado um arquivo; encontrados {len(matches)}")
    return matches[0]


def split_sections(patch: str):
    starts = [m.start() for m in re.finditer(r"^diff --git ", patch, re.MULTILINE)]
    if not starts:
        die("patch SystemUI EAD não contém seções diff")
    sections = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(patch)
        sections.append(patch[start:end])
    return sections


def paths(section: str):
    first = section.splitlines()[0]
    m = re.match(r"diff --git a/(.+) b/(.+)$", first)
    if not m:
        die("cabeçalho diff inválido")
    return m.group(1), m.group(2)


def new_file_content(section: str) -> str:
    lines = []
    in_hunk = False
    for line in section.splitlines(keepends=True):
        if line.startswith("@@ "):
            in_hunk = True
            continue
        if not in_hunk:
            continue
        if line.startswith("+") and not line.startswith("+++"):
            lines.append(line[1:])
        elif line.startswith(" "):
            lines.append(line[1:])
    return "".join(lines)


def replace_path(section: str, old: str, new: str) -> str:
    return section.replace(f"a/{old}", f"a/{new}").replace(f"b/{old}", f"b/{new}")


def appops_ready(path: Path) -> bool:
    text = path.read_text(encoding="utf-8", errors="strict")
    m = re.search(
        r"^\.method[^\n]*\bisUserVisible\(Ljava/lang/String;Ljava/lang/String;\)Z\s*$",
        text,
        re.MULTILINE,
    )
    if not m:
        return False
    end = text.find("\n.end method", m.end())
    if end < 0:
        return False
    body = text[m.start():end]
    return (
        '"com.samsung.android.sead"' in body
        and '"com.samsung.sightcare"' in body
        and body.count("PackageManager;->checkSignatures") >= 2
    )


def validate(decoded: Path) -> None:
    appops = locate(decoded, "com/android/systemui/appops/AppOpsControllerImpl.smali")
    if not appops_ready(appops):
        die("AppOpsControllerImpl não contém as verificações de SEAD e SightCare")

    adapter = locate(decoded, "com/android/systemui/settings/brightness/BrightnessDetailAdapter.smali")
    adapter_text = adapter.read_text(encoding="utf-8", errors="strict")
    if "->quickBrightnessSeadView:Lcom/android/systemui/settings/brightness/QuickBrightnessSeadView;" not in adapter_text:
        die("BrightnessDetailAdapter não contém quickBrightnessSeadView")

    quick = locate(decoded, "com/android/systemui/settings/brightness/QuickBrightnessSeadView.smali")
    quick_text = quick.read_text(encoding="utf-8", errors="strict")
    if '"ead_enabled"' not in quick_text:
        die("QuickBrightnessSeadView não referencia ead_enabled")

    print(f"SystemUI EAD adapter: {adapter.relative_to(decoded)}")
    print(f"SystemUI EAD SHA-256 adapter: {hashlib.sha256(adapter.read_bytes()).hexdigest()}")
    print(f"SystemUI EAD SHA-256 quick view: {hashlib.sha256(quick.read_bytes()).hexdigest()}")


def main() -> None:
    if len(sys.argv) != 3:
        die("uso: apply_systemui_ead_android17.py <SystemUI.apk decompilado> <patch>")
    decoded = Path(sys.argv[1]).resolve()
    patch_file = Path(sys.argv[2]).resolve()
    if not decoded.is_dir() or not patch_file.is_file():
        die("SystemUI decompilado ou patch EAD não encontrado")

    patch = patch_file.read_text(encoding="utf-8", errors="strict")
    selected = []

    for section in split_sections(patch):
        old, new = paths(section)
        suffix = new.split("/", 1)[1] if new.startswith("smali/") else re.sub(r"^smali_classes\d+/", "", new)

        if suffix == "com/android/systemui/appops/AppOpsControllerImpl.smali":
            target = locate(decoded, suffix)
            if appops_ready(target):
                print("SystemUI EAD: AppOps já possui SEAD/SightCare; seção omitida.")
                continue
            actual = target.relative_to(decoded).as_posix()
            selected.append(replace_path(section, old, actual))
            continue

        if suffix == "com/android/systemui/settings/brightness/BrightnessDetailAdapter.smali":
            target = locate(decoded, suffix)
            actual = target.relative_to(decoded).as_posix()
            print(f"SystemUI EAD: BrightnessDetailAdapter real = {actual}")
            selected.append(replace_path(section, old, actual))
            continue

        if "new file mode" in section:
            target = decoded / new
            expected = new_file_content(section)
            if target.exists():
                current = target.read_text(encoding="utf-8", errors="strict")
                if current == expected:
                    print(f"SystemUI EAD: novo arquivo já aplicado; omitindo {new}")
                    continue
                die(f"arquivo novo já existe com conteúdo diferente: {new}")
            selected.append(section)
            continue

        selected.append(section)

    if selected:
        generated = "".join(selected)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".patch", delete=False) as tmp:
            tmp.write(generated)
            temp_path = Path(tmp.name)
        try:
            for garbage in decoded.rglob("*"):
                if garbage.is_file() and garbage.suffix in {".rej", ".orig"}:
                    garbage.unlink()
            env = {**os.environ, "LC_ALL": "C"}
            dry = subprocess.run(
                ["patch", "-p1", "-d", str(decoded), "-N", "--forward", "-l", "--dry-run", "-i", str(temp_path)],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
            )
            print("===== DRY-RUN SYSTEMUI EAD ANDROID 17 =====")
            print(dry.stdout, end="")
            if dry.returncode != 0:
                die("patch SystemUI EAD adaptado ainda não aplica; nenhum hunk foi aplicado pelo helper")
            run = subprocess.run(
                ["patch", "-p1", "-d", str(decoded), "-N", "--forward", "-l", "-i", str(temp_path)],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
            )
            print(run.stdout, end="")
            if run.returncode != 0:
                die("falha inesperada ao aplicar patch SystemUI EAD após dry-run válido")
        finally:
            temp_path.unlink(missing_ok=True)
    else:
        print("SystemUI EAD: todas as seções já estavam aplicadas.")

    validate(decoded)


if __name__ == "__main__":
    main()
