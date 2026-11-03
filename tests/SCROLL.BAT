@ECHO OFF
REM Endless full-screen scrolling (DOS/V graphics text) for long-running tests. Ctrl+C to stop.
:LOOP
DIR C:\DOS /W
GOTO LOOP
