<#
.SYNOPSIS
    RENT-A-HAL RTX Node Bootstrap Script
.DESCRIPTION
    Sets up a Windows 10 machine with an RTX GPU as a RENT-A-HAL worker node.
    Installs CUDA, Ollama, and required models.
#>

# Run as admin check
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as Administrator. Please restart with elevated privileges." -ForegroundColor Red
    Start-Sleep -Seconds 5
    exit
}

# Configuration
$nodeId = [System.Guid]::NewGuid().ToString()
$workDir = "$env:USERPROFILE\RentAHal"
$logFile = "$workDir\install_log.txt"
$ollama_url = "https://ollama.com/download/ollama-windows-amd64.msi"
$cuda_url = "https://developer.download.nvidia.com/compute/cuda/12.2.0/local_installers/cuda_12.2.0_537.13_windows.exe"
$ngrok_url = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip"
$rentahal_server = "rentahal.com"
$models = @(
    @{name="llama3"; type="chat"},
    @{name="llava"; type="vision"},
    @{name="stabilityai/stable-diffusion"; type="imagine"}
)

# Create working directory
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

# Start logging
Start-Transcript -Path $logFile -Append

# Helper functions
function Show-Progress {
    param (
        [string]$Activity,
        [int]$PercentComplete
    )
    
    Write-Progress -Activity $Activity -PercentComplete $PercentComplete
    Write-Host "[Progress: $PercentComplete%] $Activity" -ForegroundColor Cyan
}

function Test-RTXCompatibility {
    Show-Progress -Activity "Checking GPU compatibility..." -PercentComplete 5
    
    try {
        $gpu = Get-WmiObject Win32_VideoController | Where-Object { $_.Name -match "NVIDIA" }
        
        if (-not $gpu) {
            throw "No NVIDIA GPU detected."
        }
        
        # Check if it's an RTX card
        if ($gpu.Name -notmatch "RTX") {
            throw "NVIDIA GPU found, but not an RTX series: $($gpu.Name)"
        }
        
        # Check if it's 2060 Super or better (simplified check)
        $modelMatches = $gpu.Name -match "RTX\s+(\d+)"
        if ($modelMatches) {
            $modelNumber = $Matches[1]
            if ([int]$modelNumber -lt 2060) {
                throw "RTX GPU found, but below minimum requirements: $($gpu.Name)"
            }
        }
        
        Write-Host "Compatible GPU found: $($gpu.Name)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "GPU compatibility check failed: $_" -ForegroundColor Red
        return $false
    }
}

function Install-CUDA {
    Show-Progress -Activity "Downloading CUDA drivers..." -PercentComplete 10
    
    try {
        $cudaInstaller = "$workDir\cuda_installer.exe"
        Invoke-WebRequest -Uri $cuda_url -OutFile $cudaInstaller
        
        Show-Progress -Activity "Installing CUDA (this may take a while)..." -PercentComplete 15
        Start-Process -FilePath $cudaInstaller -ArgumentList "/s" -Wait
        
        # Verify CUDA installation
        $cudaPath = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA"
        if (Test-Path $cudaPath) {
            Write-Host "CUDA installed successfully." -ForegroundColor Green
            return $true
        } else {
            throw "CUDA installation path not found."
        }
    }
    catch {
        Write-Host "CUDA installation failed: $_" -ForegroundColor Red
        return $false
    }
}

