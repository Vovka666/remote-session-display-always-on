@echo off
:: Vigil, runnable straight from a clone.
::   vigil status | doctor | on | off | ensure | setup | install | uninstall
::
:: Windows PowerShell 5.1 ships with every supported Windows, so nothing needs
:: installing first. -ExecutionPolicy Bypass applies to this call only and
:: changes no machine-wide setting.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0vigil.ps1" %*
exit /b %ERRORLEVEL%
