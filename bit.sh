#!/usr/bin/env bash

cd ~/root/UN1CA-HIRUMISU

echo "======================================================"
echo "BLOCO A: Correções confirmadas nesta conversa (eSE, legacy UICC,"
echo "esecomm, mainline api, virtual_vib, HDR, fingerprint side_fp,"
echo "EAD adaptive color tone, rezoss)"
echo "======================================================"

touch unica/patches/ese/disable

sed -i \
    's/LOG_MISSING_PATCHES "SOURCE_SECURITY_CONFIG_ESE_COS_NAME" "TARGET_SECURITY_CONFIG_ESE_COS_NAME"$/LOG_MISSING_PATCHES "SOURCE_SECURITY_CONFIG_ESE_COS_NAME" "TARGET_SECURITY_CONFIG_ESE_COS_NAME" || true/' \
    unica/patches/ese/customize.sh

python3 <<'PYEOF'
def apply(path, replacements):
    s = open(path).read()

    for old, new, label in replacements:
        if old in s:
            s = s.replace(old, new, 1)
            print(f"OK: {label}")
        else:
            print(f"PULADO (padrao nao encontrado): {label}")

    open(path, "w").write(s)


apply(
    "unica/patches/legacy/customize.sh",
    [
        (
            '''        PATCHED=true
        APPLY_PATCH "system" "system/framework/telephony-common.jar" \\
            "$MODPATH/ril/telephony-common.jar/0001-Backport-legacy-UiccController-code.patch"
    fi''',
            '''        #PATCHED=true
        #APPLY_PATCH "system" "system/framework/telephony-common.jar" \\
            #"$MODPATH/ril/telephony-common.jar/0001-Backport-legacy-UiccController-code.patch"
        true
    fi''',
            "legacy UICC controller",
        ),
    ],
)

apply(
    "unica/patches/product_feature/customize.sh",
    [
        (
            '''    SMALI_PATCH "system" "system/framework/esecomm.jar" \\
        "smali/com/sec/esecomm/EsecommAdapter.smali" "replace" \\
        "<clinit>()V" \\
        "$SOURCE_PRODUCT_SHIPPING_API_LEVEL" \\
        "$TARGET_PRODUCT_SHIPPING_API_LEVEL"
    SMALI_PATCH "system" "system/framework/services.jar" \\
        "smali/com/android/server/enterprise/hdm/HdmSakManager.smali" "replace" \\''',
            '''    SMALI_PATCH "system" "system/framework/services.jar" \\
        "smali/com/android/server/enterprise/hdm/HdmSakManager.smali" "replace" \\''',
            "esecomm.jar block removal",
        ),
        (
            'if [[ "$SOURCE_PRODUCT_SHIPPING_API_LEVEL" != "$TARGET_PRODUCT_SHIPPING_API_LEVEL" ]]; then',
            'if false; then',
            "mainline api level disable",
        ),
        (
            'if ! $TARGET_AUDIO_SUPPORT_VIRTUAL_VIBRATION; then',
            'if false; then',
            "virtual_vib disable",
        ),
        (
            'if ! $TARGET_COMMON_SUPPORT_HDR_EFFECT; then',
            'if false; then',
            "HDR disable",
        ),
        (
            'smali_classes4/com/samsung/android/settings/biometrics/fingerprint/FingerprintSettingsUtils.smali',
            'smali_classes5/com/samsung/android/settings/biometrics/fingerprint/FingerprintSettingsUtils.smali',
            "fingerprint classes4->5",
        ),
        (
            '"$MODPATH/fingerprint/side_fp/framework.jar/0001-Add-side-fingerprint-sensor-support.patch"',
            '"$MODPATH/fingerprint/side_fp/framework.jar/0001-Add-side-fingerprint-sensor-support.patch" || true',
            "side_fp framework.jar tolerante",
        ),
        (
            '"$MODPATH/fingerprint/side_fp/services.jar/0001-Add-side-fingerprint-sensor-support.patch"',
            '"$MODPATH/fingerprint/side_fp/services.jar/0001-Add-side-fingerprint-sensor-support.patch" || true',
            "side_fp services.jar tolerante",
        ),
        (
            '"$MODPATH/fingerprint/side_fp/SecSettings.apk/0001-Add-side-fingerprint-sensor-support.patch"',
            '"$MODPATH/fingerprint/side_fp/SecSettings.apk/0001-Add-side-fingerprint-sensor-support.patch" || true',
            "side_fp SecSettings.apk tolerante",
        ),
    ],
)

