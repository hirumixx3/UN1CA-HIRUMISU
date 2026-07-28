SET_PROP_IF_DIFF "vendor" "ro.security.fips.ux" "Disabled"

DEKNOX_LIBEPM_PATCHED=0
DEKNOX_LIBEPM_ALREADY=0
DEKNOX_LIBMDF_PATCHED=0
DEKNOX_LIBMDF_ALREADY=0

DEKNOX_LIBEPM_PATCHED=0
DEKNOX_LIBEPM_ALREADY=0
DEKNOX_LIBMDF_PATCHED=0
DEKNOX_LIBMDF_ALREADY=0

DEKNOX_HEX_PATCH()
{
    local FILE="$1"
    local FROM="$2"
    local TO="$3"
    local FILE_HEX
    local BASE

    if [ ! -f "$FILE" ]; then
        LOGW "File not found: ${FILE//$WORK_DIR/}"
        return 0
    fi

    if [ "${#FROM}" -ne "${#TO}" ]; then
        ABORT "Invalid deknox hex patch: source and target sizes differ for ${FILE//$WORK_DIR/}"
    fi

    FILE_HEX="$(xxd -p -c 0 "$FILE" | tr 'A-F' 'a-f')"
    FROM="${FROM,,}"
    TO="${TO,,}"
    BASE="$(basename "$FILE")"

    if [[ "$FILE_HEX" == *"$FROM"* ]]; then
        LOG "- Applying compatible deknox signature to ${FILE//$WORK_DIR/}"

        HEX_PATCH "$FILE" "$FROM" "$TO"

        case "$BASE" in
            libepm.so)
                DEKNOX_LIBEPM_PATCHED=$((DEKNOX_LIBEPM_PATCHED + 1))
                ;;
            libmdf.so)
                DEKNOX_LIBMDF_PATCHED=$((DEKNOX_LIBMDF_PATCHED + 1))
                ;;
        esac

        return 0
    fi

    if [[ "$FILE_HEX" == *"$TO"* ]]; then
        LOG "- Deknox signature already applied in ${FILE//$WORK_DIR/}"

        case "$BASE" in
            libepm.so)
                DEKNOX_LIBEPM_ALREADY=$((DEKNOX_LIBEPM_ALREADY + 1))
                ;;
            libmdf.so)
                DEKNOX_LIBMDF_ALREADY=$((DEKNOX_LIBMDF_ALREADY + 1))
                ;;
        esac

        return 0
    fi

    # Esta assinatura específica não pertence à versão atual.
    # Outras assinaturas conhecidas ainda serão testadas.
    return 0
}

DELETE_FROM_WORK_DIR "system" "system/app/BlockchainBasicKit"
# Support legacy sdFAT kernel drivers (pre-API 35)
# Check unica/patches/legacy/customize.sh for more info.
if [ "$TARGET_PLATFORM_SDK_VERSION" -lt "35" ] && \
        grep -q "SDFAT" "$WORK_DIR/kernel/boot.img" && \
        ! grep -q "bogus directory:" "$WORK_DIR/kernel/boot.img"; then
    if xxd -p -c 0 "$WORK_DIR/system/system/bin/vold" | grep -q "2c74696d655f6f66667365743d2564"; then
        LOG_STEP_IN
        # ",time_offset=%d" -> "NUL"
        HEX_PATCH "$WORK_DIR/system/system/bin/vold" "2c74696d655f6f66667365743d2564" "000000000000000000000000000000"
        LOG_STEP_OUT
    fi
