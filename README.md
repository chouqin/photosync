# PhotoSync Backend

基于 Azure Blob Storage + FastAPI 的照片云同步后端，运行在自有 Azure VM 上，预算控制在 $20-25/月。

## 架构

- **存储**: Azure Blob Storage (Cool Tier) 存原图，Archive Tier 做老照片自动归档
- **计算**: 已有 Azure VM 跑 Docker Compose (FastAPI + Caddy)
- **数据库**: SQLite on VM 本地磁盘（零运维，每日自动备份到 Blob）
- **CDN**: Cloudflare Free Plan（推荐）或直接走 VM IP
- **缩略图**: VM 本地磁盘缓存，LRU 自动清理

## 目录结构

```
.
├── backend/          # FastAPI 后端代码
│   ├── main.py
│   ├── models.py
│   ├── storage.py
│   ├── thumbnails.py
│   ├── auth.py
│   ├── config.py
│   ├── requirements.txt
│   └── Dockerfile
├── caddy/
│   └── Caddyfile     # 反向代理 + HTTPS
├── data/
│   ├── db/           # SQLite 数据库（Docker volume）
│   └── cache/        # 缩略图缓存（Docker volume）
├── docker-compose.yml
└── .env              # 环境变量（从 .env.example 复制）
```

## 快速部署（全自动）

### 方案 A：一键全自动部署（推荐）

#### 1. 创建 Azure 资源（本地执行）

确保已安装 [Azure CLI](https://aka.ms/installazurecli) 并登录：

```bash
az login
```

运行部署脚本创建 Storage Account、Container 和生命周期策略：

```bash
cd infra
./deploy.sh
```

脚本会自动：
- 创建 Resource Group（默认 `photosync-rg`）
- 创建 Storage Account（Standard LRS，Cool Tier）
- 创建 `photos` 和 `backups` Container
- 配置生命周期策略（180 天自动转 Archive）
- 生成 `.env.deploy` 文件（包含密钥和密码）

#### 2. 部署到 VM（本地执行）

设置环境变量并一键部署：

```bash
export PHOTOSYNC_VM_IP=20.1.2.3          # 你的 VM 公网 IP
export PHOTOSYNC_VM_USER=azureuser       # VM 用户名
export PHOTOSYNC_VM_KEY=~/.ssh/id_rsa    # SSH 私钥路径（可选）

cd scripts
chmod +x deploy-to-vm.sh
./deploy-to-vm.sh
```

脚本会自动：
- 打包后端代码
- 上传到 VM
- 安装 Docker + Docker Compose
- 构建并启动服务
- 创建 systemd 开机自启
- 配置每日数据库备份到 Blob Archive

#### 3. 验证

```bash
curl http://YOUR_VM_IP/health
# 应返回 {"status":"ok"}
```

#### 4. 配置域名和 HTTPS

编辑 VM 上的 `/opt/photosync/caddy/Caddyfile`，把 `:80` 替换为你的域名：

```bash
ssh azureuser@YOUR_VM_IP
sudo nano /opt/photosync/caddy/Caddyfile
# 把 :80 改为 yourdomain.com
sudo docker compose -C /opt/photosync restart caddy
```

然后在 Cloudflare 添加 A 记录指向 VM IP。

#### 5. 开放防火墙

在 Azure Portal → VM → Networking → NSG 中放行：
- TCP 80 (HTTP)
- TCP 443 (HTTPS)

---

### 方案 B：手动部署

如果你更喜欢手动控制，参考以下步骤：

#### 1. 准备 Azure Blob Storage

在 Azure Portal 中：
1. 创建 Storage Account（Performance: Standard, Redundancy: LRS）
2. 创建 Container `photos`
3. 获取 Access Key

#### 2. 在 VM 上部署

```bash
# 上传代码到 VM
scp -r backend/ caddy/ docker-compose.yml azureuser@VM_IP:/opt/photosync/

# SSH 到 VM
ssh azureuser@VM_IP

# 运行初始化脚本
sudo bash /opt/photosync/scripts/setup-vm.sh
```

#### 3. 配置环境变量

```bash
cp .env.deploy .env   # 从 infra/deploy.sh 生成的文件
sudo chmod 600 .env
```

## API 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/auth/token` | 登录获取 JWT |
| GET | `/api/photos` | 照片列表（分页） |
| POST | `/api/photos/upload` | 上传照片 |
| GET | `/api/photos/{id}` | 照片元数据 |
| GET | `/api/photos/{id}/thumbnail?size=256` | 缩略图 |
| GET | `/api/photos/{id}/original?redirect=1` | 原图（默认 302 到 SAS URL） |
| DELETE | `/api/photos/{id}` | 删除照片 |

## 上传照片示例

```bash
curl -X POST http://your-domain/api/photos/upload \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -F "file=@photo.jpg" \
  -F "device_id=iphone-15-pro"
```

## Blob 生命周期策略（省成本关键）

在 Azure Portal 中为 Container 设置生命周期管理规则：

**规则 1: 原图自动归档**
- 如果 Blob 已创建于 180 天前
- 将 Blob 层移动到 Archive

**规则 2: 删除已删除照片的临时文件**
- 如果 Blob 已删除
- 在 7 天后永久删除

这样原图先存 Cool Tier（随时可看），半年后自动转入 Archive（ cheapest，检索时稍慢几秒）。

## 缩略图缓存管理

缩略图存储在 VM 本地 `./data/cache/`。定期清理：

```bash
# 进入 backend 容器执行清理
docker compose exec backend python -c "from thumbnails import cleanup_old_thumbnails; print(cleanup_old_thumbnails(30))"
```

或添加 cron job：
```bash
# 每天凌晨清理 30 天未访问的缩略图
0 3 * * * cd /opt/photosync && docker compose exec -T backend python -c "from thumbnails import cleanup_old_thumbnails; cleanup_old_thumbnails(30)" >> /var/log/photosync-cleanup.log 2>&1
```

## 备份

SQLite 数据库建议每日备份到 Blob Archive Tier：

```bash
# 可添加到 cron，每天执行
az storage blob upload \
  --account-name $AZURE_STORAGE_ACCOUNT \
  --container-name backups \
  --name "photosync-$(date +%Y%m%d).db" \
  --file ./data/db/photosync.db \
  --tier Archive
```

## 成本预估（基于已有 VM）

| 项目 | 月费用 |
|------|--------|
| Blob Storage Cool 2TB | ~$20.5 |
| Blob Storage 月增 50GB | ~$0.5 |
| VM（已有）| $0 |
| SQLite / 缓存 | $0 |
| Cloudflare CDN | $0 |
| 出站流量 | $0-1 |
| **总计** | **~$21-22** |

## 后续扩展

- **iOS App**: Swift + SwiftUI，调用上述 API
- **人脸/物体识别**: Azure Cognitive Services（5000 次/月免费）
- **搜索**: SQLite FTS5 全文索引
- **多用户**: 替换 SQLite 为 PostgreSQL，扩展 user 表
