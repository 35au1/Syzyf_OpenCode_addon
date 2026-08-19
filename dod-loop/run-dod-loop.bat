@echo off
setlocal EnableDelayedExpansion

rem run-dod-loop.bat - run the Definition of Done loop with a live view of it.
rem
rem   run-dod-loop.bat                      allocate a new run, review the definition, launch
rem   run-dod-loop.bat "your directive"     optional, overrides cycle 0's directive
rem   set DOD_RUN_ID=00003                  resume an existing run instead of allocating a new one
rem   set DOD_LOOP_NO_REVIEW=1              skip the review window and launch straight away
rem   set DOD_LOOP_TEXT_REVIEW=1            review in %EDITOR% instead of the window
rem   set DOD_LOOP_NO_GUI=1                 headless: no TUI, monitor with status.ps1
rem   set EDITOR=code -w                    editor for the text fallback (default: notepad)
rem
rem The review window is definition-gui.ps1: two editable boxes, "Task to perform" and "Definition of
rem Done", saved back as the single file the verifier is handed. The split is presentation only.
rem
rem EVERY GENERATED FILE LIVES UNDER projectfiles\<run id>\
rem   definition.md   the Definition of Done this run is judged against, seeded from .opencode\dod.md
rem   state.md        the handoff notes carried between cycles
rem   run.log         the full transcript
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
rem The opencode TUI has no attach-to-an-existing-server mode. It always spawns its own server in a
rem worker (see cli/cmd/tui.ts), and even `--port` only tells THAT worker which port to bind. It
rem never dials an external server and it never reads OPENCODE_BASE_URL.
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
rem The tradeoff: the TUI window IS the server. Closing it ends the run.
rem ---------------------------------------------------------------------------------------------

cd /d "%~dp0"
set "PATH=%USERPROFILE%\.bun\bin;%PATH%"
if "%PORT%"=="" set "PORT=4096"
set "OPENCODE_BASE_URL=http://localhost:%PORT%"
set "STARTED_SERVE="
set "SERVER_PID="
set "LOOP_EXIT=1"
if not defined EDITOR set "EDITOR=notepad"

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
if not exist "definition-gui.ps1" (
  echo NOTE: definition-gui.ps1 is missing, so the review step will use %EDITOR%.
)

rem ------------------------------------------------------------------- run
rem A new run unless DOD_RUN_ID names an existing one. --prepare creates the folder and copies the
rem template in, so the definition exists on disk before anyone is asked to approve it.
if defined DOD_RUN_ID goto :resume

for /f "usebackq tokens=1-3 delims=|" %%A in (`bun dod-loop.ts --prepare`) do (
  set "DOD_RUN_ID=%%A"
  set "RUN_DIR=%%B"
  set "DEF_FILE=%%C"
)
if not defined DOD_RUN_ID (
  echo ERROR: could not allocate a run folder. See the error above.
  goto :done
)
echo allocated run !DOD_RUN_ID!
goto :haverun

:resume
set "RUN_DIR=%CD%\projectfiles\%DOD_RUN_ID%"
set "DEF_FILE=!RUN_DIR!\definition.md"
if not exist "!DEF_FILE!" (
  echo ERROR: run %DOD_RUN_ID% has no definition at !DEF_FILE!
  echo Clear DOD_RUN_ID to allocate a fresh run.
  goto :done
)
echo resuming run !DOD_RUN_ID!

:haverun
echo files:   !RUN_DIR!
echo.

rem ------------------------------------------------------------- directive
rem Optional. When empty, dod-loop.ts derives cycle 0's directive from the run's definition.
set "DIRECTIVE=%~1"
set "DIRECTIVE_SHOWN=!DIRECTIVE!"
if not defined DIRECTIVE set "DIRECTIVE_SHOWN=(from definition.md)"

if defined DOD_LOOP_NO_REVIEW goto :server

rem ---------------------------------------------------------------- review
rem Nothing starts until the operator has seen and approved what this run is aiming at. Getting the
rem definition wrong is the expensive mistake here: the loop will chase a wrong rule for as many
rem cycles as you give it, and every cycle costs a full context window.
rem
rem definition-gui.ps1 shows it as two editable boxes - the task, and the Definition of Done - and
rem saves both back into the one file the verifier is given. Editing is the default state of that
rem window: there is no mode to switch into and no menu to walk. Exit 0 launch, 1 quit, 2 no GUI here.
:review
if defined DOD_LOOP_TEXT_REVIEW goto :textreview
if not exist "%~dp0definition-gui.ps1" goto :textreview

powershell -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0definition-gui.ps1" -Path "!DEF_FILE!" -RunId "!DOD_RUN_ID!"
set "REVIEW=!ERRORLEVEL!"
if "!REVIEW!"=="0" goto :approved
if "!REVIEW!"=="1" goto :cancelled
echo the review window could not open, using %EDITOR% instead

rem Fallback for a machine without WinForms, or for DOD_LOOP_TEXT_REVIEW. Straight into the editor,
rem no prompt first: nobody opens this to admire it.
:textreview
echo editing the definition for run !DOD_RUN_ID! in %EDITOR%
echo   !DEF_FILE!
echo   Section 1 is the task, section 2 is the Definition of Done. Save and close to continue.
%EDITOR% "!DEF_FILE!"
echo.
choice /C LQ /N /M "[L]aunch   [Q]uit : "
if errorlevel 2 goto :cancelled
goto :approved

:cancelled
echo.
echo cancelled. Run folder !RUN_DIR! is kept, resume it with:  set DOD_RUN_ID=!DOD_RUN_ID!
set "LOOP_EXIT=0"
goto :done

:approved
echo.
for %%S in ("!DEF_FILE!") do if %%~zS EQU 0 (
  echo ERROR: the definition is empty. Nothing to work towards.
  goto :done
)

rem ---------------------------------------------------------------- server
:server
call :portopen
if not errorlevel 1 goto :inuse

if defined DOD_LOOP_NO_GUI goto :headless

rem --- default: the TUI owns the server, so its event bus is the loop's event bus
echo starting the opencode TUI, which owns the server on port %PORT% ...
start "opencode TUI" cmd /k opencode --port %PORT%
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
bun dod-loop.ts "!DIRECTIVE!"
set "LOOP_EXIT=!ERRORLEVEL!"

:stopserve
rem Only ever stop a server this script started headlessly. The TUI's server belongs to the TUI, and
rem killing it would take the user's window down with it.
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
