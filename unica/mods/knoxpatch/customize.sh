# Nuke WSM
DELETE_FROM_WORK_DIR "system" "system/etc/public.libraries-wsm.samsung.txt"
DELETE_FROM_WORK_DIR "system" "system/lib/libhal.wsm.samsung.so"
DELETE_FROM_WORK_DIR "system" "system/lib/vendor.samsung.hardware.security.wsm.service-V1-ndk.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/libhal.wsm.samsung.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/vendor.samsung.hardware.security.wsm.service-V1-ndk.so"

# Add KnoxPatchHooks
APPLY_PATCH "system" "system/framework/framework.jar" \
    "$MODPATH/framework.jar/0001-Introduce-KnoxPatchHooks.patch"
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali/android/app/Instrumentation.smali" "replace" \
    'newApplication(Ljava/lang/Class;Landroid/content/Context;)Landroid/app/Application;' \
    'return-object p0' \
    '    invoke-static {p1}, Lio/mesalabs/unica/KnoxPatchHooks;->init(Landroid/content/Context;)V\n\n    return-object p0' \
    > /dev/null
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali/android/app/Instrumentation.smali" "replace" \
    'newApplication(Ljava/lang/ClassLoader;Ljava/lang/String;Landroid/content/Context;)Landroid/app/Application;' \
    'return-object p0' \
    '    invoke-static {p3}, Lio/mesalabs/unica/KnoxPatchHooks;->init(Landroid/content/Context;)V\n\n    return-object p0' \
    > /dev/null
APPLY_PATCH "system" "system/framework/knoxsdk.jar" \
    "$MODPATH/knoxsdk.jar/0001-Introduce-KnoxPatchHooks.patch"

# Bypass ICD verification
SMALI_PATCH "system" "system/framework/samsungkeystoreutils.jar" \
    "smali/com/samsung/android/security/keystore/AttestParameterSpec.smali" "return" \
    'isVerifiableIntegrity()Z' 'true'
# Android 17: o patch ICD literal foi substituído por uma
# aplicação semântica completa depois que services.jar for
# decompilado pelo primeiro SMALI_PATCH abaixo.
# Disable SAK in DarManagerService
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali/com/android/server/knox/dar/DarManagerService.smali" "return" \
    'checkDeviceIntegrity([Ljava/security/cert/Certificate;)Z' 'true'

LOG "- Applying \"Bypass ICD verification (Android 17 semantic)\" to /system/system/framework/services.jar"
python3 "$MODPATH/apply_icd_android17.py" "/root/UN1CA-HIRUMISU"

# Disable DRK in DarManagerService
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali/com/android/server/knox/dar/DarManagerService.smali" "return" \
    'isDeviceRootKeyInstalled()Z' 'true'

# Disable root checks in StorageManagerService
SMALI_PATCH "system" "system/framework/services.jar" \
    "smali/com/android/server/StorageManagerService.smali" "return" \
    'isRootedDevice()Z' 'false'

# Spoof ROT/IntegrityStatus in Knox Matrix
if [ -f "$WORK_DIR/system/system/priv-app/KmxService/KmxService.apk" ]; then
    LOG "- Resolving Knox Matrix download URL"

    KMX_URL="$(
        GET_GALAXY_STORE_DOWNLOAD_URL             "com.samsung.android.kmxservice"             2>/dev/null || true
    )"

    case "$KMX_URL" in
        http://*|https://*)
            LOG "- Downloading latest Knox Matrix app"
            DOWNLOAD_FILE "$KMX_URL"                 "$WORK_DIR/system/system/priv-app/KmxService/KmxService.apk"
            ;;
        *)
            LOG "- Galaxy Store URI unavailable; using Knox Matrix app from source firmware"
            ;;
    esac
    APPLY_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "$MODPATH/KmxService.apk/0002-Ignore-FabricEscrowVault-errors-in-KmxServiceReceiver.patch"
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/common/util/RootOfTrust.smali" "return" \
        'getVerifiedBootState()I' '0'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/common/util/RootOfTrust.smali" "return" \
        'isDeviceLocked()Z' 'true'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/fabrickeystore/keystore/cert/RootOfTrust.smali" "return" \
        'getVerifiedBootState()I' '0'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/fabrickeystore/keystore/cert/RootOfTrust.smali" "return" \
        'isDeviceLocked()Z' 'true'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/sdk/trustchain/util/RootOfTrust.smali" "return" \
        'getVerifiedBootState()I' '0'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/sdk/trustchain/util/RootOfTrust.smali" "return" \
        'isDeviceLocked()Z' 'true'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/common/util/IntegrityStatus.smali" "return" \
        'getStatus()I' '0'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/common/util/IntegrityStatus.smali" "return" \
        'isNormal()Z' 'true'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/fabrickeystore/keystore/cert/IntegrityStatus.smali" "return" \
        'isNormal()Z' 'true'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/sdk/trustchain/util/IntegrityStatus.smali" "return" \
        'getStatus()I' '0'
    SMALI_PATCH "system" "system/priv-app/KmxService/KmxService.apk" \
        "smali_classes2/com/samsung/android/kmxservice/sdk/trustchain/util/IntegrityStatus.smali" "return" \
        'isNormal()Z' 'true'
fi
