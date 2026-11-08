# Uptime Kuma 云吞插件

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)。

[Uptime Kuma](https://uptime.kuma.pet) 的云吞插件（应用许可证 MIT）：监控公网站点与局域网设备，通过应用自带的通知
渠道告警。网页免登录直接用（管理员账号已预建，见下面的「账号和登录」），同时受云吞网关保护；Push 心跳、公开状态页和其他
插件网页监控的限制见清单 `about`。

## 图标来源

`icon.png` 使用 Uptime Kuma 2.5.9 的官方 `public/icon-512x512.png`，未用图片模型生成；来源、版权、处理方式、上游 MIT 全文和商标说明见 [NOTICE](NOTICE)。

Uptime Kuma 名称和标志是上游项目的商标，权利归相应权利人。本插件是社区适配，不暗示与上游官方合作、关联或获得背书。

## 先跑起来

```bash
scripts/dev.sh up
scripts/dev.sh install
```

`up` 在本机起一套云吞并打印它的地址，用 `scripts/dev.sh token` 输出的用户令牌登录；`install` 列出插件要的权限，确认后
装上并打印插件网页的地址；第一次打开直接可用，不用再登录应用本身（见下面的「账号和登录」）。

## 账号和登录

装好就用，不用选数据库、注册管理员，也不用记应用密码：

- 数据库固定为 SQLite（compose 里的 `UPTIME_KUMA_DB_TYPE`），上游见到这个变量就跳过数据库设置页。
- 管理员账号由一次性服务 `setup-admin` 预建：用镜像自带的 socket.io-client 调上游自己的 `setup` 事件，等价于在注册页提交
  一次。用户名是云吞用户名（`owner.identity` 权限）。
- 建好账号后它再调上游的 `setSettings` 打开 `disableAuth`（上游自带的“前面有第三方认证时关掉登录”）。网页只经云吞网关
  进来，网关已经认了主人，所以打开直接是仪表盘，不需要应用密码。

想恢复应用自己的登录（比如想再加一层）：在 Uptime Kuma 的“设置 → 安全”里关掉“Disable Auth”。之后登录用的是预建密码——
核心生成的随机密钥，App 里看不到（规范也把“插件密钥在 App 里查看”列为待办），在宿主机上取：

```bash
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
  "$(docker ps -aq --filter name=setup-admin)" | grep WONTON_SECRET_ADMIN_PASSWORD
```

登录后建议在“设置 → 安全”里改成自己的密码。密码忘了：按 Kuma 自己的办法重置（在宿主机进容器执行它的
`npm run reset-password`）。

## 通知和邮件

装好即在 Uptime Kuma 的“设置 → 通知”里有一条预置的邮件通知 **Wonton**：SMTP 主机、端口、发件人用核心注入的值，
收件人是你的内部邮箱（`<用户名>@wonton.internal`）。新建的监控默认勾上它，掉线/恢复的信会出现在你的云吞私聊里；
已有的监控在监控的编辑页勾上它，或在通知设置里勾“对所有现有监控生效”。

收件人只能是家里人：把收件人改成外部邮箱，发送时核心在 SMTP 阶段就拒收（550），Kuma 的通知会报发送失败。
Telegram、Webhook 等其他渠道照常自己加。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：compose 加上 `x-wonton` 清单 |
| `icon.png` | 上游官方标志，透明区域铺白底的满幅 PNG（清单引用） |
| `screenshots/` | 商店详情页里的截图 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/smoke-probes.sh` | `scripts/dev.sh smoke` 对这个插件逐项的探测 |
| `scripts/publish.sh` | 发布一个版本：构建自己的镜像、按摘要写回、打 tag、推送 |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE`、`NOTICE` | 插件许可证、上游 MIT 许可证和商标声明 |