fi
DELETE_FROM_WORK_DIR "system" "system/bin/dualdard"
DELETE_FROM_WORK_DIR "system" "system/bin/sdp_cryptod"
DELETE_FROM_WORK_DIR "system" "system/etc/init/dualdard.rc"
DELETE_FROM_WORK_DIR "system" "system/etc/init/kpp.init.rc"
DELETE_FROM_WORK_DIR "system" "system/etc/init/kss.init.rc"
DELETE_FROM_WORK_DIR "system" "system/etc/init/sdp_cryptod.rc"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.hdmapp.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.kgclient.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.knox.kfbp.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.knox.knnr.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.knox.mpos.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.knox.pushmanager.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.knox.sandbox.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/privapp-permissions-com.samsung.android.knox.zt.framework.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/permissions/signature-permissions-com.samsung.android.kgclient.xml"
DELETE_FROM_WORK_DIR "system" "system/etc/sysconfig/preinstalled-packages-com.samsung.android.coldwalletservice.xml"
DELETE_FROM_WORK_DIR "system" "system/lib/libdualdar.so"
DELETE_FROM_WORK_DIR "system" "system/lib/libepm.so"
DELETE_FROM_WORK_DIR "system" "system/lib/libhermes_cred.so"
DELETE_FROM_WORK_DIR "system" "system/lib/libkeyutils.so"
DELETE_FROM_WORK_DIR "system" "system/lib/libknox_filemanager.so"
DELETE_FROM_WORK_DIR "system" "system/lib/libmdfpp_req.so"
DELETE_FROM_WORK_DIR "system" "system/lib/libpersona.so"
DELETE_FROM_WORK_DIR "system" "system/lib/libsdp_crypto.so"
DELETE_FROM_WORK_DIR "system" "system/lib/libsdp_kekm.so"
DELETE_FROM_WORK_DIR "system" "system/lib/libsdp_sdk.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/libmdfpp_req.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/libsdp_crypto.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/libsdp_kekm.so"
DELETE_FROM_WORK_DIR "system" "system/lib64/libsdp_sdk.so"
DELETE_FROM_WORK_DIR "system" "system/priv-app/HdmApk"
DELETE_FROM_WORK_DIR "system" "system/priv-app/KnoxFrameBufferProvider"
DELETE_FROM_WORK_DIR "system" "system/priv-app/KnoxGuard"
DELETE_FROM_WORK_DIR "system" "system/priv-app/KnoxMposAgent"
DELETE_FROM_WORK_DIR "system" "system/priv-app/KnoxNeuralNetworkRuntime"
DELETE_FROM_WORK_DIR "system" "system/priv-app/KnoxPushManager"
DELETE_FROM_WORK_DIR "system" "system/priv-app/KnoxSandbox"
DELETE_FROM_WORK_DIR "system" "system/priv-app/KnoxZtFramework"

# OneUI 8.5: old a73xqxx donor swaps are unsafe because they replace core
# executables/libs from a different platform build. Keep current 8.5 binaries
# and stub the DDAR/MDF native entry points that the donor blobs removed.
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libepm.so" \
    "3f2303d5fe0f1df8f65701a9f44f02a928004039290840f9f30301aa" \
    "5f2403d5e0031f2ac0035fd61f2003d51f2003d51f2003d51f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libepm.so" \
    "3f2303d5fe4fbfa9842e0094892e0094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libepm.so" \
    "3f2303d5fe0f1ef8f44f01a948008052" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libepm.so" \
    "3f2303d5ffc301d1fd7b01a9fc6f02a9" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libepm.so" \
    "3f2303d5fd7bbaa9fc6f01a9fa6702a9f85f03a9f65704a9f44f05a9ff0740d1ff0305d100e4006f" \
    "5f2403d5e0031f2ac0035fd61f2003d51f2003d51f2003d51f2003d51f2003d51f2003d51f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libepm.so" \
    "3f2303d5ff8301d1fe2300f9f44f05a9" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libepm.so" \
    "3f2303d5fe0f1df8f65701a9f44f02a928004039290840f9f40302aa" \
    "5f2403d5e0031f2ac0035fd61f2003d51f2003d51f2003d51f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libepm.so" \
    "3f2303d5fd7bbaa9fc6f01a9fa6702a9f85f03a9f65704a9f44f05a9ff0740d1ff8304d100e4006f" \
    "5f2403d5e0031f2ac0035fd61f2003d51f2003d51f2003d51f2003d51f2003d51f2003d51f2003d5"

# BEGIN ONEUI9 LIBEPM PATCH AUDIT
DEKNOX_LIBEPM_TOTAL=$((DEKNOX_LIBEPM_PATCHED + DEKNOX_LIBEPM_ALREADY))

if [ "$DEKNOX_LIBEPM_TOTAL" -gt 0 ]; then
    LOG "- libepm deknox signatures validated: patched=$DEKNOX_LIBEPM_PATCHED already=$DEKNOX_LIBEPM_ALREADY"
else
    LOGW "No known libepm.so native signature matches this One UI 9 build"
    LOGW "Continuing with framework/app DualDAR removal; native libepm stubs were not modified"
fi

unset DEKNOX_LIBEPM_TOTAL
# END ONEUI9 LIBEPM PATCH AUDIT

