#!/usr/bin/env python3
from pathlib import Path
import os
import re
import sys

def abort(msg):
    raise SystemExit("ERRO: " + msg)

if len(sys.argv) != 2:
    abort("informe o SettingsObserver.smali")

path = Path(sys.argv[1])
if not path.is_file():
    abort(f"arquivo não encontrado: {path}")

text = path.read_text(encoding="utf-8")

# Hunk 1: observer Settings.Secure/disable_secure_windows
#          -> Settings.System/unica_secure_ss
observer_old = re.compile(
    r'(?m)^(\s*)const-string/jumbo (v\d+), "disable_secure_windows"\n'
    r'\n'
    r'\1invoke-static \{\2\}, '
    r'Landroid/provider/Settings\$Secure;->getUriFor'
    r'\(Ljava/lang/String;\)Landroid/net/Uri;$'
)

observer_new = (
    r'\1const-string/jumbo \2, "unica_secure_ss"\n'
    r'\n'
    r'\1invoke-static {\2}, '
    r'Landroid/provider/Settings$System;->getUriFor'
    r'(Ljava/lang/String;)Landroid/net/Uri;'
)

old_observers = len(observer_old.findall(text))

already_observing = bool(re.search(
    r'(?ms)const-string/jumbo v\d+, "unica_secure_ss".{0,180}'
    r'Settings\$System;->getUriFor'
    r'\(Ljava/lang/String;\)Landroid/net/Uri;',
    text,
))

if old_observers == 1:
    text = observer_old.sub(observer_new, text, count=1)
elif old_observers == 0 and already_observing:
    pass
else:
    abort(
        "observer em estado inesperado: "
        f"antigos={old_observers}, novo={already_observing}"
    )

method_pattern = re.compile(
    r'(?ms)^\.method public final '
    r'updateDisableSecureWindows\(\)V\n'
    r'.*?'
    r'^\.end method$'
)

methods = list(method_pattern.finditer(text))
if len(methods) != 1:
    abort(
        "esperado um updateDisableSecureWindows()V; "
        f"encontrados: {len(methods)}"
    )

new_method = r'''.method public final updateDisableSecureWindows()V
    .locals 3

    iget-object v0, p0, Lcom/android/server/wm/WindowManagerService$SettingsObserver;->this$0:Lcom/android/server/wm/WindowManagerService;

    iget-object v0, v0, Lcom/android/server/wm/WindowManagerService;->mContext:Landroid/content/Context;

    invoke-virtual {v0}, Landroid/content/Context;->getContentResolver()Landroid/content/ContentResolver;

    move-result-object v0

    const/4 v1, 0x0

    const-string/jumbo v2, "unica_secure_ss"

    invoke-static {v0, v2, v1}, Landroid/provider/Settings$System;->getInt(Landroid/content/ContentResolver;Ljava/lang/String;I)I

    move-result v0

    if-eqz v0, :cond_0

    const/4 v1, 0x1

    :cond_0
    iget-object v0, p0, Lcom/android/server/wm/WindowManagerService$SettingsObserver;->this$0:Lcom/android/server/wm/WindowManagerService;

    iget-boolean v0, v0, Lcom/android/server/wm/WindowManagerService;->mDisableSecureWindows:Z

    if-ne v0, v1, :cond_1

    return-void

    :cond_1
    iget-object v0, p0, Lcom/android/server/wm/WindowManagerService$SettingsObserver;->this$0:Lcom/android/server/wm/WindowManagerService;

    iget-object v0, v0, Lcom/android/server/wm/WindowManagerService;->mGlobalLock:Lcom/android/server/wm/WindowManagerGlobalLock;

    invoke-static {}, Lcom/android/server/wm/WindowManagerService;->boostPriorityForLockedSection()V

    monitor-enter v0

    :try_start_0
    iget-object v2, p0, Lcom/android/server/wm/WindowManagerService$SettingsObserver;->this$0:Lcom/android/server/wm/WindowManagerService;

    iput-boolean v1, v2, Lcom/android/server/wm/WindowManagerService;->mDisableSecureWindows:Z

    iget-object p0, p0, Lcom/android/server/wm/WindowManagerService$SettingsObserver;->this$0:Lcom/android/server/wm/WindowManagerService;

    iget-object p0, p0, Lcom/android/server/wm/WindowManagerService;->mRoot:Lcom/android/server/wm/RootWindowContainer;

    invoke-virtual {p0}, Lcom/android/server/wm/RootWindowContainer;->refreshSecureSurfaceState()V

    monitor-exit v0
    :try_end_0
    .catchall {:try_start_0 .. :try_end_0} :catchall_0

    invoke-static {}, Lcom/android/server/wm/WindowManagerService;->resetPriorityAfterLockedSection()V

    return-void

    :catchall_0
    move-exception p0

    :try_start_1
    monitor-exit v0
    :try_end_1
    .catchall {:try_start_1 .. :try_end_1} :catchall_0

    invoke-static {}, Lcom/android/server/wm/WindowManagerService;->resetPriorityAfterLockedSection()V

    throw p0
.end method'''

match = methods[0]
text = text[:match.start()] + new_method + text[match.end():]

# Validação integral dos seis comportamentos.
method = method_pattern.search(text).group(0)

required = [
    '"unica_secure_ss"',
    "Settings$System;->getInt",
    "mDisableSecureWindows:Z",
    "refreshSecureSurfaceState()V",
    ":try_start_0",
    ":try_end_0",
    ".catchall {:try_start_0 .. :try_end_0} :catchall_0",
    ":try_start_1",
    ":try_end_1",
    ".catchall {:try_start_1 .. :try_end_1} :catchall_0",
]

for item in required:
    if item not in method:
        abort(f"validação ausente: {item}")

for forbidden in [
    '"ro.debuggable"',
    '"disable_secure_windows"',
    "Settings$Secure;->getIntForUser",
    "SettingNotFoundException",
]:
    if forbidden in method:
        abort(f"conteúdo antigo ainda presente no método: {forbidden}")

if not re.search(
    r'(?ms)const-string/jumbo v\d+, "unica_secure_ss".{0,180}'
    r'Settings\$System;->getUriFor',
    text,
):
    abort("observer de unica_secure_ss não foi validado")

tmp = path.with_name(path.name + ".tmp")
tmp.write_text(text, encoding="utf-8")
os.replace(tmp, path)

print("Secure windows: observer e 6 hunks validados semanticamente")
