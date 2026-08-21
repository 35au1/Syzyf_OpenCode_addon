@echo off
setlocal EnableDelayedExpansion

rem start_syzyf.bat - run the Definition of Done loop with a live view of it.
rem
rem   start_syzyf.bat                       pick a run in the window, then launch
rem   start_syzyf.bat "your directive"      optional, overrides cycle 0's directive
rem   set DOD_RUN_ID=00003                  preselect that run in the window
rem   set DOD_LOOP_NO_REVIEW=1              skip the window entirely and launch straight away
rem   set DOD_LOOP_TEXT_REVIEW=1            review in %EDITOR% instead of the window
rem   set DOD_LOOP_NO_GUI=1                 headless: no TUI, monitor with status.ps1
rem   set EDITOR=code -w                    editor for the text fallback (default: notepad)
rem
rem THE REVIEW WINDOW STAYS OPEN FOR THE WHOLE RUN
rem
rem definition-gui.ps1 does two jobs, which is why it is started in the background and never waited on:
rem
rem   1. It picks the run. Every folder under projectfiles\ is listed with where it stopped, so a run
rem      that died mid-cycle is resumed by clicking it. It allocates a new run itself when you choose
rem      "New run", so quitting never leaves an empty folder behind. The chosen id comes back through
rem      the signal file below, because a window that stays open cannot answer with an exit code.
rem
rem   2. It keeps editing the definition while the loop runs. Saving rewrites the live run's
rem      definition.md, and the loop re-reads that file at the start of every cycle, so a correction
rem      lands on the next cycle. Closing the window does not stop the run.
rem
rem EVERY GENERATED FILE LIVES UNDER projectfiles\<run id>\
rem   definition.md            the Definition of Done this run is judged against, seeded from .opencode\dod.md
rem   definition.original.md   what the run was launched with, written once, never edited
rem   state.md                 the handoff notes carried between cycles
rem   run.log                  the full transcript
rem A run id is five digits and iterates: 00001, 00002, ... Session titles use it too, so the TUI
rem picker shows "00001 work 0" and "00001 verify 0".
rem
rem .opencode\dod.md is the TEMPLATE. Each run copies it once, so correcting a run's definition never
rem changes what an earlier run was judged against. Edit the template to change the starting point for
rem future runs.
rem
rem Runs unbounded: it keeps opening fresh sessions until DOD_PASS_STREAK consecutive independent
rem verdicts say the DoD is met. Set DOD_CYCLE_BUDGET to cap it.
rem
rem Model fallback: both turns walk a chain and move to the next model when one reports "Free usage
rem exceeded". Defaults to deepseek-v4-flash-free -> big-pickle -> mimo-v2.5-free. Override with
rem   set DOD_WORK_MODELS=deepseek-v4-flash-free,big-pickle
rem   set DOD_VERIFY_MODELS=big-pickle,mimo-v2.5-free
rem   set DOD_QUOTA_COOLDOWN_MS=900000     how long to wait when the whole chain is rate-limited
rem
rem The server does not report a quota refusal back to the loop: it treats it as retryable and holds
rem the request open, retrying on its own hours-long schedule. So each turn is watched via
rem GET /session/status instead of waited on, and abandoned as soon as a refusal appears there.
rem   set DOD_TURN_POLL_MS=5000            how often to check a running turn
rem   set DOD_RETRY_TOLERANCE_MS=60000     a retry due sooner than this is transient and worth waiting for
rem   set DOD_TURN_DEADLINE_MS=2700000     backstop for a turn that wedges without the server saying so
rem
rem ---------------------------------------------------------------------------------------------
rem WHY THE TUI OWNS THE SERVER
rem
rem Started as `opencode --port N`, the TUI always spawns its own server in a worker (see
rem cli/cmd/tui.ts), and even `--port` only tells THAT worker which port to bind. It never dials an
rem external server and it never reads OPENCODE_BASE_URL. (There is a separate `opencode attach <url>`
rem command, untested here, which may lift that restriction.)
rem
rem So the old arrangement - `opencode serve` for the loop, plus a separate `opencode` TUI - gave two
rem processes with two event buses over one shared SQLite store. The TUI could read the loop's
rem sessions, but every event came from the loop server's bus, so the window rendered a snapshot and
rem then sat frozen. It looked like the agent was stuck when it was not.
rem
rem Inverting it fixes that. `opencode --port N` makes the TUI's own worker bind N and serve the full
rem API, and that worker forwards every GlobalBus event straight to the TUI. Point the loop at N and
rem its sessions run inside that worker, so they stream live.
rem
rem The tradeoff: the TUI window IS the server. Closing it ends the run. The review window is the
rem opposite - closing that one costs nothing but the ability to edit.
rem ---------------------------------------------------------------------------------------------

