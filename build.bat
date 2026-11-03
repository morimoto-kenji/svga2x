@echo off
rem Build SVGA2X.COM with NASM (nasm.exe must be on PATH or set NASM=path\to\nasm.exe)
if "%NASM%"=="" set NASM=nasm
if not exist bin mkdir bin
%NASM% -f bin -o bin\SVGA2X.COM -l bin\svga2x.lst src\svga2x.asm
if errorlevel 1 exit /b 1
echo Built bin\SVGA2X.COM
