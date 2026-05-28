# RAG-Anything + LightRAG 完整部署运维手册

> **版本：** LightRAG 1.5.0 | RAG-Anything (latest)
> **维护人：** 小虾 🦐
> **最后更新：** 2026-05-28

---

## 一、系统架构

```
┌──────────────────────────────────────────────────────────────┐
│                      用户请求 (Query)                        │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│               LightRAG 1.5.0 (Python API Server)             │
│                    http://localhost:9621                     │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Operate Layer (kg_query / naive_query / extract)       │  │
│  └────────────────────────────────────────────────────────┘  │
│  ┌──────────────┬──────────────┬──────────────┬───────────┐  │
│  │  Qdrant      │   Redis      │   Neo4j      │  文件备份  │  │
│  │  向量存储     │   KV/状态     │   图存储     │           │  │
│  │  :6333       │   :6379      │   :7474/:7687│           │  │
│  └──────────────┴──────────────┴──────────────┴───────────┘  │
└──────────────────────────────────────────────────────────────┘
        ┌────────────────┼────────────────┐
        │                │                │
    ┌───▼───┐      ┌────▼────┐      ┌────▼────┐
    │Qdrant │      │ Redis   │      │ Neo4j   │
    │v1.12  │      │ 7-alpine│      │ 5.22    │
    └───────┘      └─────────┘      └─────────┘
     Docker          Docker          Docker
```

### 存储分层

| 存储类型 | 存储实现 | 数据内容 | 数据量 |
|---------|---------|---------|-------|
| **向量存储** | QdrantVectorDBStorage | entities / relationships / chunks 向量 | ~156k vectors |
| **KV存储** | RedisKVStorage | LLM response cache / text_chunks / full_docs / entities / relations | ~100k keys |
| **文档状态** | RedisDocStatusStorage | 文档处理状态 | 2.1k docs |
| **图存储** | Neo4JStorage | 知识图谱节点和边 | 62k nodes, 76k edges |
| **文件备份** | 本地 JSON/GraphML | 各存储原始文件（应急回退用） | ~4GB |

---

## 二、新机器完整安装部署

### 2.1 环境准备

**操作系统：** Windows 10/11 或 Windows Server

**前置软件：**
- Python 3.14.x（建议从 python.org 下载安装）
- Git
- Docker Desktop（开启 WSL2 后端）
- 文本编辑器（VS Code 推荐）

### 2.2 目录规划

```
E:\RAG-Anything\
├── RAG-Anything\           # 源码（可从 Git 拉取）
│   ├── .env
│   ├── docker-compose.yml
│   ├── lightrag\
│   │   ├── inputs\
│   │   └── outputs\
├── data_backup\
└── scripts\
```

### 2.3 安装步骤

#### Step 1：安装 Python 3.14

下载地址：https://www.python.org/downloads/

验证：
```powershell
python --version
pip --version
```

#### Step 2：安装 Git

下载地址：https://git-scm.com/download/win

验证：
```powershell
git --version
```

#### Step 3：安装 Docker Desktop

下载地址：https://www.docker.com/products/docker-desktop/

验证：
```powershell
docker --version
docker-compose --version
```

#### Step 4：克隆 RAG-Anything 源码

```powershell
cd E:\RAG-Anything
git clone https://github.com/your-repo/RAG-Anything.git
```

> 如果用已有数据迁移，直接从旧机器复制整个 RAG-Anything 目录，跳过 git clone

#### Step 5：安装 Python 依赖

```powershell
cd E:\RAG-Anything
pip install -r requirements.txt
```

#### Step 6：创建 Docker 网络

```powershell
docker network create lightrag-net
```

#### Step 7：启动 Docker 服务

将以下内容保存为 `E:\RAG-Anything\docker-compose.yml`：

