// 预建管理员账号并关掉应用自己的登录，让第一次打开直接可用。
// 上游 2.5.9 只认自己的登录（不认代理用户、没有 OIDC），从环境变量建号的功能（UK_INITIAL_ADMIN_*）
// 只在未发布的 master（3.0.0-beta.0）上。这里用镜像自带的 socket.io-client 走上游自己的事件：
// setup 建号 → login 拿会话（setup 不登录，setSettings 要求已登录）→ getSettings 合并 →
// setSettings 打开 disableAuth。网页只经云吞网关进来，网关已经认了主人，不需要应用自己的登录。
// 幂等：成功后写标记文件，再跑（升级、重建）直接退出；已有账号且密码对不上（主人接管过）也不动它的设置。
import { io } from "socket.io-client";
import { existsSync, writeFileSync } from "node:fs";

const username = process.env.WONTON_OWNER_NAME;
const password = process.env.WONTON_SECRET_ADMIN_PASSWORD;
const marker = "/app/data/.setup-admin-ready";

const quit = (ok, msg) => {
    console[ok ? "log" : "error"](`setup-admin: ${msg}`);
    process.exit(ok ? 0 : 1);
};

if (!username || !password) quit(false, "缺少 WONTON_OWNER_NAME 或 WONTON_SECRET_ADMIN_PASSWORD");
if (existsSync(marker)) quit(true, "已完成过（标记文件在），跳过");

const socket = io("http://kuma:3001", {
    // 走轮询通道：上游只对 WebSocket 连接检查 Origin，polling 一律放行（server/uptime-kuma-server.js 的 allowRequest）。
    // kuma 还没监听时报 connect_error，靠自动重连等到它就绪。
    transports: ["polling"],
    reconnection: true,
    reconnectionDelay: 1000,
    reconnectionDelayMax: 1000,
});

// 整个流程的总时限（正常几秒内完成，重试也含在内）。超时按失败退出，由安装流程回滚并展示日志。
const deadline = setTimeout(() => quit(false, "180 秒内没完成（连不上或服务器没回应）"), 180_000);

// 发一个带 ack 的事件；30 秒没回应按失败处理
const ask = (event, ...args) => new Promise((resolve) => {
    socket.timeout(30_000).emit(event, ...args, (err, res) => resolve(err ? { ok: false, msg: "30 秒内没有回应" } : res));
});

socket.on("connect", async () => {
    try {
        // 先发 setup：只在我们刚建的号上生效，已有账号时上游回 initialized
        const setup = await ask("setup", username, password);
        if (!setup.ok && !/initialized/i.test(setup.msg || "")) {
            quit(false, `创建管理员失败：${setup.msg}`);
        }
        const fresh = setup.ok;

        const login = await ask("login", { username, password });
        if (!login.ok) {
            if (fresh) quit(false, `刚建好的账号登录失败：${JSON.stringify(login)}`);
            quit(true, "账号存在但密码对不上，视为主人已接管，跳过");
        }

        // 在现有 general 设置上只打开 disableAuth，不覆盖其他设置
        const settings = await ask("getSettings");
        if (!settings.ok) quit(false, `读设置失败：${settings.msg}`);
        settings.data.disableAuth = true;
        const saved = await ask("setSettings", settings.data, password);
        if (!saved.ok) quit(false, `打开 disableAuth 失败：${saved.msg}`);

        try {
            writeFileSync(marker, `${new Date().toISOString()}\n`);
        } catch (e) {
            quit(false, `写标记文件失败：${e.message}`);
        }
        quit(true, "管理员账号已就绪，应用自己的登录已关（disableAuth）");
    } catch (e) {
        quit(false, `未预期的错误：${e.message}`);
    }
});
