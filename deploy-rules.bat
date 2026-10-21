@echo off
REM ---------------------------------------------------------------------
REM  Deploy firestore.rules, then record which version went live.
REM
REM  The recorded hash is what makes "did I deploy this?" answerable.
REM  Run check-rules.bat any time to find out.
REM ---------------------------------------------------------------------
cd /d "%~dp0"

REM  Indexes go with the rules. They used to be left out entirely, so a query
REM  needing a composite index threw failed-precondition in production while
REM  firestore.indexes.json sat on disk looking correct. Deploying them here
REM  costs nothing when unchanged. Note indexes BUILD after deploying - a large
REM  collection can take a few minutes before the query starts working.
echo Deploying firestore.rules and indexes ...
call firebase deploy --project hostel-acc38 --only firestore:rules,firestore:indexes
if errorlevel 1 (
  echo.
  echo DEPLOY FAILED - the live rules are unchanged.
  exit /b 1
)

git hash-object firestore.rules > .rules-deployed
echo.
echo Deployed. Live rules now match your local firestore.rules.