cd /d "%~dp0"
set "PATH=%USERPROFILE%\.bun\bin;%PATH%"
if "%PORT%"=="" set "PORT=4096"
set "OPENCODE_BASE_URL=http://localhost:%PORT%"
set "STARTED_SERVE="
set "SERVER_PID="
set "GUI_PID="
set "LOOP_EXIT=1"
if not defined EDITOR set "EDITOR=notepad"

rem Several runs at once is a supported way to work, so nothing here may be a fixed shared filename.
rem Two launchers with one signal file fight over it: the first window's answer gets deleted, or the
rem second launcher reads the first window's run id and launches somebody else's run. A per-launch token
rem keeps each handshake private.
set "GUI_SCRIPT=%~dp0definition-gui.ps1"
set "GUI_DIR=%CD%\projectfiles\_gui"
set "TOKEN=%RANDOM%%RANDOM%"
set "SIGNAL=!GUI_DIR!\launch-!TOKEN!.txt"
set "GUI_PIDFILE=!GUI_DIR!\gui-!TOKEN!.pid"
set "GUI_BOUNDS="
set "TUI_BOUNDS="

rem ---------------------------------------------------------------- layout
rem A starting arrangement for the two windows that matter: Syzyf down the left edge at full height, the
rem TUI filling everything to its right. Both are drawn by different processes, so the split is computed
rem once by layout.ps1 and handed to each of them. Drag them afterwards and they stay dragged.
rem   set DOD_LOOP_NO_LAYOUT=1     leave every window wherever Windows puts it
if defined DOD_LOOP_NO_LAYOUT goto :nolayout
if not exist "%~dp0layout.ps1" goto :nolayout
for /f "usebackq tokens=1,2 delims=|" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0layout.ps1" -Plan`) do (
  set "GUI_BOUNDS=%%A"
  set "TUI_BOUNDS=%%B"
)
:nolayout

echo === Definition of Done loop ===
echo project: %CD%
echo port:    %PORT%
echo.

rem ---------------------------------------------------------------- checks
where bun >nul 2>&1
if errorlevel 1 (
  echo ERROR: bun not found on PATH.
  echo Add %%USERPROFILE%%\.bun\bin to PATH, or install Bun from https://bun.com/install
  goto :done
)
where opencode >nul 2>&1
if errorlevel 1 (
  echo ERROR: opencode not found on PATH.
  goto :done
)
if not exist "dod-loop.ts" (
  echo ERROR: dod-loop.ts not found in %CD%.
  goto :done
)
if not exist ".opencode\dod.md" (
  echo ERROR: .opencode\dod.md not found. That is the template definition; write your rules there first.
  goto :done
)

rem --------------------------------------------------------------- directive
rem Optional. When empty, dod-loop.ts derives cycle 0's directive from the run's definition.
set "DIRECTIVE=%~1"
set "DIRECTIVE_SHOWN=!DIRECTIVE!"
if not defined DIRECTIVE set "DIRECTIVE_SHOWN=(from definition.md)"

rem ---------------------------------------------------------------- review
rem Nothing starts until the operator has seen and approved what this run is aiming at. Getting the
rem definition wrong is the expensive mistake here: the loop will chase a wrong rule for as many
rem cycles as you give it, and every cycle costs a full context window.
if defined DOD_LOOP_NO_REVIEW goto :allocate
if defined DOD_LOOP_TEXT_REVIEW goto :allocate
if not exist "!GUI_SCRIPT!" (
  echo NOTE: definition-gui.ps1 is missing, so the review step will use %EDITOR%.
  goto :allocate
)

rem The window owns run selection AND stays open afterwards, so it is started in the background and
rem answers through a file instead of an exit code.
if not exist "!GUI_DIR!" mkdir "!GUI_DIR!" >nul 2>&1
if exist "!SIGNAL!" del /q "!SIGNAL!" >nul 2>&1
if exist "!GUI_PIDFILE!" del /q "!GUI_PIDFILE!" >nul 2>&1

echo opening the review window: pick a run, edit it, then Save and launch.
echo   It stays open for the whole run so you can correct the definition later.
echo.

