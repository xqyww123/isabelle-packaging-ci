@echo off
rem :=====================================================================:
rem : Isabelle command-line wrapper for Windows.                          :
rem :                                                                     :
rem : Location: <ISABELLE_HOME>\bin\isabelle.bat -- i.e. exactly where    :
rem : the Unix "bin/isabelle" lives, so the user instruction is uniform   :
rem : on every platform: put <ISABELLE_HOME>/bin on the PATH.             :
rem :                                                                     :
rem : The script is RELOCATABLE: ISABELLE_HOME is derived from the        :
rem : script's own location (bin\.. == ISABELLE_HOME).  No absolute path  :
rem : is baked in, which is what lets it be shipped inside a conda        :
rem : package, where $PREFIX differs per user and per environment.        :
rem :                                                                     :
rem : "isabelle TOOL ..." is normally SYNCHRONOUS: stdout/stderr and the  :
rem : exit code are passed straight through, so CLI/CI use (getenv,       :
rem : build, "jedit -b", ...) behaves exactly like on Unix.               :
rem :                                                                     :
rem : The single exception is a *GUI* start of jEdit ("isabelle jedit"    :
rem : WITHOUT -b).  The chain cmd -> bash -> bash -> java is fully        :
rem : synchronous, so it would (a) block the console until jEdit quits    :
rem : and (b) die together with that console, because java stays attached :
rem : to it and receives CTRL_CLOSE_EVENT when the window is closed.      :
rem : Such an invocation is therefore re-launched DETACHED, in its own    :
rem : hidden console, via Cygwin's run.exe (PowerShell as a fallback).    :
rem : This mirrors the official launcher Isabelle2025-2.exe, which is a   :
rem : GUI-subsystem (console-less) launch4j stub.                         :
rem :                                                                     :
rem : Environment overrides:                                              :
rem :   ISABELLE_BAT_SYNC=1     never detach (force synchronous)          :
rem :   ISABELLE_BAT_DRYRUN=1   print the GUI/SYNC decision and exit      :
rem :=====================================================================:

setlocal EnableExtensions

rem :---------------------------------------------------------------------:
rem : self-location: this script is <ISABELLE_HOME>\bin\isabelle.bat, so   :
rem : ISABELLE_HOME is its parent directory.  "%~dp0" is the fully         :
rem : qualified drive+path of this script and always ends in "\".          :
rem :                                                                      :
rem : NB: the three statements MUST stay on separate lines.  cmd expands   :
rem : %CD% when it *parses* a line, not when it runs it, so the one-liner  :
rem :     pushd "%~dp0.." && set "ISABELLE_HOME=%CD%" && popd              :
rem : would capture the OLD working directory.                             :
rem :---------------------------------------------------------------------:
pushd "%~dp0.." || exit /b 1
set "ISABELLE_HOME=%CD%"
popd

set "HOME=%HOMEDRIVE%%HOMEPATH%"
set "LANG=en_US.UTF-8"
set "CHERE_INVOKING=true"
set "CYGWIN=nodosfilewarning"
set "PATH=%ISABELLE_HOME%\bin;%PATH%"

set "_ISA_BASH=%ISABELLE_HOME%\contrib\cygwin\bin\bash.exe"
set "_ISA_RUN=%ISABELLE_HOME%\contrib\cygwin\bin\run.exe"