apply(
    "unica/mods/paradigm/customize.sh",
    [
        (
            '"$MODPATH/ead/services.jar/0001-Add-Adaptive-color-tone-feature.patch"',
            '"$MODPATH/ead/services.jar/0001-Add-Adaptive-color-tone-feature.patch" || true',
            "ead services.jar",
        ),
        (
            '"$MODPATH/ead_mdnie/services.jar/0001-Add-Adaptive-color-tone-feature.patch"',
            '"$MODPATH/ead_mdnie/services.jar/0001-Add-Adaptive-color-tone-feature.patch" || true',
            "ead_mdnie services.jar",
        ),
        (
            '"$MODPATH/ead_resolution/SecSettings.apk/0001-Add-Adaptive-color-tone-feature.patch"',
            '"$MODPATH/ead_resolution/SecSettings.apk/0001-Add-Adaptive-color-tone-feature.patch" || true',
            "ead_resolution SecSettings",
        ),
        (
            '"$MODPATH/ead_resolution_legacy/SecSettings.apk/0001-Add-Adaptive-color-tone-feature.patch"',
            '"$MODPATH/ead_resolution_legacy/SecSettings.apk/0001-Add-Adaptive-color-tone-feature.patch" || true',
            "ead_resolution_legacy SecSettings",
        ),
        (
            '"$MODPATH/ead/SecSettings.apk/0001-Add-Adaptive-color-tone-feature.patch"',
            '"$MODPATH/ead/SecSettings.apk/0001-Add-Adaptive-color-tone-feature.patch" || true',
            "ead SecSettings",
        ),
        (
            '"$MODPATH/ead/SettingsProvider.apk/0001-Add-Adaptive-color-tone-feature.patch"',
            '"$MODPATH/ead/SettingsProvider.apk/0001-Add-Adaptive-color-tone-feature.patch" || true',
            "ead SettingsProvider",
        ),
        (
            '"$MODPATH/ead/SystemUI.apk/0001-Add-Adaptive-color-tone-toggle.patch"',
            '"$MODPATH/ead/SystemUI.apk/0001-Add-Adaptive-color-tone-toggle.patch" || true',
            "ead SystemUI",
        ),
    ],
)
PYEOF

touch unica/mods/rezoss/disable

echo "======================================================"
echo "BLOCO B: Correções NÃO verificadas nesta conversa (câmera/dvfs/ese extra)"
echo "Revise antes de confiar cegamente"
echo "======================================================"

mkdir -p target/a05s/camera

cat > target/a05s/camera/camera-feature.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<CameraFeatures>
</CameraFeatures>
EOF

sed -i \
    '71s/^\([^#]\)/#\1/' \
    unica/patches/dvfs/customize.sh

sed -i \
    '/APPLY_PATCH "system" "system\/framework\/framework.jar" "\$MODPATH\/ese\/framework.jar\/0001-Disable-SemService.patch"/s/^\([^#]\)/#\1/' \
    unica/patches/ese/customize.sh

sed -i \
    '/APPLY_PATCH "system" "system\/framework\/services.jar" "\$MODPATH\/ese\/services.jar\/0001-Disable-SemService.patch"/s/^\([^#]\)/#\1/' \
    unica/patches/ese/customize.sh

sed -i \
    '271s#.*#    DELETE_FROM_WORK_DIR "system" "system/lib64/libarcsoft_superresolution_bokeh.so" 2>/dev/null || true#' \
    unica/patches/camera/customize.sh

echo "======================================================"
echo "BLOCO C: Módulos inteiros desabilitados + deknox (NÃO VERIFICADO,"
echo "'deknox' nunca foi discutido nesta conversa -- risco de comentar linha errada)"
echo "======================================================"

touch unica/patches/spen/disable
touch unica/patches/uwb/disable
touch unica/patches/saiv/disable
touch unica/patches/product_feature/disable

ESE_SMALI="out/target/a05s/apktool/system/app/SecureElement/SecureElement.apk/smali/com/android/se/internal/UtilExtension.smali"

if [ -f "$ESE_SMALI" ]; then
    sed -i \
        's/const-string v1, "JCOP6.2U"/const-string v1, ""/' \
        "$ESE_SMALI"
fi

grep -n \
    "0001-Disable-eSE-support.patch" \
    unica/patches/ese/ese/customize.sh 2>/dev/null ||
    echo "AVISO: caminho unica/patches/ese/ese/customize.sh não existe -- item ignorado"

if [ -f unica/mods/deknox/customize.sh ]; then
    sed -i '287,292 s/^/#/' unica/mods/deknox/customize.sh
    sed -i '295,296 s/^/#/' unica/mods/deknox/customize.sh
    sed -i '428,429 s/^/#/' unica/mods/deknox/customize.sh
    sed -i '427 a\    :' unica/mods/deknox/customize.sh
else
    echo "AVISO: unica/mods/deknox/customize.sh não existe neste projeto -- bloco inteiro ignorado"
fi

echo "======================================================"
echo "Validando sintaxe de todos os arquivos tocados"
echo "======================================================"

for f in \
    unica/patches/ese/customize.sh \
    unica/patches/legacy/customize.sh \
    unica/patches/product_feature/customize.sh \
    unica/mods/paradigm/customize.sh \
    unica/patches/dvfs/customize.sh \
    unica/patches/camera/customize.sh
do
    if [ -f "$f" ]; then
        if bash -n "$f"; then
            echo "OK: $f"
        else
            echo "!!! ERRO DE SINTAXE: $f"
        fi
    fi
done

echo "======================================================"
echo "Limpando build antigo (BLOCO C pedia isso) e commitando"
echo "======================================================"

rm -rf out/target/a05s

git add -A
git commit -m "fix: correcoes A05s (confirmadas + nao verificadas, revisar)"
git push origin lapanlima

echo "PRONTO -- revise os avisos acima antes de rodar o build."
