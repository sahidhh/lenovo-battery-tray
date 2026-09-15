' Launches the tray script with a truly hidden window (no console flash at logon).
' WScript.Shell.Run intWindowStyle=0, bWaitOnReturn=False.
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\Users\sahid\scripts\lenovo-battery-tray.ps1""", 0, False