```yaml
version: "3.8"

services:
  qdrant:
    image: qdrant/qdrant:v1.12.0
    container_name: lightrag-qdrant
    ports:
      - "6333:6333"
      - "6334:6334"
    volumes:
      - qdrant_storage:/qdrant/storage
    restart: unless-stopped
    networks:
      - lightrag-net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:6333/readyz"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: lightrag-redis
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    command: >
      redis-server
      --appendonly yes
      --maxmemory 2gb
      --maxmemory-policy allkeys-lru
      --save 900 1
      --save 300 10
      --save 60 10000
    restart: unless-stopped
    networks:
      - lightrag-net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

  neo4j:
    image: neo4j:5.22.0
    container_name: lightrag-neo4j
    ports:
      - "7474:7474"
      - "7687:7687"
    volumes:
      - neo4j_data:/data
      - neo4j_logs:/logs
    environment:
      - NEO4J_AUTH=neo4j/password123
      - NEO4J_dbms_memory_heap_max=1G
      - NEO4J_dbms_security_procedures_unrestricted=apoc.*
      - NEO4J_dbms_security_procedures_allowlist=apoc.*
    restart: unless-stopped
    networks:
      - lightrag-net
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:7474"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  qdrant_storage:
  redis_data:
  neo4j_data:
  neo4j_logs:

networks:
  lightrag-net:
    driver: bridge
```

启动：
```powershell
cd E:\RAG-Anything
docker-compose up -d
Start-Sleep -Seconds 30
docker-compose ps
```

#### Step 8：配置 .env

保存为 `E:\RAG-Anything\RAG-Anything\.env`：

```env
WORKING_DIR=E:\RAG-Anything\RAG-Anything\lightrag
LOG_DIR=E:\RAG-Anything\RAG-Anything\lightrag\logs
OUTPUT_DIR=E:\RAG-Anything\RAG-Anything\outputs

VECTOR_STORAGE=QdrantVectorDBStorage
QDRANT_URL=http://localhost:6333
QDRANT_TIMEOUT=10

KV_STORAGE=RedisKVStorage
REDIS_URI=redis://localhost:6379/0

DOC_STATUS_STORAGE=RedisDocStatusStorage

GRAPH_STORAGE=Neo4JStorage
NEO4J_URI=bolt://localhost:7687
NEO4J_USERNAME=neo4j
NEO4J_PASSWORD=password123

LLM_BINDING=openai
LLM_MODEL=glm-4-flashx
LLM_BINDING_API_KEY=你的ZhipuAPIKey
OPENAI_API_BASE=https://open.bigmodel.cn/api/paas/v4
LLM_BINDING_HOST=https://open.bigmodel.cn/api/paas/v4
LLM_BINDING_BASE_URL=https://open.bigmodel.cn/api/paas/v4
TIMEOUT=300
LLM_TIMEOUT=300
MAX_ASYNC=200

EMBEDDING_BINDING=openai
EMBEDDING_MODEL=text-embedding-v4
EMBEDDING_DIM=2048
EMBEDDING_BINDING_HOST=https://dashscope.aliyuncs.com/compatible-mode/v1
EMBEDDING_BINDING_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
EMBEDDING_BINDING_API_KEY=你的阿里APIKey
EMBEDDING_TIMEOUT=120
EMBEDDING_SEND_DIM=true
EMBEDDING_BATCH_NUM=5
EMBEDDING_FUNC_MAX_ASYNC=200

CHUNK_SIZE=1024
CHUNK_OVERLAP_SIZE=128
SUMMARY_LANGUAGE=Chinese

LOG_MAX_BYTES=10485760
LOG_BACKUP_COUNT=5
VERBOSE=false
```

#### Step 9：启动 LightRAG

```powershell
cd E:\RAG-Anything\RAG-Anything
set PYTHONIOENCODING=utf-8
python lightrag\start_server.py
```

#### Step 10：验证

```powershell
# Docker 服务
docker-compose ps

# Qdrant
curl.exe http://localhost:6333/readyz

# Redis
redis-cli.exe ping

# LightRAG
powershell -Command "Invoke-WebRequest -Uri 'http://localhost:9621/health' -UseBasicParsing | ConvertFrom-Json | Select-Object -ExpandProperty status"
```

---

## 三、数据迁移方案（重装机器 / 换机器）

### 3.1 迁移架构图

```
旧机器                                    新机器
┌──────────────────────────┐          ┌──────────────────────────┐
│ E:\RAG-Anything\          │   ──►    │ E:\RAG-Anything\          │
│   ├── RAG-Anything\       │          │   ├── RAG-Anything\       │
│   │   ├── .env            │          │   │   ├── .env            │
│   │   ├── docker-compose.yml          │   │   ├── docker-compose.yml          │
│   │   ├── lightrag\       │          │   │   ├── lightrag\       │
│   │   │   ├── vdb_*.json  │          │   │   │   └── ...        │
│   │   │   ├── kv_store_*.json │      │   │   │                  │
│   │   │   └── graph_*.graphml │      │   │   └── ...        │
│   └── data_backup\        │          │   └── data_backup\        │
└──────────────────────────┘          └──────────────────────────┘
                                       ┌──────────────────────────┐
                                       │ Docker Volumes           │
                                       │  qdrant_storage          │
                                       │  redis_data              │
                                       │  neo4j_data              │
                                       └──────────────────────────┘
```

