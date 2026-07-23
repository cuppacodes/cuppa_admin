@echo off
echo ========================================
echo  cuppa_admin Discord Bot - Installer
echo ========================================
echo.

:: Check if Node.js is installed
where node >nul 2>nul
if %errorlevel% neq 0 (
    echo Node.js is not installed.
    echo.
    echo Please install Node.js from: https://nodejs.org
    echo Download the LTS version and run the installer.
    echo.
    echo After installing Node.js, run this script again.
    pause
    exit /b 1
)

echo Node.js found:
node --version
echo.

:: Check if config.json has been edited
findstr /C:"YOUR_BOT_TOKEN" config.json >nul 2>nul
if %errorlevel% equ 0 (
    echo WARNING: config.json still has default values.
    echo Please edit config.json with your bot token and RCON password before starting.
    echo.
)

:: Install dependencies
echo Installing dependencies...
call npm install
if %errorlevel% neq 0 (
    echo.
    echo Failed to install dependencies.
    pause
    exit /b 1
)

echo.
echo ========================================
echo  Installation complete!
echo.
echo  1. Edit config.json with your settings
echo  2. Run start.bat to start the bot
echo ========================================
pause
