@echo off
setlocal
if "%QVW_TEST_MODE%"=="1" (
    rem Fixture-only smoke: never install into the user's active Hermes.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qvw.ps1" -Action doctor -HermesRoot "%~dp0tests\fixtures\hermes\active" -NonInteractive
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qvw.ps1" -Action install
)
set "QVW_EXIT=%ERRORLEVEL%"
echo.
if not "%QVW_EXIT%"=="0" echo 安装未完成，请运行“千问视觉管理.cmd”查看诊断。
if not "%QVW_TEST_MODE%"=="1" pause
exit /b %QVW_EXIT%
