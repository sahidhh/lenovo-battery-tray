' Launches the tray script (relative to this file) with a truly hidden window (no console flash at logon).
' WScript.Shell.Run intWindowStyle=0, bWaitOnReturn=False.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & dir & "\lenovo-battery-tray.ps1""", 0, False
