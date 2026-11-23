kill -9 $(ps aux | grep -iE 'vscode-server|server-main.js' | grep -v grep | awk '{print $2}') 2>/dev/null || true
rm -rf /root/.vscode-server /root/.vscode-server-insiders