# Some Knox-era shared objects are kept only as loader shims because
# libandroid_servers.so has direct/transitive DT_NEEDED entries:
# - hidl_comm_ddar_client.so
# - vendor.samsung.hardware.tlc.ddar@1.0.so
# - android.hardware.weaver@1.0.so through libhermes_cred.so
# lib64/libdualdar.so is also kept for libepm's 8.5 BIND_NOW dependency chain.
# The libepm entry points above prevent DDAR use.
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "5f2403d5c00100b43f2303d5fd7bbfa9" \
    "5f2403d520008012c0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5ffc300d1fd7b02a9fd83009100e4006fe0ffffb000781691" \
    "5f2403d520008012c0035fd61f2003d51f2003d51f2003d51f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbea9f30b00f9fd030091" \
    "5f2403d520008012c0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5ffc300d1fd7b02a9fd83009100e4006fe0ffffb000b40b91" \
    "5f2403d5e0031f2ac0035fd61f2003d51f2003d51f2003d51f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd0300917e040094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd03009175040094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd0300916c040094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd03009163040094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd0300915a040094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd030091e5000094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5ff0302d1fd7b06a9f33b00f9" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd03009142000094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd03009139000094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd03009130000094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd03009127000094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd03009122000094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib64/libmdf.so" \
    "3f2303d5fd7bbfa9fd03009117000094" \
    "5f2403d5e0031f2ac0035fd61f2003d5"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b558b101460748" "6ff00100704700bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b58ab02648c0ef" "6ff00100704700bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "10b5002002f09ce9" "6ff00100704700bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b58ab01348c0ef" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b502f0b0e90021" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b502f0a6e90238" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b502f09ee90021" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b502f096e90438" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b502f08ee90138" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b501f0b8eb0128" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "10b598b004461648" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b501f0a6eac0b2" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b501f088eac0b2" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b501f08ceac0b2" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b501f08eeac0b2" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b501f06aeac0b2" "0020704700bf00bf"
DEKNOX_HEX_PATCH "$WORK_DIR/system/system/lib/libmdf.so" \
    "80b501f06ceac0b2" "0020704700bf00bf"

