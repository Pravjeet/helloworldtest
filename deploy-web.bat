@echo off
REM ---------------------------------------------------------------------
REM  Build the Flutter web app and publish it to Firebase Hosting.
REM
REM  This is separate from deploy-rules.bat on purpose: rules and the app
REM  are deployed independently, and a rules change should usually go out
REM  ahead of the app code that depends on it, not bundled in one step.
REM ---------------------------------------------------------------------
cd /d "%~dp0"

echo Running tests and analyzer first — do not ship on a red build...
call flutter analyze
if errorlevel 1 (
  echo.
  echo ANALYZE FAILED - fix the issues above before deploying.
  exit /b 1
)
call flutter test
if errorlevel 1 (
  echo.
  echo TESTS FAILED - fix the failing tests before deploying.
  exit /b 1
)

echo.
echo Building web release...
call flutter build web --release
if errorlevel 1 (
  echo.
  echo BUILD FAILED - the live site is unchanged.
  exit /b 1
)

echo.
echo Deploying to Firebase Hosting...
call firebase deploy --project hostel-acc38 --only hosting
if errorlevel 1 (
  echo.
  echo DEPLOY FAILED - check the error above. The previous release is still live
  echo  ^(Hosting keeps serving the last successful deploy until a new one lands^).
  exit /b 1
)

echo.
echo Deployed. Live on Firebase project hostel-acc38 (helloworld test clone).
echo If this deploy needs undoing: Firebase console -^> Hosting -^> Release
echo history -^> pick the previous release -^> Rollback.
