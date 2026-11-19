@echo off
setlocal
cd /d "%~dp0"
if not exist "config\sitewise_dev.env" (
  echo Missing config\sitewise_dev.env. Run setup_sitewise360_env.py first.
  exit /b 1
)
flutter run --dart-define-from-file=config/sitewise_dev.env %*
exit /b %ERRORLEVEL%
