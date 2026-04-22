param(
    [switch]$BackendRunner,
    [switch]$DryRun,
    [string]$MySqlServiceName = "MySQL"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = $MyInvocation.MyCommand.Path
$backendRoot = Split-Path -Parent $scriptPath
$backendContainer = Split-Path -Parent $backendRoot
$day01Root = Split-Path -Parent $backendContainer
$nginxRoot = Join-Path $day01Root "front-end\nginx-1.20.2"
$nginxExe = Join-Path $nginxRoot "nginx.exe"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Note {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Yellow
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PortListening {
    param([int]$Port)

    $listener = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq "Listen" } |
        Select-Object -First 1

    return $null -ne $listener
}

function Wait-ForPort {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 15
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-PortListening -Port $Port) {
            return $true
        }

        Start-Sleep -Seconds 1
    }

    return $false
}

function Get-MavenCommand {
    $command = Get-Command mvn.cmd -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command mvn -ErrorAction SilentlyContinue
    }

    if ($command) {
        return $command.Source
    }

    $wrapperRoot = Join-Path $env:USERPROFILE ".m2\wrapper\dists"
    if (Test-Path $wrapperRoot) {
        $candidate = Get-ChildItem -Path $wrapperRoot -Recurse -Filter "mvn.cmd" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($candidate) {
            return $candidate.FullName
        }
    }

    throw "Unable to find Maven. Install Maven or open the project in IntelliJ IDEA once so it can download Maven."
}

if ($BackendRunner) {
    if (-not (Test-Path $backendRoot)) {
        throw "Backend directory was not found: $backendRoot"
    }

    $maven = Get-MavenCommand

    Push-Location $backendRoot
    try {
        Write-Step "Preparing backend dependencies..."
        Write-Host "& `"$maven`" -pl sky-common,sky-pojo -am install -DskipTests"
        if (-not $DryRun) {
            & $maven -pl sky-common,sky-pojo -am install -DskipTests
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to prepare backend dependencies."
            }
        }

        Write-Step "Starting Spring Boot backend on port 8080..."
        Write-Host "& `"$maven`" -pl sky-server spring-boot:run"
        if (-not $DryRun) {
            & $maven -pl sky-server spring-boot:run
            if ($LASTEXITCODE -ne 0) {
                throw "Backend exited with code $LASTEXITCODE."
            }
        }
    }
    finally {
        Pop-Location
    }

    return
}

if (-not (Test-Path $backendRoot)) {
    throw "Backend directory was not found: $backendRoot"
}

if (-not (Test-Path $nginxExe)) {
    throw "nginx.exe was not found: $nginxExe"
}

if (-not $DryRun -and -not (Test-IsAdministrator) -and -not (Test-PortListening -Port 3306)) {
    Write-Step "Relaunching as Administrator so the MySQL service can be started..."

    $elevatedArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptPath,
        "-MySqlServiceName", $MySqlServiceName
    )

    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $elevatedArgs | Out-Null
    return
}

Write-Step "Day01 startup"

if (Test-PortListening -Port 3306) {
    Write-Ok "MySQL is already listening on port 3306."
}
else {
    $mysqlService = Get-Service -Name $MySqlServiceName -ErrorAction SilentlyContinue

    if (-not $mysqlService) {
        Write-Note "MySQL service '$MySqlServiceName' was not found. Start MySQL manually if your database runs under a different service name."
    }
    elseif ($mysqlService.Status -eq "Running") {
        Write-Note "MySQL service reports Running, waiting for port 3306..."
    }
    else {
        Write-Step "Starting MySQL service '$MySqlServiceName'..."
        Write-Host "Start-Service -Name $MySqlServiceName"

        if (-not $DryRun) {
            try {
                Start-Service -Name $MySqlServiceName
            }
            catch {
                Write-Note "Unable to start service '$MySqlServiceName': $($_.Exception.Message)"
            }
        }
    }

    if (-not $DryRun) {
        if (Wait-ForPort -Port 3306 -TimeoutSeconds 15) {
            Write-Ok "MySQL is now listening on port 3306."
        }
        else {
            Write-Note "MySQL is still not reachable on port 3306. Backend may report database errors until MySQL is running."
        }
    }
}

if (Test-PortListening -Port 8080) {
    Write-Ok "Backend is already listening on port 8080."
}
else {
    Write-Step "Starting backend in a new PowerShell window..."

    $backendArgs = @(
        "-NoExit",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptPath,
        "-BackendRunner"
    )

    Write-Host "powershell.exe $($backendArgs -join ' ')"

    if (-not $DryRun) {
        Start-Process -FilePath "powershell.exe" -WorkingDirectory $backendRoot -ArgumentList $backendArgs | Out-Null
    }
}

if (Test-PortListening -Port 80) {
    Write-Ok "A service is already listening on port 80."
}
else {
    Write-Step "Checking nginx configuration..."
    Write-Host "& `"$nginxExe`" -t"
    if (-not $DryRun) {
        Push-Location $nginxRoot
        try {
            & $nginxExe -t
            if ($LASTEXITCODE -ne 0) {
                throw "nginx configuration test failed."
            }
        }
        finally {
            Pop-Location
        }
    }

    Write-Step "Starting nginx..."
    Write-Host "Start-Process -FilePath `"$nginxExe`" -WorkingDirectory `"$nginxRoot`""
    if (-not $DryRun) {
        Start-Process -FilePath $nginxExe -WorkingDirectory $nginxRoot | Out-Null
    }

    if (-not $DryRun) {
        if (Wait-ForPort -Port 80 -TimeoutSeconds 5) {
            Write-Ok "nginx is now listening on port 80."
        }
        else {
            Write-Note "Port 80 did not open after starting nginx."
        }
    }
}

Write-Host ""
Write-Ok "Startup flow finished."
Write-Host "Frontend : http://localhost"
Write-Host "Docs     : http://localhost:8080/doc.html"
Write-Host "Backend  : http://localhost:8080"
Write-Host ""
Write-Host "If the backend window is still preparing dependencies, wait for it to finish booting."
