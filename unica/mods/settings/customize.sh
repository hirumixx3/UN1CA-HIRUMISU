if [ ! "$(GET_PROP "system" "ro.unica.version")" ]; then
    SET_PROP "system" "ro.unica.version" "$ROM_VERSION"
fi

SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali/android/app/Instrumentation.smali" "replace" \
    'newApplication(Ljava/lang/Class;Landroid/content/Context;)Landroid/app/Application;' \
    'invoke-virtual {p0, p1}, Landroid/app/Application;->attach(Landroid/content/Context;)V' \
    '    invoke-virtual {p0, p1}, Landroid/app/Application;->attach(Landroid/content/Context;)V\n\n    invoke-static {p1}, Lio/mesalabs/unica/SamsungPropsHooks;->init(Landroid/content/Context;)V' \
    > /dev/null
SMALI_PATCH "system" "system/framework/framework.jar" \
    "smali/android/app/Instrumentation.smali" "replace" \
    'newApplication(Ljava/lang/ClassLoader;Ljava/lang/String;Landroid/content/Context;)Landroid/app/Application;' \
    'invoke-virtual {p0, p3}, Landroid/app/Application;->attach(Landroid/content/Context;)V' \
    '    invoke-virtual {p0, p3}, Landroid/app/Application;->attach(Landroid/content/Context;)V\n\n    invoke-static {p3}, Lio/mesalabs/unica/SamsungPropsHooks;->init(Landroid/content/Context;)V' \
    > /dev/null

DECODE_APK "system" "system/priv-app/SecSettings/SecSettings.apk"

# Android 17: resolve as classes independentemente de smali_classesN.
APPLY_SECSETTINGS_CORE_PATCHES()
{
    local SECSETTINGS_DIR
    local SOFTWARE_UPDATE_UTILS_SMALI
    local ONEUI_VERSION_CONTROLLER_SMALI
    local MODEL_NAME_GETTER_SMALI

    SECSETTINGS_DIR="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk"

    RESOLVE_SECSETTINGS_SMALI()
    {
        local OUTPUT_VARIABLE="$1"
        local RELATIVE_PATH="$2"
        local -a MATCHES=()

        mapfile -t MATCHES < <(
            find "$SECSETTINGS_DIR" \
                -type f \
                -path "*/$RELATIVE_PATH" \
                -printf '%P\n' |
                sort
        )

        if [ "${#MATCHES[@]}" -ne 1 ]; then
            printf '%s\n' \
                "ERRO: esperado exatamente um SecSettings smali para $RELATIVE_PATH; encontrados: ${#MATCHES[@]}" \
                >&2

            if [ "${#MATCHES[@]}" -gt 0 ]; then
                printf 'Candidato: %s\n' "${MATCHES[@]}" >&2
            fi

            return 1
        fi

        printf -v "$OUTPUT_VARIABLE" '%s' "${MATCHES[0]}"
    }

    RESOLVE_SECSETTINGS_SMALI \
        SOFTWARE_UPDATE_UTILS_SMALI \
        'com/samsung/android/settings/softwareupdate/SoftwareUpdateUtils.smali'

    RESOLVE_SECSETTINGS_SMALI \
        ONEUI_VERSION_CONTROLLER_SMALI \
        'com/samsung/android/settings/deviceinfo/softwareinfo/OneUIVersionPreferenceController.smali'

    RESOLVE_SECSETTINGS_SMALI \
        MODEL_NAME_GETTER_SMALI \
        'com/samsung/android/settings/deviceinfo/aboutphone/ModelNameGetter.smali'

    LOG "- SoftwareUpdateUtils: $SOFTWARE_UPDATE_UTILS_SMALI"
    LOG "- OneUIVersionPreferenceController: $ONEUI_VERSION_CONTROLLER_SMALI"
    LOG "- ModelNameGetter: $MODEL_NAME_GETTER_SMALI"

    # Disable stock OTA references on sources that still expose the old gate.
    if [ ! -f "$WORK_DIR/system/system/priv-app/ChoiDujour/ChoiDujour.apk" ]; then
        SOFTWARE_UPDATE_UTILS_FILE="$SECSETTINGS_DIR/$SOFTWARE_UPDATE_UTILS_SMALI"

        if grep -qF \
                'isOTAUpgradeAllowed(Landroid/content/Context;)Z' \
                "$SOFTWARE_UPDATE_UTILS_FILE"; then
            SMALI_PATCH "system" "system/priv-app/SecSettings/SecSettings.apk" \
                "$SOFTWARE_UPDATE_UTILS_SMALI" "return" \
                'isOTAUpgradeAllowed(Landroid/content/Context;)Z' \
                'false'
        else
            LOG "- Stock OTA gate is absent on Android 17; no OTA patch required"
        fi

        unset SOFTWARE_UPDATE_UTILS_FILE
    fi

    # Always show One UI minor version
    ONEUI_VERSION_CONTROLLER_FILE="$SECSETTINGS_DIR/$ONEUI_VERSION_CONTROLLER_SMALI"

    ONEUI_VERSION_METHOD="$(
        sed -n \
            '/^\.method .*isDeviceWithMicroVersion()Z$/,/^\.end method$/p' \
            "$ONEUI_VERSION_CONTROLLER_FILE"
    )"

    if grep -qF 'const/4 p0, 0x1' <<< "$ONEUI_VERSION_METHOD" &&
            grep -qF 'return p0' <<< "$ONEUI_VERSION_METHOD"; then
        LOG "- isDeviceWithMicroVersion() already returns true; patch not required"
    elif grep -qF 'move-result p0' <<< "$ONEUI_VERSION_METHOD"; then
        SMALI_PATCH "system" "system/priv-app/SecSettings/SecSettings.apk" \
            "$ONEUI_VERSION_CONTROLLER_SMALI" "replace" \
            'isDeviceWithMicroVersion()Z' \
            'move-result p0' \
            'const/4 p0, 0x1'
    else
        LOGE "Unsupported isDeviceWithMicroVersion()Z structure"

        printf '%s\n' "$ONEUI_VERSION_METHOD" >&2
        return 1
    fi

    unset ONEUI_VERSION_METHOD
    unset ONEUI_VERSION_CONTROLLER_FILE

    # Show real device model number
    SMALI_PATCH "system" "system/priv-app/SecSettings/SecSettings.apk" \
        "$MODEL_NAME_GETTER_SMALI" "replace" \
        'getModelName()Ljava/lang/String;' \
        'ro.product.model' \
        'ro.boot.em.model'

    unset -f RESOLVE_SECSETTINGS_SMALI
}

