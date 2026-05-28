$ErrorActionPreference = "SilentlyContinue"

Write-Host "===== LightRAG 健康检查 =====" -ForegroundColor Cyan
Write-Host ""

# Docker
Write-Host "[Docker] " -NoNewline
$dockerStatus = docker-compose ps --format json 2>$null | ConvertFrom-Json | Where-Object { $_.Service -ne "" }
$runningCount = ($dockerStatus | Where-Object { $_.State -eq "Up" }).Count
Write-Host " $runningCount/3 服务运行中" -ForegroundColor $(if ($runningCount -eq 3) { "Green" } else { "Yellow" })

# Qdrant
Write-Host "[Qdrant] " -NoNewline
$qdrant = curl.exe -s http://localhost:6333/readyz
if ($qdrant -match "ok") { Write-Host "OK" -ForegroundColor Green } else { Write-Host "FAIL" -ForegroundColor Red }

# Redis
Write-Host "[Redis] " -NoNewline
$redis = redis-cli.exe ping 2>$null
if ($redis -match "PONG") { Write-Host "OK" -ForegroundColor Green } else { Write-Host "FAIL" -ForegroundColor Red }

# Neo4j
Write-Host "[Neo4j] " -NoNewline
$neo4j = curl.exe -s -o `$null -w "%{http_code}" http://localhost:7474
if ($neo4j -eq "200") { Write-Host "OK" -ForegroundColor Green } else { Write-Host "FAIL" -ForegroundColor Red }

# LightRAG
Write-Host "[LightRAG] " -NoNewline
$lr = powershell -Command "try { (Invoke-WebRequest -Uri 'http://localhost:9621/health' -UseBasicParsing | ConvertFrom-Json).status } catch { 'offline' }"
if ($lr -eq "healthy") { Write-Host "OK" -ForegroundColor Green } else { Write-Host "FAIL ($lr)" -ForegroundColor Red }

Write-Host ""