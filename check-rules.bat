@echo off
REM ---------------------------------------------------------------------
REM  Are the deployed Firestore rules current?
REM
REM  Compares firestore.rules against the version last pushed by
REM  deploy-rules.bat. Answers the question that has already cost you two
REM  confusing "You don't have permission to do that" sessions.
REM ---------------------------------------------------------------------
cd /d "%~dp0"

for /f %%h in ('git hash-object firestore.rules') do set CURRENT=%%h

if not exist .rules-deployed (
  echo UNKNOWN - no record of a deploy from this machine.
  echo Run deploy-rules.bat to publish and start tracking.
  exit /b 2
)

set /p DEPLOYED=<.rules-deployed

if "%CURRENT%"=="%DEPLOYED%" (
  echo UP TO DATE - live rules match firestore.rules.
) else (
  echo OUT OF DATE - firestore.rules has changed since the last deploy.
  echo Run deploy-rules.bat
  exit /b 1
)