APPLY_SECSETTINGS_CORE_PATCHES
unset -f APPLY_SECSETTINGS_CORE_PATCHES

LOG_STEP_IN "- Adding UN1CA Settings"

# Dynamically patch SecSettings
# - Add missing/non-xml files in place
# - Patch existing files
#   - Use the first line of the file to tell sed how to apply the rest of the content
#   - Exception made for files under *res/values* where the "resources" tag gets nuked
while IFS= read -r f; do
    f="${f//$MODPATH\/SecSettings.apk\//}"

    if [ ! -f "$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk/$f" ] || \
            [[ "$f" != *".xml" ]]; then
        LOG "- Adding \"$f\" to /system/system/priv-app/SecSettings.apk"
        EVAL "mkdir -p \"$(dirname "$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk/$f")\""
        EVAL "cp -a \"$MODPATH/SecSettings.apk/${f//\$/\\$}\" \"$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk/${f//\$/\\$}\""
    else
        LOG "- Patching \"$f\" in /system/system/priv-app/SecSettings.apk"
        if [[ "$f" == *"res/values"* ]]; then
            PATCH_INST="/<\/resources>/i"
            CONTENT="$(sed -e "/?xml/d" -e "/resources>/d" "$MODPATH/SecSettings.apk/$f")"
        else
            PATCH_INST="$(head -n 1 "$MODPATH/SecSettings.apk/$f")"
            CONTENT="$(tail -n +2 "$MODPATH/SecSettings.apk/$f")"
        fi
        CONTENT="$(sed -e "s/\"/\\\\\"/g" -e "s/\\$/\\\\$/g" -e "s/ /\\\ /g" -e "s/\\\\n/\\\\\\\\\n/g" <<< "$CONTENT")"
        CONTENT="$(sed -E ':a;N;$!ba;s/\r{0,1}\n/\\n/g' <<< "$CONTENT")"
        EVAL "sed -i \"$PATCH_INST $CONTENT\" \"$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk/$f\""
    fi