rem : The Unix entry point of *this* tree, addressed absolutely rather than
rem : via PATH, so that a second Isabelle installation cannot be picked up
rem : by accident.  Cygwin accepts a mixed "C:/dir/file" path, so plain
rem : backslash->slash substitution is enough (and, unlike backslashes, it
rem : survives bash's string processing).
set "_ISA_TOOL=%ISABELLE_HOME:\=/%/bin/isabelle"

rem : stage 2 -- re-entry inside the detached, hidden-console process.
rem : The original command line is handed over in ISABELLE_BAT_ARGS rather
rem : than on the command line, because run.exe rewrites its arguments
rem : (--quote doubles every backslash, mangling Windows paths).
if defined ISABELLE_BAT_INNER goto :inner

rem : Does this invocation open the jEdit GUI?
set "_ISA_GUI="
if /I "%~1"=="jedit" call :scan_jedit %*
if defined ISABELLE_BAT_SYNC set "_ISA_GUI="

if defined ISABELLE_BAT_DRYRUN goto :dryrun
if defined _ISA_GUI goto :gui


rem :---------------------------------------------------------------------:
rem : synchronous path (all CLI tools, and "jedit -b")                     :
rem :---------------------------------------------------------------------:
"%_ISA_BASH%" --login -c "exec \"$0\" \"$@\"" "%_ISA_TOOL%" %*
exit /b %ERRORLEVEL%


rem :---------------------------------------------------------------------:
rem : detached path (GUI start of jEdit)                                   :
rem :---------------------------------------------------------------------:
:gui
set "ISABELLE_BAT_INNER=1"
rem : NB: deliberately NOT   set "ISABELLE_BAT_ARGS=%*"   -- the extra opening
rem : quote of that form flips cmd's quote parity, so a "&" inside a quoted
rem : argument would end up OUTSIDE quotes and be taken as a command separator.
rem : The bare form keeps the parity of the original command line intact.
set ISABELLE_BAT_ARGS=%*
set "ISABELLE_BAT_SELF=%~f0"
if exist "%_ISA_RUN%" goto :gui_run
powershell -NoProfile -Command "Start-Process -FilePath $env:COMSPEC -ArgumentList '/c',('\"' + $env:ISABELLE_BAT_SELF + '\"') -WindowStyle Hidden"
exit /b 0
:gui_run
"%_ISA_RUN%" "%COMSPEC%" /c "%~f0"
exit /b 0

:inner
set "ISABELLE_BAT_INNER="
rem : nothing is attached to this hidden console, so keep a log for diagnosis
"%_ISA_BASH%" --login -c "exec \"$0\" \"$@\"" "%_ISA_TOOL%" %ISABELLE_BAT_ARGS% > "%TEMP%\isabelle-jedit.log" 2>&1
exit /b %ERRORLEVEL%

:dryrun
if defined _ISA_GUI (echo GUI) else (echo SYNC)
exit /b 0


rem :---------------------------------------------------------------------:
rem : :scan_jedit -- faithful replay of the getopts spec of "isabelle      :
rem : jedit" (src/Tools/jEdit/lib/Tools/jedit):                            :
rem :                                                                      :
rem :     getopts "A:BFD:J:R:bd:fi:j:l:m:no:p:su"                          :
rem :                                                                      :
rem : i.e. A D J R d i j l m o p take a value, B F b f n s u do not, and   :
rem : getopts stops at "--", at "-", or at the first non-option argument.  :
rem : Only "-b" (build only) keeps the invocation synchronous; everything  :
rem : else opens the GUI.  Replaying the real spec is what makes the rule  :
rem : safe for clustered flags ("-bf") and for values that look like       :
rem : options ("-d -b" = session directory named "-b", NOT build-only).    :
rem : An unknown option makes jedit print its usage and exit, so it stays  :
rem : synchronous as well.                                                 :
rem :---------------------------------------------------------------------:
:scan_jedit
shift
:scan_tok
if "%~1"=="" goto :scan_gui
set "_tok=%~1"
if "%_tok%"=="--" goto :scan_gui
if "%_tok%"=="-" goto :scan_gui
if not "%_tok:~0,1%"=="-" goto :scan_gui
set "_tok=%_tok:~1%"
:scan_char
if "%_tok%"=="" goto :scan_next
set "_c=%_tok:~0,1%"
set "_tok=%_tok:~1%"
if "%_c%"=="b" goto :scan_sync
if "%_c%"=="B" goto :scan_char
if "%_c%"=="F" goto :scan_char
if "%_c%"=="f" goto :scan_char
if "%_c%"=="n" goto :scan_char
if "%_c%"=="s" goto :scan_char
if "%_c%"=="u" goto :scan_char
if "%_c%"=="A" goto :scan_arg
if "%_c%"=="D" goto :scan_arg
if "%_c%"=="J" goto :scan_arg
if "%_c%"=="R" goto :scan_arg
if "%_c%"=="d" goto :scan_arg
if "%_c%"=="i" goto :scan_arg
if "%_c%"=="j" goto :scan_arg
if "%_c%"=="l" goto :scan_arg
if "%_c%"=="m" goto :scan_arg
if "%_c%"=="o" goto :scan_arg
if "%_c%"=="p" goto :scan_arg
goto :scan_sync
:scan_arg
if not "%_tok%"=="" goto :scan_next
shift
:scan_next
shift
goto :scan_tok
:scan_gui
set "_ISA_GUI=1"
goto :eof
:scan_sync
set "_ISA_GUI="
goto :eof
