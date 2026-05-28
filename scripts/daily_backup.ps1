$backupDir = "E:\RAG-Anything\data_backup"
$date = Get-Date -Format "yyyy-MM-dd"
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"

$dayBackupDir = "$backupDir\daily\$date"
New-Item -ItemType Directory -Force -Path $dayBackupDir | Out-Null

Write-Host "[$timestamp] 开始每日备份..."

# 1. 备份 Redis
docker exec lightrag-redis BGSAVE
Start-Sleep -Seconds 5
docker exec lightrag-redis redis-cli SAVE
$redisBackupFile = "$dayBackupDir\redis_dump.rdb"
docker cp lightrag-redis:/data/dump.rdb $redisBackupFile
Write-Host "  Redis: $redisBackupFile" -ForegroundColor Green

# 2. 备份 Qdrant 元数据
$qdrantDump = "$dayBackupDir\qdrant_meta.json"
docker exec lightrag-qdrant curl -s http://localhost:6333/collections > $qdrantDump
Write-Host "  Qdrant meta: $qdrantDump" -ForegroundColor Green

# 3. 备份 Neo4j
docker exec neo4j cypher-shell -u neo4j -p password123 "CALL apoc.export.json.all('/logs/neo4j_backup.json', {useTypes:true})" 2>$null
$neo4jBackupFile = "$dayBackupDir\neo4j_backup.json"
docker cp neo4j:/logs/neo4j_backup.json $neo4jBackupFile 2>$null
Write-Host "  Neo4j: $neo4jBackupFile" -ForegroundColor Green

# 4. 备份配置文件
$configFiles = @("E:\RAG-Anything\RAG-Anything\.env","E:\RAG-Anything\RAG-Anything\docker-compose.yml")
foreach ($f in $configFiles) {
    if (Test-Path $f) {
        $dest = "$dayBackupDir\$(Split-Path $f -Leaf)"
        Copy-Item $f -Destination $dest -Force
        Write-Host "  Config: $dest" -ForegroundColor Green
    }
}

# 5. 压缩
$archiveFile = "$backupDir\archives\lightrag_daily_$timestamp.zip"
New-Item -ItemType Directory -Force -Path (Split-Path $archiveFile -Parent) | Out-Null
Compress-Archive -Path $dayBackupDir -DestinationPath $archiveFile -CompressionLevel Optimal

# 6. 清理超过 30 天的备份
Get-ChildItem "$backupDir\archives\lightrag_daily_"*.zip | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force

Write-Host "[$timestamp] 每日备份完成: $archiveFile" -ForegroundColor Cyan