rem Paths travel in environment variables and quotes are built with [char]34, so a project folder with
rem a space in its name survives both the cmd and the PowerShell parse.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $a=@('-NoProfile','-Sta','-ExecutionPolicy','Bypass','-File',($q+$env:GUI_SCRIPT+$q),'-Signal',($q+$env:SIGNAL+$q)); if ($env:DOD_RUN_ID) { $a += @('-RunId',$env:DOD_RUN_ID) }; if ($env:GUI_BOUNDS) { $a += @('-Bounds',$env:GUI_BOUNDS) }; $p=Start-Process -FilePath 'powershell.exe' -ArgumentList $a -PassThru; Set-Content -LiteralPath $env:GUI_PIDFILE -Value $p.Id -Encoding ASCII"
if not exist "!GUI_PIDFILE!" (
  echo ERROR: could not start the review window. Set DOD_LOOP_TEXT_REVIEW=1 to review in %EDITOR% instead.
  goto :done
)
set /p GUI_PID=<"!GUI_PIDFILE!"

:waitgui
if exist "!SIGNAL!" goto :readsignal
rem The window normally writes "quit" on its way out. This catches the case where it died instead.
tasklist /FI "PID eq !GUI_PID!" 2>nul | find "!GUI_PID!" >nul
if errorlevel 1 (
  echo.
  echo the review window closed without launching anything.
  set "LOOP_EXIT=0"
  goto :done
)
timeout /t 1 /nobreak >nul 2>&1
goto :waitgui

:readsignal
set "APPROVED="
set /p APPROVED=<"!SIGNAL!"
del /q "!SIGNAL!" >nul 2>&1
if /i "!APPROVED!"=="quit" goto :cancelled
if not defined APPROVED goto :cancelled
set "DOD_RUN_ID=!APPROVED!"
echo launching run !DOD_RUN_ID!
goto :haverun

rem ------------------------------------------------------------- allocation
rem The text-review and no-review paths still allocate here, because only the window knows how to ask
rem which run you meant.
:allocate
if defined DOD_RUN_ID goto :resume

for /f "usebackq tokens=1-3 delims=|" %%A in (`bun dod-loop.ts --prepare`) do (
  set "DOD_RUN_ID=%%A"
)
if not defined DOD_RUN_ID (
  echo ERROR: could not allocate a run folder. See the error above.
  goto :done
)
echo allocated run !DOD_RUN_ID!
goto :reviewtext

:resume
echo resuming run !DOD_RUN_ID!

:reviewtext
set "RUN_DIR=%CD%\projectfiles\!DOD_RUN_ID!"
set "DEF_FILE=!RUN_DIR!\definition.md"
if not exist "!DEF_FILE!" (
  echo ERROR: run !DOD_RUN_ID! has no definition at !DEF_FILE!
  echo Clear DOD_RUN_ID to allocate a fresh run.
  goto :done
)
if defined DOD_LOOP_NO_REVIEW goto :haverun

rem Fallback for a machine without WinForms, or for DOD_LOOP_TEXT_REVIEW. Straight into the editor,
rem no prompt first: nobody opens this to admire it. This path cannot stay open during the run, so
rem mid-run corrections need the window or a text editor of your own.
echo editing the definition for run !DOD_RUN_ID! in %EDITOR%
echo   !DEF_FILE!
echo   Section 1 is the task, section 2 is the Definition of Done. Save and close to continue.
%EDITOR% "!DEF_FILE!"
echo.
choice /C LQ /N /M "[L]aunch   [Q]uit : "
if errorlevel 2 goto :cancelled
goto :haverun

:cancelled
echo.
echo cancelled. Nothing was launched.
if defined DOD_RUN_ID echo Run folder projectfiles\!DOD_RUN_ID! is kept; pick it in the window to resume it.
set "LOOP_EXIT=0"
goto :done

:haverun
set "RUN_DIR=%CD%\projectfiles\!DOD_RUN_ID!"
set "DEF_FILE=!RUN_DIR!\definition.md"
if not exist "!DEF_FILE!" (
  echo ERROR: run !DOD_RUN_ID! has no definition at !DEF_FILE!
  goto :done
)
for %%S in ("!DEF_FILE!") do if %%~zS EQU 0 (
  echo ERROR: the definition is empty. Nothing to work towards.
  goto :done
)
echo files:   !RUN_DIR!
echo.

rem ---------------------------------------------------------------- server
:server
call :portopen
if not errorlevel 1 goto :inuse

if defined DOD_LOOP_NO_GUI goto :headless

