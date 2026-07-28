#!/usr/bin/env python3

from pathlib import Path
import sys

root = Path(sys.argv[1])

files = list(root.rglob("AudioEraserUtils.smali"))

if len(files) != 1:
    raise SystemExit(
        f"ERRO: AudioEraserUtils.smali encontrado {len(files)} vez(es)"
    )

path = files[0]
text = path.read_text(encoding="utf-8")

old_signature = (
    ".method public static "
    "setStrength(ILandroid/content/Context;)V"
)

new_signature = (
    ".method public static setStrength("
    "Landroid/content/Context;"
    "Ljava/lang/String;I)V"
)

if old_signature in text:
    print("OK: wrapper Audio Eraser já existe")
    raise SystemExit(0)

if new_signature not in text:
    raise SystemExit(
        "ERRO: método Android 17 "
        "setStrength(Context,String,int) não encontrado"
    )

wrapper = r'''

.method public static setStrength(ILandroid/content/Context;)V
    .locals 3

    if-eqz p1, :cond_unica_return

    const-string v0, "audio_eraser"

    const/4 v1, 0x0

    invoke-virtual {p1, v0, v1}, Landroid/content/Context;->getSharedPreferences(Ljava/lang/String;I)Landroid/content/SharedPreferences;

    move-result-object v0

    const-string v1, "audio_eraser_package_name"

    const-string v2, ""

    invoke-interface {v0, v1, v2}, Landroid/content/SharedPreferences;->getString(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    if-eqz v0, :cond_unica_return

    invoke-virtual {v0}, Ljava/lang/String;->length()I

    move-result v1

    if-eqz v1, :cond_unica_return

    invoke-static {p1, v0, p0}, Lcom/android/systemui/samsung/quicksetting/ui/banner/AudioEraserUtils;->setStrength(Landroid/content/Context;Ljava/lang/String;I)V

    :cond_unica_return
    return-void
.end method
'''

path.write_text(
    text.rstrip() + wrapper + "\n",
    encoding="utf-8",
)

print("OK: wrapper Audio Eraser Android 17 adicionado")
