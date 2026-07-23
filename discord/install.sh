#!/bin/bash
echo "========================================"
echo " cuppa_admin Discord Bot - Installer"
echo "========================================"
echo ""

# Check if Node.js is installed
if ! command -v node &> /dev/null; then
    echo "Node.js is not installed."
    echo ""
    echo "Install with Homebrew: brew install node"
    echo "Or download from: https://nodejs.org"
    echo ""
    echo "After installing, run this script again."
    exit 1
fi

echo "Node.js found:"
node --version
echo ""

# Check if config.json has been edited
if grep -q "YOUR_BOT_TOKEN" config.json 2>/dev/null; then
    echo "WARNING: config.json still has default values."
    echo "Please edit config.json with your bot token and RCON password before starting."
    echo ""
fi

# Install dependencies
echo "Installing dependencies..."
npm install
if [ $? -ne 0 ]; then
    echo ""
    echo "Failed to install dependencies."
    exit 1
fi

echo ""
echo "========================================"
echo " Installation complete!"
echo ""
echo " 1. Edit config.json with your settings"
echo " 2. Run ./start.sh to start the bot"
echo "========================================"