### 3.2 迁移步骤

#### Phase 1：旧机器数据导出

**Step 1：停止 LightRAG**

```powershell
netstat -ano | findstr :9621
taskkill /PID <PID> /F
```

**Step 2：备份 Docker Volume 数据**

```powershell
docker run --rm -v lightrag_qdrant_storage:/qdrant -v E:/RAG-Anything/data_backup:/backup alpine tar czf /backup/qdrant_data.tar.gz -C /qdrant .
docker run --rm -v lightrag_redis_data:/redis -v E:/RAG-Anything/data_backup:/backup alpine tar czf /backup/redis_data.tar.gz -C /redis .
docker run --rm -v lightrag_neo4j_data:/neo4j -v E:/RAG-Anything/data_backup:/backup alpine tar czf /backup/neo4j_data.tar.gz -C /neo4j .
```

**Step 3：复制整个 RAG-Anything 目录**

```powershell
robocopy E:\RAG-Anything D:\RAG-Anything /E /COPYALL /DCOPY:T /MIR /NP /R:3 /W:5
```

**关键文件清单：**
- `RAG-Anything\.env` — 包含所有 API Keys，必须复制
- `RAG-Anything\docker-compose.yml` — Docker 编排配置
- `RAG-Anything\lightrag\inputs\` — 待索引文档
- `RAG-Anything\lightrag\outputs\` — 导出结果
- `RAG-Anything\lightrag\vdb_*.json` — 向量数据备份
- `RAG-Anything\lightrag\kv_store_*.json` — KV 数据备份
- `RAG-Anything\lightrag\graph_chunk_entity_relation.graphml` — 图数据备份
- `RAG-Anything\lightrag\kv_store_doc_status.json` — 文档状态备份

#### Phase 2：新机器数据导入

**Step 1：安装 Docker Desktop，创建网络**

```powershell
docker network create lightrag-net
```

**Step 2：启动 Docker 服务**

```powershell
cd D:\RAG-Anything\RAG-Anything
docker-compose up -d
Start-Sleep -Seconds 30
```

**Step 3：启动 LightRAG（自动迁移）**

```powershell
set PYTHONIOENCODING=utf-8
python lightrag\start_server.py
```

LightRAG 1.5.0 会自动从 `lightrag\` 目录的 JSON/GraphML 文件读取数据并写入 Qdrant/Redis/Neo4j。

**Step 4：验证迁移结果**

```powershell
# Qdrant 向量数量
curl.exe http://localhost:6333/collections

# Redis keyspace
redis-cli.exe info keyspace

# Neo4j 节点数
# 浏览器访问 http://localhost:7474 执行：
# MATCH (n) RETURN count(n)
# MATCH ()-[r]->() RETURN count(r)

# LightRAG 健康
powershell -Command "Invoke-WebRequest -Uri 'http://localhost:9621/health' -UseBasicParsing | ConvertFrom-Json | Select-Object -ExpandProperty status"
```

### 3.3 迁移核查清单

| 核查项 | 预期值 | 验证方法 |
|--------|--------|---------|
| Qdrant entities collection | ~62,016 vectors | `curl localhost:6333/collections` |
| Qdrant relationships collection | ~79,466 vectors | 同上 |
| Qdrant chunks collection | ~10,312 vectors | 同上 |
| Redis keyspace | ~100k keys | `redis-cli info keyspace` |
| Neo4j 节点数 | ~62,019 nodes | Neo4j Browser Cypher |
| Neo4j 边数 | ~76,024 edges | Neo4j Browser Cypher |
| LightRAG 健康 | healthy | PowerShell Invoke-WebRequest |
| 文档状态数 | 2,170 docs | Redis `keys *doc_status*` |

---

## 四、数据备份与恢复方案

### 4.1 备份架构

```
每日增量备份                         每周全量备份
┌─────────────────┐                 ┌─────────────────┐
│  Docker Volumes │                 │  Docker Volumes │
│  (生产数据)      │                 │  + JSON/GraphML │
└────────┬────────┘                 └────────┬────────┘
         │                                   │
         ▼                                   ▼
