@echo off
echo ========================================
echo  cuppa_admin Discord Bridge - Setup
echo ========================================
echo.

where node >nul 2>nul
if %errorlevel% neq 0 (
    echo Node.js is not installed.
    echo Download from: https://nodejs.org (LTS version)
    echo Then run this script again.
    pause
    exit /b 1
)

echo Node.js found:
node --version
echo.

findstr /C:"YOUR_BOT_TOKEN" config.json >nul 2>nul
if %errorlevel% equ 0 (
    echo WARNING: Edit config.json first with your bot token.
    echo.
)

echo Installing dependencies...
call npm install
if %errorlevel% neq 0 (
    echo Failed to install dependencies.
    pause
    exit /b 1
)

echo.
echo ========================================
echo  Setup complete!
echo.
echo  1. Edit config.json with your bot token
echo  2. Run start.bat to start the bot
echo ========================================
pause
