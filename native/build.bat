@echo off
rem PalCommand native bridge -- local build.
rem Run from an "x64 Native Tools Command Prompt for VS 2022" (or any shell where
rem cl.exe is on PATH). Output: out\main.dll
rem
rem Optional: pass the target UE4SS build SHA as the first argument
rem   build.bat ba2efd55

setlocal
set SHA=%1
if "%SHA%"=="" set SHA=ba2efd55

if not exist out mkdir out

cl /nologo /LD /EHsc /std:c++17 /O2 /MD /utf-8 ^
  /DPALCOMMAND_UE4SS_SHA=\"%SHA%\" ^
  /Fe:out\main.dll ^
  "%~dp0src\bridge.cpp" ^
  /link /DLL kernel32.lib user32.lib

if errorlevel 1 (
  echo BUILD FAILED
  exit /b 1
)

echo.
echo Built out\main.dll  (UE4SS SHA target: %SHA%)
echo Install to:  ^<server^>\Pal\Binaries\Win64\ue4ss\Mods\PalCommand\dlls\main.dll
endlocal