┌─────────────────┐                 ┌─────────────────┐
│  备份脚本自动执行 │                 │  备份到本地磁盘  │
│  (定时任务)      │                 │  + 压缩归档     │
└────────┬────────┘                 └────────┬────────┘
         │                                   │
         ▼                                   ▼
┌─────────────────┐                 ┌─────────────────┐
│  本地备份目录    │                 │  异地备份(云盘)  │
│  data_backup/   │                 │  (OneDrive/SMB) │
└─────────────────┘                 └─────────────────┘
```

### 4.2 备份策略

| 数据类型 | 备份频率 | 保留周期 | 存储位置 |
|---------|---------|---------|---------|
| Docker Volumes | 每日增量 + 每周全量 | 4周 | 本地 `data_backup/` |
| JSON/GraphML 原始文件 | 每日 | 4周 | 本地 `data_backup/` |
| .env 配置文件 | 每次修改后 | 长期 | 加密存储 (OneDrive) |
| Neo4j 导出 (JSON/CSV) | 每周 | 4周 | 本地 + 云盘 |
| Docker Compose + 启动脚本 | 每次修改后 | 长期 | Git 仓库 |

### 4.3 备份脚本

#### 每日增量备份（每日凌晨 2:00）

保存为 `E:\RAG-Anything\scripts\daily_backup.ps1`：

```powershell
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
```

设置定时任务：
```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File 'E:\RAG-Anything\scripts\daily_backup.ps1'"
$trigger = New-ScheduledTaskTrigger -Daily -At "02:00"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingBatteries
Register-ScheduledTask -TaskName "LightRAG_DailyBackup" -Action $action -Trigger $trigger -Settings $settings -Description "LightRAG 每日备份"
```

#### 每周全量备份（每周日凌晨 3:00）

保存为 `E:\RAG-Anything\scripts\weekly_backup.ps1`：

```powershell
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
```

设置定时任务：
```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File 'E:\RAG-Anything\scripts\weekly_backup.ps1'"
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "03:00"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingBatteries
Register-ScheduledTask -TaskName "LightRAG_WeeklyBackup" -Action $action -Trigger $trigger -Settings $settings -Description "LightRAG 每周全量备份"
```

### 4.4 恢复方案

#### 恢复 Level 1：文件数据损坏（Docker 数据完好）

```powershell
# 1. 确认文件完整
Get-ChildItem E:\RAG-Anything\RAG-Anything\lightrag\vdb_*.json

# 2. 确保 Docker 服务运行
docker-compose up -d

# 3. 编辑 .env，注释掉 Docker 存储，使用文件存储临时回退
# VECTOR_STORAGE=NanoVectorDBStorage
# KV_STORAGE=JsonKVStorage
# GRAPH_STORAGE=NetworkXStorage
# DOC_STATUS_STORAGE=JsonDocStatusStorage

# 4. 启动 LightRAG
set PYTHONIOENCODING=utf-8
python lightrag\start_server.py

# 5. 正常后切回 Docker 存储，重启 LightRAG
```

#### 恢复 Level 2：Docker volumes 损坏（有备份文件）

```powershell
# 1. 停止所有服务
docker-compose down

# 2. 删除损坏的 volumes
docker volume rm lightrag_qdrant_storage lightrag_redis_data lightrag_neo4j_data

# 3. 重建 volumes
docker volume create lightrag_qdrant_storage
docker volume create lightrag_redis_data
docker volume create lightrag_neo4j_data

# 4. 启动 Docker 服务
docker-compose up -d

# 5. .env 设为文件存储模式，启动 LightRAG 触发迁移
set PYTHONIOENCODING=utf-8
python lightrag\start_server.py

# 6. 验证后切回 Docker 存储配置
```

#### 恢复 Level 3：从归档备份完全恢复

```powershell
# 1. 创建网络，启动 Docker
docker network create lightrag-net
docker-compose up -d

# 2. 解压备份归档
$archiveFile = "E:\RAG-Anything\data_backup\archives\lightrag_weekly_2026-05-20_0300.zip"
$extractDir = "E:\RAG-Anything\data_backup\restore_temp"
Expand-Archive -Path $archiveFile -DestinationPath $extractDir -Force