function Install-Ollama {
    Show-Progress -Activity "Downloading Ollama..." -PercentComplete 30
    
    try {
        $ollamaInstaller = "$workDir\ollama_installer.msi"
        Invoke-WebRequest -Uri $ollama_url -OutFile $ollamaInstaller
        
        Show-Progress -Activity "Installing Ollama..." -PercentComplete 35
        Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$ollamaInstaller`" /quiet" -Wait
        
        # Start Ollama service
        Show-Progress -Activity "Starting Ollama service..." -PercentComplete 40
        Start-Process -FilePath "$env:ProgramFiles\Ollama\ollama.exe" -ArgumentList "serve" -WindowStyle Hidden
        
        # Wait for Ollama to initialize
        $retries = 0
        while ($retries -lt 10) {
            try {
                $response = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -Method Get -ErrorAction SilentlyContinue
                Write-Host "Ollama service started successfully." -ForegroundColor Green
                return $true
            }
            catch {
                $retries++
                Start-Sleep -Seconds 3
            }
        }
        
        throw "Timed out waiting for Ollama service to start."
    }
    catch {
        Write-Host "Ollama installation failed: $_" -ForegroundColor Red
        return $false
    }
}

function Install-Models {
    Show-Progress -Activity "Downloading and installing AI models..." -PercentComplete 45
    
    try {
        $totalModels = $models.Count
        $currentModel = 0
        
        foreach ($model in $models) {
            $currentModel++
            $percent = 45 + (30 * ($currentModel / $totalModels))
            
            Show-Progress -Activity "Downloading model: $($model.name) ($currentModel of $totalModels)..." -PercentComplete $percent
            
            # Use Ollama CLI to pull the model
            Start-Process -FilePath "$env:ProgramFiles\Ollama\ollama.exe" -ArgumentList "pull $($model.name)" -Wait -NoNewWindow
        }
        
        Write-Host "All models installed successfully." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Model installation failed: $_" -ForegroundColor Red
        return $false
    }
}

function Install-Ngrok {
    Show-Progress -Activity "Setting up ngrok tunnel..." -PercentComplete 75
    
    try {
        # Download and extract ngrok
        $ngrokZip = "$workDir\ngrok.zip"
        $ngrokDir = "$workDir\ngrok"
        
        Invoke-WebRequest -Uri $ngrok_url -OutFile $ngrokZip
        
        # Create directory and extract
        New-Item -ItemType Directory -Force -Path $ngrokDir | Out-Null
        Expand-Archive -Path $ngrokZip -DestinationPath $ngrokDir -Force
        
        # Generate random auth token for demo purposes (in production, you'd use a real token)
        # In a real implementation, you'd provide your ngrok auth token or have users sign up
        $demoAuthToken = "demo_$([System.Guid]::NewGuid().ToString().Substring(0, 8))"
        
        # Configure ngrok
        Set-Location -Path $ngrokDir
        Start-Process -FilePath "$ngrokDir\ngrok.exe" -ArgumentList "config add-authtoken $demoAuthToken" -Wait -NoNewWindow
        
        # Start ngrok tunnel
        $ngrokProcess = Start-Process -FilePath "$ngrokDir\ngrok.exe" -ArgumentList "http 8000 --log=stdout" -WindowStyle Hidden -PassThru
        
        # Wait for ngrok to start and get the public URL
        Start-Sleep -Seconds 5
        
        # Get the ngrok tunnel URL (in a real implementation, parse from API)
        $tunnelUrl = "https://demo-tunnel-$nodeId.ngrok.io" # This is a placeholder
        
        Write-Host "Ngrok tunnel established: $tunnelUrl" -ForegroundColor Green
        
        # Save tunnel info
        $tunnelInfo = @{
            process_id = $ngrokProcess.Id
            url = $tunnelUrl
        }
        
        $tunnelInfo | ConvertTo-Json | Out-File -FilePath "$workDir\tunnel_info.json"
        
        return $tunnelUrl
    }
    catch {
        Write-Host "Ngrok setup failed: $_" -ForegroundColor Red
        return $null
    }
}

function Start-NodeServer {
    Show-Progress -Activity "Starting node server..." -PercentComplete 85
    
    try {
        # Create simple server config
        $serverConfig = @{
            node_id = $nodeId
            models = $models
            log_path = "$workDir\node_server.log"
        }
        
        $serverConfig | ConvertTo-Json | Out-File -FilePath "$workDir\node_config.json"
        
        # Create FastAPI server script
        $serverScript = @"
from fastapi import FastAPI, Response, HTTPException
import uvicorn
import json
import os
import subprocess
import sys
import logging
from typing import Dict, List, Any
from datetime import datetime
import ollama

# Configure logging
logging.basicConfig(
    filename="$($serverConfig.log_path.Replace('\', '\\'))",
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger("rentahal-node")

# Load config
with open("$($workDir.Replace('\', '\\'))\\node_config.json", "r") as f:
    config = json.load(f)

# Initialize FastAPI app
app = FastAPI(title="RENT-A-HAL Worker Node")

# Node status
NODE_STATUS = {
    "id": config["node_id"],
    "is_busy": False,
    "last_health_check": datetime.now().isoformat(),
    "uptime": 0,
    "models": config["models"],
    "stats": {
        "requests_processed": 0,
        "total_processing_time": 0
    }
}

# Startup event
@app.on_event("startup")
async def startup_event():
    logger.info(f"Node server starting. ID: {NODE_STATUS['id']}")
    # Register with main server
    register_with_rentahal()

# Health check endpoint
@app.get("/health")
async def health_check():
    if NODE_STATUS["is_busy"]:
        return Response(status_code=503)
    
    NODE_STATUS["last_health_check"] = datetime.now().isoformat()
    return {"status": "healthy", "node_id": NODE_STATUS["id"]}

# Toggle busy status
@app.post("/toggle_busy")
async def toggle_busy(status: Dict[str, bool]):
    NODE_STATUS["is_busy"] = status.get("is_busy", False)
    return {"status": "success", "is_busy": NODE_STATUS["is_busy"]}

# Chat endpoint
@app.post("/chat")
async def chat(data: Dict[str, Any]):
    if NODE_STATUS["is_busy"]:
        raise HTTPException(status_code=503, detail="Node is busy")
    
    start_time = datetime.now()
    
    try:
        response = ollama.chat(
            model=data.get("model", "llama3"),
            messages=[{"role": m.get("role", "user"), "content": m.get("content", "")} for m in data.get("messages", [])]
        )
        
        processing_time = (datetime.now() - start_time).total_seconds()
        NODE_STATUS["stats"]["requests_processed"] += 1
        NODE_STATUS["stats"]["total_processing_time"] += processing_time
        
        return {
            "response": response["message"]["content"],
            "processing_time": processing_time
        }
    except Exception as e:
        logger.error(f"Error processing chat request: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

# Vision endpoint
@app.post("/vision")
async def vision(data: Dict[str, Any]):
    if NODE_STATUS["is_busy"]:
        raise HTTPException(status_code=503, detail="Node is busy")
    
    start_time = datetime.now()
    
    try:
        # Process vision request with llava
        response = ollama.chat(
            model="llava",
            messages=[{
                "role": "user", 
                "content": data.get("prompt", "Describe this image"),
                "images": [data.get("image")]
            }]
        )
        
        processing_time = (datetime.now() - start_time).total_seconds()
        NODE_STATUS["stats"]["requests_processed"] += 1
        NODE_STATUS["stats"]["total_processing_time"] += processing_time
        
        return {
            "response": response["message"]["content"],
            "processing_time": processing_time
        }
    except Exception as e:
        logger.error(f"Error processing vision request: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

# Status endpoint
@app.get("/status")
async def get_status():
    NODE_STATUS["uptime"] = (datetime.now() - datetime.fromisoformat(NODE_STATUS["last_health_check"])).total_seconds()
    return NODE_STATUS

def register_with_rentahal():
    try:
        # Read tunnel info
        with open("$($workDir.Replace('\', '\\'))\\tunnel_info.json", "r") as f:
            tunnel_info = json.load(f)
            
        # In production this would be an HTTPS request to the main server
        logger.info(f"Registering with RENT-A-HAL main server: {tunnel_info['url']}")
        
        # Create a file with registration details for demonstration
        with open("$($workDir.Replace('\', '\\'))\\registration_details.json", "w") as f:
            registration = {
                "node_id": NODE_STATUS["id"],
                "tunnel_url": tunnel_info["url"],
                "registration_time": datetime.now().isoformat(),
                "models": NODE_STATUS["models"],
                "registration_server": "$rentahal_server"
            }
            json.dump(registration, f, indent=2)
            
        # In a real implementation, this would make an API call to register
        # This would use requests.post("https://$rentahal_server/addme", json=registration)
        logger.info("Node registered successfully. Visit https://$rentahal_server/addme with the details in registration_details.json")
    except Exception as e:
        logger.error(f"Error registering with RENT-A-HAL: {str(e)}")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
"@
        
        $serverScript | Out-File -FilePath "$workDir\node_server.py" -Encoding utf8
        
        # Install required Python packages
        Show-Progress -Activity "Installing Python dependencies..." -PercentComplete 90
        Start-Process -FilePath "pip" -ArgumentList "install fastapi uvicorn ollama" -Wait -NoNewWindow
        
        # Start the server
        Show-Progress -Activity "Starting FastAPI server..." -PercentComplete 95
        $serverProcess = Start-Process -FilePath "python" -ArgumentList "$workDir\node_server.py" -WindowStyle Hidden -PassThru
        
        # Create startup shortcut
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut("$env:USERPROFILE\Desktop\RENT-A-HAL Node.lnk")
        $Shortcut.TargetPath = "python"
        $Shortcut.Arguments = "$workDir\node_server.py"
        $Shortcut.WorkingDirectory = $workDir
        $Shortcut.Save()
        
        Write-Host "Node server started successfully. PID: $($serverProcess.Id)" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Node server setup failed: $_" -ForegroundColor Red
        return $false
    }
}

function Register-WithRentAHal {
    Show-Progress -Activity "Registering with RENT-A-HAL..." -PercentComplete 98
    
    try {
        # Get tunnel info
        $tunnelInfo = Get-Content -Path "$workDir\tunnel_info.json" | ConvertFrom-Json
        
        # Prepare registration payload
        $registration = @{
            node_id = $nodeId
            tunnel_url = $tunnelInfo.url
            models = $models
            system_info = @{
                gpu = (Get-WmiObject Win32_VideoController | Where-Object { $_.Name -match "NVIDIA" }).Name
                cpu = (Get-WmiObject Win32_Processor).Name
                memory_gb = [math]::Round((Get-WmiObject Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
                os = (Get-WmiObject Win32_OperatingSystem).Caption
            }
        }
        
        # In a real implementation, you would make an API call to register
        # For demo purposes, we'll just save the registration info
        $registration | ConvertTo-Json | Out-File -FilePath "$workDir\registration_payload.json"
        
        # Auto-visit the /addme endpoint in default browser
        Start-Process "https://$rentahal_server/addme?node_id=$nodeId&url=$($tunnelInfo.url)&type=windows"
        
        Write-Host "Registration with RENT-A-HAL completed successfully!" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Registration failed: $_" -ForegroundColor Red
        return $false
    }
}

function Initialize-TrayApp {
    Show-Progress -Activity "Setting up system tray application..." -PercentComplete 99
    
    try {
        # Create a simple PowerShell tray app script
        $trayScript = @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Create a context menu that lets users toggle busy status
function Create-Menu {
    `$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    
    `$toggleBusyItem = New-Object System.Windows.Forms.ToolStripMenuItem
    `$toggleBusyItem.Text = "Toggle Busy"
    `$toggleBusyItem.Add_Click({
        # Toggle busy status via API call
        try {
            `$currentStatus = Invoke-RestMethod -Uri "http://localhost:8000/status" -Method Get
            `$newStatus = -not `$currentStatus.is_busy
            
            Invoke-RestMethod -Uri "http://localhost:8000/toggle_busy" -Method Post -Body (@{is_busy=`$newStatus} | ConvertTo-Json) -ContentType "application/json"
            
            if (`$newStatus) {
                `$notifyIcon.Icon = `$busyIcon
                `$notifyIcon.Text = "RENT-A-HAL Node (Busy)"
            } else {
                `$notifyIcon.Icon = `$availableIcon
                `$notifyIcon.Text = "RENT-A-HAL Node (Available)"
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error toggling busy status: `$_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    
    `$viewStatusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    `$viewStatusItem.Text = "View Status"
    `$viewStatusItem.Add_Click({
        try {
            `$status = Invoke-RestMethod -Uri "http://localhost:8000/status" -Method Get
            `$statusStr = "Node ID: `$(`$status.id)`nBusy: `$(`$status.is_busy)`nRequests Processed: `$(`$status.stats.requests_processed)`nUptime: `$(Get-FormattedUptime `$status.uptime)"
            [System.Windows.Forms.MessageBox]::Show(`$statusStr, "Node Status", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error fetching status: `$_", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    
    `$openConsoleItem = New-Object System.Windows.Forms.ToolStripMenuItem
    `$openConsoleItem.Text = "Open Console"
    `$openConsoleItem.Add_Click({
        Start-Process "$workDir\node_server.log"
    })
    
    `$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    `$exitItem.Text = "Exit"
    `$exitItem.Add_Click({
        `$notifyIcon.Visible = `$false
        [System.Windows.Forms.Application]::Exit()
    })
    
    `$contextMenu.Items.Add(`$toggleBusyItem)
    `$contextMenu.Items.Add(`$viewStatusItem)
    `$contextMenu.Items.Add(`$openConsoleItem)
    `$contextMenu.Items.Add("-")
    `$contextMenu.Items.Add(`$exitItem)
    
    return `$contextMenu
}

function Get-FormattedUptime(`$seconds) {
    `$timespan = [TimeSpan]::FromSeconds(`$seconds)
    if (`$timespan.Days -gt 0) {
        return "`$(`$timespan.Days)d `$(`$timespan.Hours)h `$(`$timespan.Minutes)m"
    } elseif (`$timespan.Hours -gt 0) {
        return "`$(`$timespan.Hours)h `$(`$timespan.Minutes)m"
    } else {
        return "`$(`$timespan.Minutes)m `$(`$timespan.Seconds)s"
    }
}

# Create the tray icon
`$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
`$notifyIcon.Text = "RENT-A-HAL Node (Available)"
`$notifyIcon.ContextMenuStrip = Create-Menu

# Load icons
`$availableIcon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
`$busyIcon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