done < <(find "$MODPATH/SecSettings.apk" -type f \
    ! -name "*.bak*" \
    ! -name "*.orig" \
    ! -name "*.rej")

# Mark UN1CA Settings fragments as "valid"
LOG "- Patching \"smali/com/android/settings/core/gateway/SettingsGateway.smali\" in /system/system/priv-app/SecSettings.apk"

SETTINGS_GATEWAY_SMALI="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk/smali/com/android/settings/core/gateway/SettingsGateway.smali"

if ! python3 \
        "$MODPATH/apply_settings_gateway_fragments.py" \
        "$SETTINGS_GATEWAY_SMALI"; then
    LOGE "Failed to adapt SettingsGateway SAMSUNG_ENTRY_FRAGMENTS"
    return 1
fi

unset SETTINGS_GATEWAY_SMALI

LOG "- Patching \"smali/com/android/settings/SettingsActivity.smali\" in /system/system/priv-app/SecSettings.apk"

SETTINGS_GATEWAY_SMALI="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk/smali/com/android/settings/core/gateway/SettingsGateway.smali"
SETTINGS_ACTIVITY_SMALI="$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk/smali/com/android/settings/SettingsActivity.smali"

if ! python3 "$MODPATH/apply_settings_activity_fragment_count.py" \
        "$SETTINGS_GATEWAY_SMALI" \
        "$SETTINGS_ACTIVITY_SMALI"; then
    LOGE "Failed to adapt SettingsActivity fragment count"
    return 1
fi

unset SETTINGS_GATEWAY_SMALI
unset SETTINGS_ACTIVITY_SMALI

# Add UN1CA Settings SearchIndexDataProvider(s)
LOG "- Patching Settings search index providers in /system/system/priv-app/SecSettings.apk"
SEARCH_INDEX_RESOURCES="$(
    find "$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk" \
        -path '*/com/android/settings/search/SearchFeatureProviderImpl$$ExternalSyntheticLambda0.smali' \
        -print -quit
)"
if [ ! "$SEARCH_INDEX_RESOURCES" ]; then
    LOGE "Settings search provider registry not found in /system/system/priv-app/SecSettings.apk"
    return 1
fi
SEARCH_INDEX_RESOURCES_SMALI="${SEARCH_INDEX_RESOURCES#$APKTOOL_DIR/system/priv-app/SecSettings/SecSettings.apk/}"

ADD_UNICA_SETTINGS_SEARCH_INDEX_DATA_PROVIDER()
{
    local FRAGMENT="$1"

    if grep -q "L$FRAGMENT;->SEARCH_INDEX_DATA_PROVIDER" "$SEARCH_INDEX_RESOURCES"; then
        return 0
    fi

    SMALI_PATCH "system" "system/priv-app/SecSettings/SecSettings.apk" \
        "$SEARCH_INDEX_RESOURCES_SMALI" "replace" \
        'invoke()Ljava/lang/Object;' \
        'new-instance v0, Lcom/android/settingslib/spa/search/SearchIndexableDataConverter;' \
        "    new-instance v0, Lcom/android/settingslib/search/SearchIndexableData;\n\n    const-class v1, L$FRAGMENT;\n\n    sget-object v2, L$FRAGMENT;->SEARCH_INDEX_DATA_PROVIDER:Lcom/android/settings/search/BaseSearchIndexProvider;\n\n    invoke-direct {v0, v1, v2}, Lcom/android/settingslib/search/SearchIndexableData;-><init>(Ljava/lang/Class;Lcom/android/settingslib/search/Indexable\$SearchIndexProvider;)V\n\n    invoke-virtual {p0, v0}, Lcom/android/settingslib/search/SearchIndexableResourcesBase;->addIndex(Lcom/android/settingslib/search/SearchIndexableData;)V\n\n    new-instance v0, Lcom/android/settingslib/spa/search/SearchIndexableDataConverter;" \
        > /dev/null
}