# 3. 恢复文件
$weeklyBackup = Get-ChildItem $extractDir -Directory | Select-Object -First 1
Copy-Item "$($weeklyBackup.FullName)\lightrag_data.zip" -Destination "E:\RAG-Anything\RAG-Anything\lightrag\" -Force
Expand-Archive -Path "E:\RAG-Anything\RAG-Anything\lightrag\lightrag_data.zip" -DestinationPath "E:\RAG-Anything\RAG-Anything\lightrag\" -Force
Copy-Item "$($weeklyBackup.FullName)\.env" -Destination "E:\RAG-Anything\RAG-Anything\" -Force

# 4. 启动 LightRAG
set PYTHONIOENCODING=utf-8
python lightrag\start_server.py

# 5. 验证
curl.exe http://localhost:9621/health
```

### 4.5 备份验证脚本

保存为 `E:\RAG-Anything\scripts\verify_backup.ps1`：

```powershell
Write-Host "===== 备份验证检查 =====" -ForegroundColor Cyan

$latestDaily = Get-ChildItem "E:\RAG-Anything\data_backup\archives\lightrag_daily_"*.zip | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$latestWeekly = Get-ChildItem "E:\RAG-Anything\data_backup\archives\lightrag_weekly_"*.zip | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($latestDaily) {
    Write-Host "最新每日备份: $($latestDaily.Name) ($($latestDaily.LastWriteTime))" -ForegroundColor Green
} else {
    Write-Host "警告: 未找到每日备份" -ForegroundColor Red
}

if ($latestWeekly) {
    Write-Host "最新每周备份: $($latestWeekly.Name) ($($latestWeekly.LastWriteTime))" -ForegroundColor Green
    try {
        Expand-Archive -Path $latestWeekly.FullName -DestinationPath "E:\RAG-Anything\data_backup\test_extract" -Force
        Write-Host "备份文件完整性: OK" -ForegroundColor Green
        Remove-Item "E:\RAG-Anything\data_backup\test_extract" -Recurse -Force
    } catch {
        Write-Host "备份文件损坏: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "警告: 未找到每周备份" -ForegroundColor Red
}

docker-compose ps

$qdrantResult = curl.exe -s http://localhost:6333/collections 2>$null
if ($qdrantResult) {
    $qdrantResult | python -c "import sys,json; d=json.load(sys.stdin); [print(f'  {c[\"name\"]}: {c[\"vectors_count\"]} vectors') for c in d['result']['collections']]"
} else {
    Write-Host "  Qdrant 无法连接" -ForegroundColor Red
}

Write-Host "===== 检查完成 =====" -ForegroundColor Cyan
```

---

## 五、运维命令速查

### 日常操作

```powershell
# 启动全部服务
cd E:\RAG-Anything\RAG-Anything; docker-compose up -d

# 停止全部服务
cd E:\RAG-Anything\RAG-Anything; docker-compose down

# 重启单个服务
docker-compose restart qdrant
docker-compose restart redis
docker-compose restart neo4j

# 重启 LightRAG
netstat -ano | findstr :9621
taskkill /PID <PID> /F
set PYTHONIOENCODING=utf-8 && python lightrag\start_server.py

# 查看日志
docker-compose logs -f
docker-compose logs -f qdrant
docker-compose logs -f redis
docker-compose logs -f neo4j
```

### 健康检查脚本

保存为 `E:\RAG-Anything\scripts\health_check.ps1`：

```powershell
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
```

### 紧急故障处理

```powershell
# 故障1：LightRAG 无法启动（端口占用）
netstat -ano | findstr :9621
taskkill /PID <PID> /F
python lightrag\start_server.py

# 故障2：Qdrant 连接失败
docker-compose restart qdrant
Start-Sleep -Seconds 10
curl.exe http://localhost:6333/readyz

# 故障3：Redis 内存满
docker exec lightrag-redis redis-cli FLUSHALL
docker-compose restart redis

# 故障4：Neo4j 无法连接
docker-compose restart neo4j
Start-Sleep -Seconds 20
# 浏览器访问 http://localhost:7474 检查
```

---

## 六、快速参考

| 服务 | 端口 | 地址 | 说明 |
|------|------|------|------|
| LightRAG | 9621 | http://localhost:9621 | 主 API 服务 |
| Qdrant | 6333/6334 | http://localhost:6333 | 向量数据库 |
| Redis | 6379 | localhost:6379 | KV 存储 |
| Neo4j | 7474/7687 | http://localhost:7474 | 图数据库（用户: neo4j, 密码: password123） |

---

_小虾出品，品质保证 🦐_