$backupDir = "E:\RAG-Anything\data_backup"
$date = Get-Date -Format "yyyy-MM-dd"
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"

$weeklyDir = "$backupDir\weekly\$date"
New-Item -ItemType Directory -Force -Path $weeklyDir | Out-Null

Write-Host "[$timestamp] 开始每周全量备份..."

# 1. 备份 Docker volumes
docker run --rm -v lightrag_qdrant_storage:/qdrant -v $weeklyDir:/backup alpine tar czf /backup/qdrant_vol.tar.gz -C /qdrant .
docker run --rm -v lightrag_redis_data:/redis -v $weeklyDir:/backup alpine tar czf /backup/redis_vol.tar.gz -C /redis .
docker run --rm -v lightrag_neo4j_data:/neo4j -v $weeklyDir:/backup alpine tar czf /backup/neo4j_vol.tar.gz -C /neo4j .

# 2. 备份 JSON/GraphML 原始文件
$lightragDir = "E:\RAG-Anything\RAG-Anything\lightrag"
Compress-Archive -Path "$lightragDir\vdb_*.json","$lightragDir\kv_store_*.json","$lightragDir\graph_chunk_entity_relation.graphml" -DestinationPath "$weeklyDir\lightrag_data.zip" -CompressionLevel Optimal

# 3. 备份 Neo4j 完整导出
docker exec neo4j cypher-shell -u neo4j -p password123 "CALL apoc.export.json.all('/logs/neo4j_full.json', {useTypes:true})" 2>$null
docker cp neo4j:/logs/neo4j_full.json "$weeklyDir\neo4j_full.json" 2>$null

# 4. 创建归档
$archiveFile = "$backupDir\archives\lightrag_weekly_$timestamp.zip"
Compress-Archive -Path $weeklyDir -DestinationPath $archiveFile -CompressionLevel Optimal

# 5. 上传到 OneDrive（可选）
$oneDriveDir = "$env:USERPROFILE\OneDrive\RAG-Anything_Backup"
New-Item -ItemType Directory -Force -Path $oneDriveDir | Out-Null
Copy-Item $archiveFile -Destination $oneDriveDir -Force

# 6. 清理超过 4 周的备份
Get-ChildItem "$backupDir\archives\lightrag_weekly_"*.zip | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-28) } | Remove-Item -Force

Write-Host "[$timestamp] 每周全量备份完成: $archiveFile" -ForegroundColor Cyan