@echo off
setlocal EnableExtensions EnableDelayedExpansion
if "%QVW_TEST_MODE%"=="1" (
    if not defined QVW_TEST_ACTION set "QVW_TEST_ACTION=2"
    set "QVW_CHOICE=!QVW_TEST_ACTION!"
) else (
    echo 千问视觉管理
    echo 1. 安装或修复
    echo 2. 运行只读诊断
    echo 3. 运行图片验收
    echo 4. 查看状态
    echo 5. 回滚收据
    echo 6. 导出脱敏诊断
    echo 7. 安装可选 Qwen-MM
    echo 8. 生成发布包
    set /p "QVW_CHOICE=请选择操作 [1-8]: "
)
if /i "!QVW_CHOICE!"=="1" set "QVW_ACTION=install"
if /i "!QVW_CHOICE!"=="2" set "QVW_ACTION=doctor"
if /i "!QVW_CHOICE!"=="3" set "QVW_ACTION=verify"
if /i "!QVW_CHOICE!"=="4" set "QVW_ACTION=status"
if /i "!QVW_CHOICE!"=="5" set "QVW_ACTION=rollback"
if /i "!QVW_CHOICE!"=="6" set "QVW_ACTION=diagnostics"
if /i "!QVW_CHOICE!"=="7" set "QVW_ACTION=qwen-mm"
if /i "!QVW_CHOICE!"=="8" set "QVW_ACTION=package"
if not defined QVW_ACTION (
    echo 无效的操作。
    exit /b 2
)
if "%QVW_TEST_MODE%"=="1" (
    rem Fixture-only smoke: never inspect or change the user's active Hermes.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qvw.ps1" -Action doctor -HermesRoot "%~dp0tests\fixtures\hermes\active" -NonInteractive
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0qvw.ps1" -Action !QVW_ACTION!
)
set "QVW_EXIT=%ERRORLEVEL%"
if not "%QVW_TEST_MODE%"=="1" pause
exit /b %QVW_EXIT%