for f in \
    "io/mesalabs/unica/settings/UnicaSettingsFragment" \
    "io/mesalabs/unica/settings/extra/ExtraSettingsFragment" \
    "io/mesalabs/unica/settings/hma/HideMyApplistFragment" \
    "io/mesalabs/unica/settings/spoof/HideDeveloperStatusFragment" \
    "io/mesalabs/unica/settings/spoof/SpoofSettingsFragment" \
    "io/mesalabs/unica/settings/ui/UISettingsFragment" \
    "io/mesalabs/unica/settings/spoof/CameraFeatureFragment" \
    "io/mesalabs/unica/settings/extra/ScpmAllowlistFragment"; do
    ADD_UNICA_SETTINGS_SEARCH_INDEX_DATA_PROVIDER "$f" || return 1
done

DECODE_APK "system" "system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk"
LOG "- Patching Settings Intelligence top-level keys in /system/system/priv-app/SecSettingsIntelligence.apk"
TOP_LEVEL_KEYS_COLLECTOR="$(
    find "$APKTOOL_DIR/system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk" \
        -path '*/com/samsung/android/settings/intelligence/search/categorizing/TopLevelKeysCollector.smali' \
        -print -quit
)"
if [ ! "$TOP_LEVEL_KEYS_COLLECTOR" ]; then
    LOGE "TopLevelKeysCollector smali not found in /system/system/priv-app/SecSettingsIntelligence.apk"
    return 1
fi
TOP_LEVEL_KEYS_COLLECTOR_SMALI="${TOP_LEVEL_KEYS_COLLECTOR#$APKTOOL_DIR/system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk/}"

if ! python3 \
        "$MODPATH/apply_top_level_unica.py" \
        "$TOP_LEVEL_KEYS_COLLECTOR"; then
    LOGE "Failed to adapt TopLevelKeysCollector top_level_unica"
    return 1
fi

# Show Vulkan renderer toggle if required
if [[ "$(GET_PROP "ro.hwui.use_vulkan")" != "true" ]]; then
    SET_PROP "system" "persist.sys.unica.vulkan" "false"
fi

unset -f ADD_UNICA_SETTINGS_SEARCH_INDEX_DATA_PROVIDER
unset PATCH_INST CONTENT SEARCH_INDEX_RESOURCES SEARCH_INDEX_RESOURCES_SMALI TOP_LEVEL_KEYS_COLLECTOR TOP_LEVEL_KEYS_COLLECTOR_SMALI

LOG_STEP_OUT

# Android 17 semantic replacement for Allow disabling secure windows.
DECODE_APK "system" "system/framework/services.jar"

SECURE_WINDOWS_OBSERVER="$(
    find "$APKTOOL_DIR/system/framework/services.jar" \
        -type f \
        -path '*/com/android/server/wm/WindowManagerService$SettingsObserver.smali' \
        -print -quit
)"

if [ -z "$SECURE_WINDOWS_OBSERVER" ]; then
    LOGE "WindowManagerService SettingsObserver smali not found"
    return 1
fi

if ! python3 \
        "$MODPATH/apply_secure_windows_semantic.py" \
        "$SECURE_WINDOWS_OBSERVER"; then
    LOGE "Failed to apply secure windows semantic patch"
    return 1
fi

unset SECURE_WINDOWS_OBSERVER

# Android 17 semantic replacement for Allow disable ASKS.
DECODE_APK "system" "system/framework/services.jar"

ASKS_MANAGER_SMALI="$(
    find "$APKTOOL_DIR/system/framework/services.jar" \
        -type f \
        -path '*/com/android/server/asks/ASKSManagerService.smali' \
        -print -quit
)"

if [ -z "$ASKS_MANAGER_SMALI" ]; then
    LOGE "ASKSManagerService.smali not found"
    return 1
fi

if ! python3 \
        "$MODPATH/apply_asks_semantic.py" \
        "$ASKS_MANAGER_SMALI"; then
    LOGE "Failed to apply ASKS semantic patch"
    return 1
fi

unset ASKS_MANAGER_SMALI

# Android 17 semantic replacement for GNSS location toggle.
DECODE_APK "system" "system/framework/services.jar"

GNSS_SERVICES_DIR="$APKTOOL_DIR/system/framework/services.jar"

if ! python3 \
        "$MODPATH/apply_gnss_toggle_semantic.py" \
        "$GNSS_SERVICES_DIR"; then
    LOGE "Failed to apply GNSS location toggle semantic patch"
    return 1
fi

unset GNSS_SERVICES_DIR