# BEGIN ONEUI9 UNLOCK CE STORAGE BINDER PATCH
if [[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" == "mssi" ]] || \
        [[ "$TARGET_OS_SINGLE_SYSTEM_IMAGE" == "qssi" ]]; then
    DECODE_APK \
        "system" \
        "system/framework/framework.jar" \
        || ABORT "Failed to decode framework.jar for unlockCeStorage"

    DECODE_APK \
        "system" \
        "system/framework/services.jar" \
        || ABORT "Failed to decode services.jar for unlockCeStorage"

    UNLOCK_FRAMEWORK="$APKTOOL_DIR/system/framework/framework.jar"
    UNLOCK_SERVICES="$APKTOOL_DIR/system/framework/services.jar"

    LOG "- Adapting unlockCeStorage Binder contract semantically"

    python3 \
        "$MODPATH/vold/patch_unlock_ce_storage_oneui9.py" \
        "$UNLOCK_FRAMEWORK" \
        "$UNLOCK_SERVICES" \
        || ABORT "unlockCeStorage Binder patch is incomplete"

    LOG "- unlockCeStorage Binder contract fully validated"

    unset UNLOCK_FRAMEWORK
    unset UNLOCK_SERVICES
fi
# END ONEUI9 UNLOCK CE STORAGE BINDER PATCH
DECODE_APK "system" "system/framework/services.jar"
SOURCE_FILE_ATTR="$(grep -F ".source" "$APKTOOL_DIR/system/framework/services.jar/smali/android/gsi/GsiProgress.smali")"
SOURCE_FILE_ATTR="${SOURCE_FILE_ATTR//\./\\\.}"
SOURCE_FILE_ATTR="${SOURCE_FILE_ATTR//\"/\\\"}"
SOURCE_FILE_ATTR="${SOURCE_FILE_ATTR//\//\\\/}"
LOG "- Replacing SourceFile attribute in /system/system/framework/services.jar"
find "$APKTOOL_DIR/system/framework/services.jar" -type f -name "*.smali" -print0 \
    | xargs -0 -I "{}" -P "$(nproc)" sed -i "s/^\.source.*/\.source \"SourceFile\"/g" "{}"
if [[ "$SOURCE_PRODUCT_SHIPPING_API_LEVEL" != "$TARGET_PRODUCT_SHIPPING_API_LEVEL" ]]; then
    SMALI_PATCH "system" "system/framework/services.jar" \
        "smali/com/android/server/knox/dar/ddar/ta/TAProxy.smali" "replace" \
        "updateServiceHolder(Z)V" \
        "$SOURCE_PRODUCT_SHIPPING_API_LEVEL" \
        "$TARGET_PRODUCT_SHIPPING_API_LEVEL" \
        > /dev/null
fi

# SEC_PRODUCT_FEATURE_KNOX_SUPPORT_SDP
# BEGIN UN1CA KNOX SDP SINGLE CALL
source "$(dirname "${BASH_SOURCE[0]}")/apply_sdp_idempotent.sh" || exit 1
# END UN1CA KNOX SDP SINGLE CALL
LOG "- Applying semantic Nuke Knox SDP to /system/system/framework/services.jar"
bash "$MODPATH/apply_sdp_services_semantic.sh" || exit 1

# SEC_PRODUCT_FEATURE_KNOX_SUPPORT_DUAL_DAR
LOG "- Applying semantic Nuke Knox DualDAR to /system/system/app/Traceur/Traceur.apk"
bash "$MODPATH/apply_traceur_dualdar_semantic.sh" || exit 1
DECODE_APK "system" "system/framework/framework.jar" || exit 1
LOG "- Applying semantic Nuke Knox DualDAR to /system/system/framework/framework.jar"
bash "$(dirname "${BASH_SOURCE[0]}")/apply_ddar_framework_semantic.sh" || exit 1
APPLY_PATCH "system" "system/framework/framework.jar" \
    "$MODPATH/ddar/framework.jar/0002-Nuke-MDF.patch"
DECODE_APK "system" "system/framework/knoxsdk.jar" || exit 1
LOG "- Applying semantic Nuke Knox DualDAR to /system/system/framework/knoxsdk.jar"
bash "$(dirname "${BASH_SOURCE[0]}")/apply_knoxsdk_dualdar_semantic.sh" || exit 1
DECODE_APK "system" "system/framework/services.jar" || exit 1
LOG "- Applying semantic Nuke Knox DualDAR to /system/system/framework/services.jar"
bash "$MODPATH/apply_ddar_services_semantic.sh" || exit 1
DECODE_APK "system" "system/priv-app/DeviceDiagnostics/DeviceDiagnostics.apk" || exit 1
LOG "- Applying semantic Nuke Knox DualDAR to /system/system/priv-app/DeviceDiagnostics/DeviceDiagnostics.apk"
bash "$(dirname "${BASH_SOURCE[0]}")/apply_devicediagnostics_dualdar_semantic.sh" || exit 1
DECODE_APK "system" "system/priv-app/KnoxCore/KnoxCore.apk" || exit 1
LOG "- Applying semantic Nuke Knox DualDAR to /system/system/priv-app/KnoxCore/KnoxCore.apk"
bash "$MODPATH/apply_remaining_dualdar_semantic.sh" "system" "system/priv-app/KnoxCore/KnoxCore.apk" "knoxcore" || exit 1
DECODE_APK "system" "system/priv-app/ManagedProvisioning/ManagedProvisioning.apk" || exit 1
LOG "- Applying semantic Nuke Knox DualDAR to /system/system/priv-app/ManagedProvisioning/ManagedProvisioning.apk"
bash "$MODPATH/apply_remaining_dualdar_semantic.sh" "system" "system/priv-app/ManagedProvisioning/ManagedProvisioning.apk" "embedded" || exit 1
DECODE_APK "system" "system/priv-app/SecSettings/SecSettings.apk" || exit 1
LOG "- Applying semantic Nuke Knox DualDAR to /system/system/priv-app/SecSettings/SecSettings.apk"
bash "$MODPATH/apply_remaining_dualdar_semantic.sh" "system" "system/priv-app/SecSettings/SecSettings.apk" "secsettings" || exit 1
DECODE_APK "system" "system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk" || exit 1
LOG "- Applying semantic Nuke Knox DualDAR to /system/system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk"
bash "$MODPATH/apply_remaining_dualdar_semantic.sh" "system" "system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk" "embedded" || exit 1
DECODE_APK "system_ext" "priv-app/StorageManager/StorageManager.apk" || exit 1
LOG "- Applying semantic Nuke Knox DualDAR to /system_ext/priv-app/StorageManager/StorageManager.apk"
bash "$MODPATH/apply_remaining_dualdar_semantic.sh" "system_ext" "priv-app/StorageManager/StorageManager.apk" "embedded" || exit 1

# SEC_PRODUCT_FEATURE_KNOX_SUPPORT_HDM
# BEGIN UN1CA HDM SEMANTIC MANAGERS
DECODE_APK "system" "system/app/Traceur/Traceur.apk" || exit 1
bash "$MODPATH/apply_hdm_manager_semantic.sh" "system" "system/app/Traceur/Traceur.apk" || exit 1

DECODE_APK "system" "system/framework/knoxsdk.jar" || exit 1
bash "$MODPATH/apply_hdm_manager_semantic.sh" "system" "system/framework/knoxsdk.jar" || exit 1

DECODE_APK "system" "system/priv-app/DeviceDiagnostics/DeviceDiagnostics.apk" || exit 1
bash "$MODPATH/apply_hdm_manager_semantic.sh" "system" "system/priv-app/DeviceDiagnostics/DeviceDiagnostics.apk" || exit 1

DECODE_APK "system" "system/priv-app/ManagedProvisioning/ManagedProvisioning.apk" || exit 1
bash "$MODPATH/apply_hdm_manager_semantic.sh" "system" "system/priv-app/ManagedProvisioning/ManagedProvisioning.apk" || exit 1

DECODE_APK "system" "system/priv-app/SecSettings/SecSettings.apk" || exit 1
bash "$MODPATH/apply_hdm_manager_semantic.sh" "system" "system/priv-app/SecSettings/SecSettings.apk" || exit 1

DECODE_APK "system" "system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk" || exit 1
bash "$MODPATH/apply_hdm_manager_semantic.sh" "system" "system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk" || exit 1

DECODE_APK "system_ext" "priv-app/StorageManager/StorageManager.apk" || exit 1
bash "$MODPATH/apply_hdm_manager_semantic.sh" "system_ext" "priv-app/StorageManager/StorageManager.apk" || exit 1

DECODE_APK "system_ext" "priv-app/SystemUI/SystemUI.apk" || exit 1
bash "$MODPATH/apply_hdm_manager_semantic.sh" "system_ext" "priv-app/SystemUI/SystemUI.apk" || exit 1

# END UN1CA HDM SEMANTIC MANAGERS
DECODE_APK "system" "system/framework/knoxsdk.jar"


if [[ "$SOURCE_PRODUCT_SHIPPING_API_LEVEL" != "$TARGET_PRODUCT_SHIPPING_API_LEVEL" ]]; then
    SMALI_PATCH "system" "system/framework/services.jar" \
        "smali/com/android/server/enterprise/hdm/HdmSakManager.smali" "replace" \
        "isSupported(Landroid/content/Context;)Z" \
        "$SOURCE_PRODUCT_SHIPPING_API_LEVEL" \
        "$TARGET_PRODUCT_SHIPPING_API_LEVEL" \
        > /dev/null
###    SMALI_PATCH "system" "system/framework/services.jar" \
###        "smali/com/android/server/enterprise/hdm/HdmVendorController.smali" "replace" \
###        "<init>()V" \
###        "$TARGET_PRODUCT_SHIPPING_API_LEVEL" \
###        "$SOURCE_PRODUCT_SHIPPING_API_LEVEL" \
###        > /dev/null
fi
# Nuke HDM service and vendor controller
###APPLY_PATCH "system" "system/framework/services.jar" \
###    "$MODPATH/hdm/services.jar/0001-Nuke-Knox-HDM.patch"


#SEC_PRODUCT_FEATURE_KNOX_SUPPORT_BLDP

# SEC_PRODUCT_FEATURE_KNOX_SUPPORT_MPOS
# TODO add services.jar patch
DECODE_APK "system" "system/app/Traceur/Traceur.apk" || exit 1
UN1CA_EAP_1_ROOT="$APKTOOL_DIR/system/app/Traceur/Traceur.apk"
mapfile -t UN1CA_EAP_1_MATCHES < <(
    find "${UN1CA_EAP_1_ROOT}" -type f \
        -path '*/com/samsung/android/knox/integrity/EnhancedAttestationPolicy.smali' \
        -printf '%P\n'
)

if [ "${#UN1CA_EAP_1_MATCHES[@]}" -ne 1 ]; then
    echo "ERRO: esperava exatamente uma cópia de EnhancedAttestationPolicy.smali em:"
    echo "${UN1CA_EAP_1_ROOT}"
    printf '  %s\n' "${UN1CA_EAP_1_MATCHES[@]}"
    exit 1
fi

UN1CA_EAP_1_SMALI="${UN1CA_EAP_1_MATCHES[0]}"
echo "    - EnhancedAttestationPolicy (system/app/Traceur/Traceur.apk): ${UN1CA_EAP_1_SMALI}"
SMALI_PATCH "system" "system/app/Traceur/Traceur.apk" \
    "${UN1CA_EAP_1_SMALI}" "return" \
    'isMposSupported()Z' 'false'
unset UN1CA_EAP_1_ROOT UN1CA_EAP_1_SMALI UN1CA_EAP_1_MATCHES
DECODE_APK "system" "system/framework/knoxsdk.jar" || exit 1
UN1CA_EAP_2_ROOT="$APKTOOL_DIR/system/framework/knoxsdk.jar"
mapfile -t UN1CA_EAP_2_MATCHES < <(
    find "${UN1CA_EAP_2_ROOT}" -type f \
        -path '*/com/samsung/android/knox/integrity/EnhancedAttestationPolicy.smali' \
        -printf '%P\n'
)

if [ "${#UN1CA_EAP_2_MATCHES[@]}" -ne 1 ]; then
    echo "ERRO: esperava exatamente uma cópia de EnhancedAttestationPolicy.smali em:"
    echo "${UN1CA_EAP_2_ROOT}"
    printf '  %s\n' "${UN1CA_EAP_2_MATCHES[@]}"
    exit 1
fi

UN1CA_EAP_2_SMALI="${UN1CA_EAP_2_MATCHES[0]}"
echo "    - EnhancedAttestationPolicy (system/framework/knoxsdk.jar): ${UN1CA_EAP_2_SMALI}"
SMALI_PATCH "system" "system/framework/knoxsdk.jar" \
    "${UN1CA_EAP_2_SMALI}" "return" \
    'isMposSupported()Z' 'false'
unset UN1CA_EAP_2_ROOT UN1CA_EAP_2_SMALI UN1CA_EAP_2_MATCHES
DECODE_APK "system" "system/priv-app/DeviceDiagnostics/DeviceDiagnostics.apk" || exit 1
UN1CA_EAP_3_ROOT="$APKTOOL_DIR/system/priv-app/DeviceDiagnostics/DeviceDiagnostics.apk"
mapfile -t UN1CA_EAP_3_MATCHES < <(
    find "${UN1CA_EAP_3_ROOT}" -type f \
        -path '*/com/samsung/android/knox/integrity/EnhancedAttestationPolicy.smali' \
        -printf '%P\n'
)

if [ "${#UN1CA_EAP_3_MATCHES[@]}" -ne 1 ]; then
    echo "ERRO: esperava exatamente uma cópia de EnhancedAttestationPolicy.smali em:"
    echo "${UN1CA_EAP_3_ROOT}"
    printf '  %s\n' "${UN1CA_EAP_3_MATCHES[@]}"
    exit 1
fi

UN1CA_EAP_3_SMALI="${UN1CA_EAP_3_MATCHES[0]}"
echo "    - EnhancedAttestationPolicy (system/priv-app/DeviceDiagnostics/DeviceDiagnostics.apk): ${UN1CA_EAP_3_SMALI}"
SMALI_PATCH "system" "system/priv-app/DeviceDiagnostics/DeviceDiagnostics.apk" \
    "${UN1CA_EAP_3_SMALI}" "return" \
    'isMposSupported()Z' 'false'
unset UN1CA_EAP_3_ROOT UN1CA_EAP_3_SMALI UN1CA_EAP_3_MATCHES
DECODE_APK "system" "system/priv-app/ManagedProvisioning/ManagedProvisioning.apk" || exit 1
UN1CA_EAP_4_ROOT="$APKTOOL_DIR/system/priv-app/ManagedProvisioning/ManagedProvisioning.apk"
mapfile -t UN1CA_EAP_4_MATCHES < <(
    find "${UN1CA_EAP_4_ROOT}" -type f \
        -path '*/com/samsung/android/knox/integrity/EnhancedAttestationPolicy.smali' \
        -printf '%P\n'
)

if [ "${#UN1CA_EAP_4_MATCHES[@]}" -ne 1 ]; then
    echo "ERRO: esperava exatamente uma cópia de EnhancedAttestationPolicy.smali em:"
    echo "${UN1CA_EAP_4_ROOT}"
    printf '  %s\n' "${UN1CA_EAP_4_MATCHES[@]}"
    exit 1
fi

UN1CA_EAP_4_SMALI="${UN1CA_EAP_4_MATCHES[0]}"
echo "    - EnhancedAttestationPolicy (system/priv-app/ManagedProvisioning/ManagedProvisioning.apk): ${UN1CA_EAP_4_SMALI}"
SMALI_PATCH "system" "system/priv-app/ManagedProvisioning/ManagedProvisioning.apk" \
    "${UN1CA_EAP_4_SMALI}" "return" \
    'isMposSupported()Z' 'false'
unset UN1CA_EAP_4_ROOT UN1CA_EAP_4_SMALI UN1CA_EAP_4_MATCHES
# BEGIN UN1CA DYNAMIC SECSETTINGS EAP PATH
DECODE_APK "system" "system/priv-app/SecSettings/SecSettings.apk" || exit 1
SECSETTINGS_EAP_ROOT="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk"
mapfile -t SECSETTINGS_EAP_MATCHES < <(
    find "$SECSETTINGS_EAP_ROOT" -type f \
        -path '*/com/samsung/android/knox/integrity/EnhancedAttestationPolicy.smali' \
        -printf '%P\n'
)

if [ "${#SECSETTINGS_EAP_MATCHES[@]}" -ne 1 ]; then
    echo "ERRO: esperava uma única cópia de EnhancedAttestationPolicy.smali no SecSettings"
    printf '  %s\n' "${SECSETTINGS_EAP_MATCHES[@]}"
    exit 1
fi

SECSETTINGS_EAP_SMALI="${SECSETTINGS_EAP_MATCHES[0]}"
echo "    - EnhancedAttestationPolicy: $SECSETTINGS_EAP_SMALI"
# END UN1CA DYNAMIC SECSETTINGS EAP PATH
SMALI_PATCH "system" "system/priv-app/SecSettings/SecSettings.apk" \
    "$SECSETTINGS_EAP_SMALI" "return" \
    'isMposSupported()Z' 'false'
unset SECSETTINGS_EAP_ROOT SECSETTINGS_EAP_SMALI SECSETTINGS_EAP_MATCHES
DECODE_APK "system" "system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk" || exit 1
UN1CA_EAP_5_ROOT="$APKTOOL_DIR/system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk"
mapfile -t UN1CA_EAP_5_MATCHES < <(
    find "${UN1CA_EAP_5_ROOT}" -type f \
        -path '*/com/samsung/android/knox/integrity/EnhancedAttestationPolicy.smali' \
        -printf '%P\n'
)

if [ "${#UN1CA_EAP_5_MATCHES[@]}" -ne 1 ]; then
    echo "ERRO: esperava exatamente uma cópia de EnhancedAttestationPolicy.smali em:"
    echo "${UN1CA_EAP_5_ROOT}"
    printf '  %s\n' "${UN1CA_EAP_5_MATCHES[@]}"
    exit 1
fi

UN1CA_EAP_5_SMALI="${UN1CA_EAP_5_MATCHES[0]}"
echo "    - EnhancedAttestationPolicy (system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk): ${UN1CA_EAP_5_SMALI}"
SMALI_PATCH "system" "system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk" \
    "${UN1CA_EAP_5_SMALI}" "return" \
    'isMposSupported()Z' 'false'
unset UN1CA_EAP_5_ROOT UN1CA_EAP_5_SMALI UN1CA_EAP_5_MATCHES
DECODE_APK "system_ext" "priv-app/StorageManager/StorageManager.apk" || exit 1
UN1CA_EAP_6_ROOT="$APKTOOL_DIR/system_ext/priv-app/StorageManager/StorageManager.apk"
mapfile -t UN1CA_EAP_6_MATCHES < <(
    find "${UN1CA_EAP_6_ROOT}" -type f \
        -path '*/com/samsung/android/knox/integrity/EnhancedAttestationPolicy.smali' \
        -printf '%P\n'
)

if [ "${#UN1CA_EAP_6_MATCHES[@]}" -ne 1 ]; then
    echo "ERRO: esperava exatamente uma cópia de EnhancedAttestationPolicy.smali em:"
    echo "${UN1CA_EAP_6_ROOT}"
    printf '  %s\n' "${UN1CA_EAP_6_MATCHES[@]}"
    exit 1
fi

UN1CA_EAP_6_SMALI="${UN1CA_EAP_6_MATCHES[0]}"
echo "    - EnhancedAttestationPolicy (priv-app/StorageManager/StorageManager.apk): ${UN1CA_EAP_6_SMALI}"
SMALI_PATCH "system_ext" "priv-app/StorageManager/StorageManager.apk" \
    "${UN1CA_EAP_6_SMALI}" "return" \
    'isMposSupported()Z' 'false'
unset UN1CA_EAP_6_ROOT UN1CA_EAP_6_SMALI UN1CA_EAP_6_MATCHES
DECODE_APK "system_ext" "priv-app/SystemUI/SystemUI.apk" || exit 1
UN1CA_EAP_7_ROOT="$APKTOOL_DIR/system_ext/priv-app/SystemUI/SystemUI.apk"
mapfile -t UN1CA_EAP_7_MATCHES < <(
    find "${UN1CA_EAP_7_ROOT}" -type f \
        -path '*/com/samsung/android/knox/integrity/EnhancedAttestationPolicy.smali' \
        -printf '%P\n'
)

if [ "${#UN1CA_EAP_7_MATCHES[@]}" -ne 1 ]; then
    echo "ERRO: esperava exatamente uma cópia de EnhancedAttestationPolicy.smali em:"
    echo "${UN1CA_EAP_7_ROOT}"
    printf '  %s\n' "${UN1CA_EAP_7_MATCHES[@]}"
    exit 1
fi

UN1CA_EAP_7_SMALI="${UN1CA_EAP_7_MATCHES[0]}"
echo "    - EnhancedAttestationPolicy (priv-app/SystemUI/SystemUI.apk): ${UN1CA_EAP_7_SMALI}"
SMALI_PATCH "system_ext" "priv-app/SystemUI/SystemUI.apk" \
    "${UN1CA_EAP_7_SMALI}" "return" \
    'isMposSupported()Z' 'false'
unset UN1CA_EAP_7_ROOT UN1CA_EAP_7_SMALI UN1CA_EAP_7_MATCHES

#SEC_PRODUCT_FEATURE_KNOX_SUPPORT_KNOXGUARD
APPLY_PATCH "system" "system/framework/services.jar" \
    "$MODPATH/knoxguard/services.jar/0001-Disable-KnoxGuard.patch"

# SEC_PRODUCT_FEATURE_SECURITY_SUPPORT_KNOX_MATRIX_AI_PRIVACY
DECODE_APK "system" "system/framework/framework.jar" || exit 1
LOG "- Applying semantic Nuke Knox Matrix AI Privacy to /system/system/framework/framework.jar"
bash "$MODPATH/apply_kmxai_framework_semantic.sh" || exit 1

#SEC_PRODUCT_FEATURE_FRAMEWORK_SUPPORT_BLOCKCHAIN_SERVICE
SET_FLOATING_FEATURE_CONFIG "SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_BLOCKCHAIN_SERVICE" --delete
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali_classes6/com/samsung/android/ProductPackagesRune.smali" "replaceall" \
    "SERVICE_SAMSUNG_BLOCKCHAIN:Z = true" \
    "SERVICE_SAMSUNG_BLOCKCHAIN:Z = false"
if [[ "$TARGET_SECURITY_CONFIG_ESE_CHIP_VENDOR" == "none" ]] && [[ "$TARGET_SECURITY_CONFIG_ESE_COS_NAME" == "none" ]]; then
    :
#    :
##    :
##    APPLY_PATCH "system" "system/framework/services.jar" \
#        "$MODPATH/ese+blockchain/services.jar/0001-Nuke-BlockchainTZService.patch"
else
    APPLY_PATCH "system" "system/framework/services.jar" \
        "$MODPATH/blockchain/services.jar/0001-Nuke-BlockchainTZService.patch"
fi

# TODO get rid of the following features
# SEC_PRODUCT_FEATURE_KNOX_SUPPORT_UCS
# SEC_PRODUCT_FEATURE_FRAMEWORK_SUPPORT_MOBILE_PAYMENT

LOG "- Restoring original SourceFile attribute in /system/system/framework/services.jar"
find "$APKTOOL_DIR/system/framework/services.jar" -type f -name "*.smali" -print0 \
    | xargs -0 -I "{}" -P "$(nproc)" sed -i "s/^\.source.*/$SOURCE_FILE_ATTR/g" "{}"

unset SOURCE_FILE_ATTR
