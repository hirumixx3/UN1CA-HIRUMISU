#!/usr/bin/env python3
from pathlib import Path
import re, sys

root = Path(sys.argv[1])

def find_one(name):
    files = list(root.rglob(name))
    if len(files) != 1:
        raise SystemExit(f"ERRO: {name} encontrado {len(files)} vez(es)")
    return files[0]

# 1. Substitui integralmente setStrength().
utils = find_one("AudioEraserUtils.smali")
text = utils.read_text(encoding="utf-8")

method = r'''.method public static setStrength(ILandroid/content/Context;)V
    .locals 6

    if-eqz p1, :cond_unica_return

    :try_start_0
    const-string v0, "audio_eraser"

    const/4 v1, 0x0

    invoke-virtual {p1, v0, v1}, Landroid/content/Context;->getSharedPreferences(Ljava/lang/String;I)Landroid/content/SharedPreferences;

    move-result-object v0

    const-string v1, "audio_eraser_package_name"

    const-string v2, ""

    invoke-interface {v0, v1, v2}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    if-eqz v0, :cond_unica_missing

    invoke-virtual {v0}, Ljava/lang/String;->length()I

    move-result v1

    if-eqz v1, :cond_unica_missing

    new-instance v1, Landroid/content/ContentValues;

    invoke-direct {v1}, Landroid/content/ContentValues;-><init>()V

    new-instance v2, Ljava/lang/StringBuilder;

    invoke-direct {v2}, Ljava/lang/StringBuilder;-><init>()V

    invoke-virtual {v2, v0}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    const-string v3, ":"

    invoke-virtual {v2, v3}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;

    invoke-virtual {v2, p0}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;

    invoke-virtual {v2}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;

    move-result-object v2

    const-string v3, "AUDIO_ERASER_EFFECT"

    invoke-virtual {v1, v3, v2}, Landroid/content/ContentValues;->put(Ljava/lang/String;Ljava/lang/String;)V

    invoke-virtual {p1}, Landroid/content/Context;->getContentResolver()Landroid/content/ContentResolver;

    move-result-object v3

    const-string v4, "content://com.sec.android.app.soundalive.compatibility.AudioEraserProvider"

    invoke-static {v4}, Landroid/net/Uri;->parse(Ljava/lang/String;)Landroid/net/Uri;

    move-result-object v4

    invoke-virtual {v3, v4, v1}, Landroid/content/ContentResolver;->insert(Landroid/net/Uri;Landroid/content/ContentValues;)Landroid/net/Uri;

    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0

    goto :cond_unica_return

    :cond_unica_missing
    const-string v0, "AudioEraserUtils"

    const-string v1, "Skipping setStrength: missing audio_eraser_package_name"

    invoke-static {v0, v1}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I

    goto :cond_unica_return

    :catch_0
    move-exception v0

    const-string v1, "AudioEraserUtils"

    const-string v2, "setStrength failed"

    invoke-static {v1, v2, v0}, Landroid/util/Slog;->e(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    :cond_unica_return
    return-void
.end method'''

pattern = re.compile(
    r"(?ms)^\.method public static setStrength\(ILandroid/content/Context;\)V\n.*?^\.end method"
)

if not pattern.search(text):
    raise SystemExit("ERRO: método setStrength não encontrado")

utils.write_text(pattern.sub(method, text, count=1), encoding="utf-8")

# 2. Faz setMode chamar o novo setStrength().
mode = find_one("AudioEraser$setMode$1.smali")
lines = mode.read_text(encoding="utf-8").splitlines(True)

if not any("AudioEraserUtils;->setStrength" in line for line in lines):
    voice = next(
        (i for i, line in enumerate(lines) if '"VOICE_BOOST_EFFECT"' in line),
        None
    )

    if voice is not None:
        start = next(
            i for i in range(voice, -1, -1)
            if "new-instance" in lines[i]
            and "ContentValues;" in lines[i]
        )
        end = next(
            i for i in range(voice, len(lines))
            if "ContentValues;->put" in lines[i]
        )
        del lines[start:end + 1]

    delegate = next(
        (i for i, line in enumerate(lines) if "->contentResolver$delegate:" in line),
        None
    )

    if delegate is not None:
        end = next(
            i for i in range(delegate, len(lines))
            if "ContentResolver;->insert" in lines[i]
        )
        del lines[delegate:end + 1]

    changed = next(
        (
            i for i, line in enumerate(lines)
            if "AudioEraser;->onModeChanged(I)V" in line
        ),
        None
    )

    if changed is None:
        raise SystemExit("ERRO: chamada onModeChanged não encontrada")

    lines[changed + 1:changed + 1] = [
        "\n",
        "    iget-object v1, v0, Lcom/android/systemui/samsung/quicksetting/ui/banner/AudioEraser;->context:Landroid/content/Context;\n",
        "\n",
        "    invoke-static {p0, v1}, Lcom/android/systemui/samsung/quicksetting/ui/banner/AudioEraserUtils;->setStrength(ILandroid/content/Context;)V\n",
    ]

mode.write_text("".join(lines), encoding="utf-8")

print("OK: provider Audio Eraser Android 17 aplicado")
