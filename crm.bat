@echo off
setlocal enabledelayedexpansion
REM ============================================================
REM  CEO Advisors CRM — Punto de entrada UNIFICADO
REM
REM  Detecta automaticamente que hacer:
REM    - Si hay un JSON exportado del CRM mas reciente que el Excel
REM      → MODO SYNC (CRM → Excel → HTML)
REM    - Si no, o el Excel es mas reciente
REM      → MODO INJECT (Excel → HTML)
REM ============================================================

cd /d "%~dp0"

echo.
echo ================================================================
echo   CEO Advisors CRM
echo ================================================================
echo.

REM ─── 1. Detectar Excel abierto ───
if exist "~$CEO_Advisors_CRM_DataTemplate_v2.xlsx" (
    echo [AVISO] La plantilla Excel parece estar abierta.
    echo         Cierrala antes de continuar para que pueda escribir en ella.
    echo.
)

REM ─── 2. Detectar _v2.NEW.xlsx (residuo de un sync anterior con Excel abierto) ───
if exist "CEO_Advisors_CRM_DataTemplate_v2.NEW.xlsx" (
    echo [AVISO] Existe CEO_Advisors_CRM_DataTemplate_v2.NEW.xlsx
    echo         de un sync anterior cuando Excel estaba abierto.
    echo.
    set /p CONSOLIDAR="¿Consolidarlo ahora sobre el _v2.xlsx? (s/n): "
    if /i "!CONSOLIDAR!"=="s" (
        if exist "~$CEO_Advisors_CRM_DataTemplate_v2.xlsx" (
            echo [ERROR] Excel sigue abierto. Cierralo y vuelve a ejecutar.
            pause
            exit /b 1
        )
        copy /y "CEO_Advisors_CRM_DataTemplate_v2.NEW.xlsx" "CEO_Advisors_CRM_DataTemplate_v2.xlsx" >nul
        del "CEO_Advisors_CRM_DataTemplate_v2.NEW.xlsx"
        echo   ✓ Consolidado.
        echo.
    )
)

REM ─── 3. Buscar el JSON mas reciente (en esta carpeta y en Descargas) ───
set "JSON="
set "JSON_TS=0"

for %%F in ("ceoadvisors_crm_export*.json") do (
    if exist "%%F" (
        for /f "delims=" %%T in ('powershell -nologo -command "(Get-Item '%%F').LastWriteTime.ToString('yyyyMMddHHmmss')" 2^>nul') do (
            if "%%T" gtr "!JSON_TS!" (
                set "JSON=%%F"
                set "JSON_TS=%%T"
            )
        )
    )
)
for %%F in ("%USERPROFILE%\Downloads\ceoadvisors_crm_export*.json") do (
    if exist "%%F" (
        for /f "delims=" %%T in ('powershell -nologo -command "(Get-Item '%%F').LastWriteTime.ToString('yyyyMMddHHmmss')" 2^>nul') do (
            if "%%T" gtr "!JSON_TS!" (
                set "JSON=%%F"
                set "JSON_TS=%%T"
            )
        )
    )
)

REM ─── 4. Comparar con la fecha del Excel ───
set "XL_TS=0"
if exist "CEO_Advisors_CRM_DataTemplate_v2.xlsx" (
    for /f "delims=" %%T in ('powershell -nologo -command "(Get-Item 'CEO_Advisors_CRM_DataTemplate_v2.xlsx').LastWriteTime.ToString('yyyyMMddHHmmss')" 2^>nul') do set "XL_TS=%%T"
)

echo Estado:
if defined JSON (
    echo   JSON  : !JSON!  ^(ts !JSON_TS!^)
) else (
    echo   JSON  : (no encontrado)
)
echo   Excel : CEO_Advisors_CRM_DataTemplate_v2.xlsx  ^(ts !XL_TS!^)
echo.

REM ─── 5. Decidir modo ───
set "MODO="
if defined JSON (
    if "!JSON_TS!" gtr "!XL_TS!" (
        set "MODO=SYNC"
    ) else (
        echo El JSON es mas antiguo que el Excel.
        set /p USE_JSON="¿Sincronizar de todos modos con el JSON? (s/n): "
        if /i "!USE_JSON!"=="s" (
            set "MODO=SYNC"
        ) else (
            set "MODO=INJECT"
        )
    )
) else (
    set "MODO=INJECT"
)

echo Modo elegido: !MODO!
echo.

REM ─── 6. Ejecutar ───
if "!MODO!"=="SYNC" (
    echo === SYNC: !JSON! → Excel → HTML ===
    py sync.py "!JSON!"
) else (
    echo === INJECT: Excel → HTML ===
    py inject_data.py
)

set RC=%errorlevel%
echo.

if !RC! NEQ 0 (
    echo [ERROR] El proceso fallo con codigo !RC!. Revisa los mensajes arriba.
    pause
    exit /b !RC!
)

echo ================================================================
echo  ✓ Proceso completado.
echo  Abre CEO_Advisors_CRM_PRODUCTION.html en tu navegador.
echo  Si te pregunta "Hay datos nuevos. ¿Recargar?" → Aceptar.
echo ================================================================
echo.
pause
