# Symfony Redis Worker Control Panel

## Files

- Workers.bat                  -> opens the control panel
- RedisWorkerPanel.ps1         -> PowerShell WinForms control panel
- worker-request.bat            -> request worker
- worker-doctrine.bat           -> doctrine worker
- worker-default.bat            -> default worker
- logs\                         -> Symfony worker logs
- state\                        -> saved CMD PIDs

## IMPORTANT

The generated worker BAT files assume:

    C:\Users\dell\Desktop\newBooking

and this Symfony command:

    php bin\console app:redis-log-worker booking:logs:request
    php bin\console app:redis-log-worker booking:logs:doctrine
    php bin\console app:redis-log-worker booking:logs:default

If your console command accepts different arguments, edit only the three worker BAT files.

## Run

Double-click:

    Workers.bat

or from PowerShell:

    .\Workers.bat

## What it does

START:
- Opens a separate CMD window for the worker.
- Saves the CMD PID.
- The worker is independent from the control panel.

STOP:
- Uses taskkill /T /F.
- Kills the CMD process and its PHP child process.

RESTART:
- Stops the process tree.
- Starts it again.

START ALL / STOP ALL / RESTART ALL:
- Controls all three workers.

STATUS:
- Shows RUNNING / STOPPED and PID.

LIVE LOG:
- Reads the corresponding file under:
    C:\Users\dell\Desktop\newBooking\logs\

Closing the PowerShell control panel does NOT stop workers.

Closing an individual worker CMD window DOES stop that worker, because that window is the worker's actual CMD process. Use the panel's Stop button if you want controlled shutdown.