rem --- default: the TUI owns the server, so its event bus is the loop's event bus
echo starting the opencode TUI, which owns the server on port %PORT% ...
if defined TUI_BOUNDS (
  rem layout.ps1 starts it and moves its window: a console window can only be placed through its handle,
  rem and a process object is the only dependable way to get that handle.
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0layout.ps1" -StartTui -Rect "!TUI_BOUNDS!" -Port %PORT% -WorkDir "%CD%"
) else (
  start "opencode TUI" cmd /k opencode --port %PORT%
)
call :waitport
if errorlevel 1 (
  echo ERROR: the TUI never started listening on port %PORT%.
  echo Look at the TUI window for the reason, then try again.
  goto :done
)
echo TUI up and serving port %PORT%
echo.
echo   To watch a cycle: focus the TUI, press ctrl+p, pick "!DOD_RUN_ID! work 0" or "!DOD_RUN_ID! verify 0".
echo   Updates are live because the loop runs inside that window's server.
echo   Do NOT close the TUI while the loop runs - it is the server.
goto :runloop

:headless
echo DOD_LOOP_NO_GUI is set: starting a headless opencode serve ...
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "(Start-Process -FilePath 'opencode' -ArgumentList 'serve','--port','%PORT%' -PassThru -WindowStyle Minimized).Id"`) do set "SERVER_PID=%%P"
if not defined SERVER_PID (
  echo ERROR: could not start opencode serve.
  goto :done
)
set "STARTED_SERVE=1"
call :waitport
if errorlevel 1 (
  echo ERROR: server never started listening on port %PORT%.
  goto :stopserve
)
echo serve up, pid !SERVER_PID!  ^(no live view; run status.ps1 to check progress^)
goto :runloop

:inuse
echo port %PORT% is already in use, so the loop will attach to whatever is there.
echo   If that is an old "opencode serve" rather than a TUI, you will get NO live updates:
echo   the TUI cannot attach to an external server, so a separate window would show a frozen
echo   snapshot. Close whatever owns port %PORT% and run this again for a live view.
echo.

:runloop
echo run:       !DOD_RUN_ID!
echo directive: !DIRECTIVE_SHOWN!
echo.
rem This console is now just a transcript, and the same text goes to run.log, so it gets out of the way
rem of the two windows that are worth looking at. Restore it from the taskbar whenever.
if defined GUI_BOUNDS (
  echo minimising this window: the run continues, and everything here is also in run.log
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0layout.ps1" -MinimizeParent >nul 2>&1
)
bun dod-loop.ts "!DIRECTIVE!"
set "LOOP_EXIT=!ERRORLEVEL!"

:stopserve
rem Only ever stop a server this script started headlessly. The TUI's server belongs to the TUI, and
rem killing it would take the user's window down with it. The review window is left alone too: it is
rem the operator's, and it is the fastest way to read what the run was aiming at.
if not defined STARTED_SERVE goto :report
if not defined SERVER_PID goto :report
echo.
echo stopping opencode serve, pid !SERVER_PID!
taskkill /PID !SERVER_PID! /T /F >nul 2>&1

:report
echo.
rem 0 = met, 1 = budget reached, 2 = something broke. Distinguishing these matters: "not done" and
rem "crashed" need completely different responses from you.
if "!LOOP_EXIT!"=="0" (
  echo RESULT: Definition of Done met.
) else if "!LOOP_EXIT!"=="1" (
  echo RESULT: not done - cycle budget reached. Raise DOD_CYCLE_BUDGET, or unset it for no limit.
) else (
  echo RESULT: FAILED - the run stopped on an error, exit code !LOOP_EXIT!.
  echo See the error above, and the full transcript in !RUN_DIR!\run.log
)
if defined RUN_DIR echo files:  !RUN_DIR!
if not defined STARTED_SERVE if not defined DOD_LOOP_NO_GUI (
  echo.
  echo The TUI window is still open and still serving port %PORT%. Close it when you are done.
)
if defined GUI_PID (
  echo The review window is still open. Close it whenever; it does not affect this result.
)

:done
echo.
if not defined DOD_LOOP_NO_PAUSE pause
endlocal & exit /b %LOOP_EXIT%

rem ---------------------------------------------------------------- helpers

:portopen
rem errorlevel 0 when something is listening on %PORT%
powershell -NoProfile -Command "$c=New-Object Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1',%PORT%); exit 0 } catch { exit 1 } finally { $c.Dispose() }" >nul 2>&1
exit /b %ERRORLEVEL%

:waitport
rem poll for up to 90 seconds; the TUI has to boot a worker and a server before it binds
powershell -NoProfile -Command "for($i=0;$i -lt 180;$i++){ $c=New-Object Net.Sockets.TcpClient; try { $c.Connect('127.0.0.1',%PORT%); exit 0 } catch { Start-Sleep -Milliseconds 500 } finally { $c.Dispose() } }; exit 1" >nul 2>&1
exit /b %ERRORLEVEL%
