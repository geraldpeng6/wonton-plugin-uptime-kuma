// 预建管理员账号、关掉应用自己的登录，并预置发进云吞私聊的邮件通知。
// 上游 2.5.9 只认自己的登录（不认代理用户、没有 OIDC），从环境变量建号的功能（UK_INITIAL_ADMIN_*）
// 只在未发布的 master（3.0.0-beta.0）上。这里用镜像自带的 socket.io-client 走上游自己的事件：
// setup 建号 → login 拿会话（setup 不登录，setSettings 要求已登录）→ getSettings 合并 →
// setSettings 打开 disableAuth。网页只经云吞网关进来，网关已经认了主人，不需要应用自己的登录。
// 邮件：登录后等上游推来的 notificationList，没有同主机同收件人的 SMTP 通知时用 addNotification
// 预置一条（上游 2.5.9 没有 SMTP 的环境变量，通知只能走它自己的事件存库）。isDefault 打开，
// 新建监控默认用它；不动已有监控（applyExisting 不开，主人自己在监控里勾）。
// 幂等：两步各自成功后写标记文件，再跑（升级、重建）看到标记直接退出；已有账号且密码对不上
// （主人接管过）也不动它的设置、不预置通知。
import { io } from "socket.io-client";
import { existsSync, writeFileSync } from "node:fs";

const username = process.env.WONTON_OWNER_NAME;
const password = process.env.WONTON_SECRET_ADMIN_PASSWORD;
const smtpHost = process.env.WONTON_SMTP_HOST;
const smtpPort = Number(process.env.WONTON_SMTP_PORT);
const mailFrom = process.env.WONTON_MAIL_FROM;
const ownerEmail = process.env.WONTON_OWNER_EMAIL;
const accountMarker = "/app/data/.setup-admin-ready";
const mailMarker = "/app/data/.setup-mail-ready";

const quit = (ok, msg) => {
    console[ok ? "log" : "error"](`setup-admin: ${msg}`);
    process.exit(ok ? 0 : 1);
};

const mark = (file) => writeFileSync(file, `${new Date().toISOString()}\n`);

if (!username || !password) quit(false, "缺少 WONTON_OWNER_NAME 或 WONTON_SECRET_ADMIN_PASSWORD");

const needAccount = !existsSync(accountMarker);
const needMail = !existsSync(mailMarker);
if (!needAccount && !needMail) quit(true, "已完成过（标记文件在），跳过");

if (needMail && (!smtpHost || !mailFrom || !ownerEmail)) {
    quit(false, "缺少 WONTON_SMTP_HOST、WONTON_MAIL_FROM 或 WONTON_OWNER_EMAIL");
}
if (needMail && (!Number.isInteger(smtpPort) || smtpPort <= 0 || smtpPort > 65535)) {
    quit(false, `WONTON_SMTP_PORT 不是端口号：${JSON.stringify(process.env.WONTON_SMTP_PORT)}`);
}

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

// 上游在登录成功后（含 disableAuth 的连接即自动登录）把通知列表推到 socket 上，
// addNotification 前要用它查重。等不到按超时给 null。
let gotNotificationList;
const notificationList = new Promise((resolve) => { gotNotificationList = resolve; });
socket.on("notificationList", (list) => gotNotificationList(list));
const firstNotificationList = (ms) => Promise.race([
    notificationList,
    new Promise((resolve) => setTimeout(() => resolve(null), ms)),
]);

let running = false;
socket.on("connect", async () => {
    if (running) return; // 断线重连会再触发；流程还在跑就让原来的继续
    running = true;
    try {
        if (needAccount) {
            // 先发 setup：只在我们刚建的号上生效，已有账号时上游回 initialized
            const setup = await ask("setup", username, password);
            if (!setup.ok && !/initialized/i.test(setup.msg || "")) {
                quit(false, `创建管理员失败：${setup.msg}`);
            }
            const fresh = setup.ok;

            const login = await ask("login", { username, password });
            if (!login.ok) {
                if (fresh) quit(false, `刚建好的账号登录失败：${JSON.stringify(login)}`);
                quit(true, "账号存在但密码对不上，视为主人已接管，跳过设置和邮件通知预置");
            }

            // 在现有 general 设置上只打开 disableAuth，不覆盖其他设置
            const settings = await ask("getSettings");
            if (!settings.ok) quit(false, `读设置失败：${settings.msg}`);
            settings.data.disableAuth = true;
            const saved = await ask("setSettings", settings.data, password);
            if (!saved.ok) quit(false, `打开 disableAuth 失败：${saved.msg}`);

            mark(accountMarker);
        } else if (needMail) {
            // 账号已就绪：disableAuth 开着时连上即被自动登录，通知列表会直接推来；
            // 等不到（主人重新打开过登录）再用预置密码登录，对不上视为主人接管。
            const auto = await firstNotificationList(10_000);
            if (!auto) {
                const login = await ask("login", { username, password });
                if (!login.ok) {
                    quit(true, "账号存在但密码对不上，视为主人已接管，跳过邮件通知预置");
                }
            }
        }

        if (needMail) {
            const list = await firstNotificationList(30_000);
            if (!Array.isArray(list)) quit(false, "登录后没收到通知列表（notificationList）");

            const sameAsOurs = (n) => {
                try {
                    const cfg = typeof n.config === "string" ? JSON.parse(n.config) : (n.config || {});
                    return cfg.type === "smtp" && cfg.smtpHost === smtpHost && cfg.smtpTo === ownerEmail;
                } catch {
                    return false;
                }
            };

            let mailMsg;
            if (list.some(sameAsOurs)) {
                mailMsg = "已有一条同主机同收件人的邮件通知，跳过预置";
            } else {
                // secure=false 加 ignoreSTARTTLS：上游 smtp.js 据此设 ignoreTLS，连接保持明文；
                // 不填用户名密码，上游就不发 AUTH。
                const saved = await ask("addNotification", {
                    name: "Wonton",
                    type: "smtp",
                    isDefault: true,
                    active: true,
                    smtpHost,
                    smtpPort,
                    smtpSecure: false,
                    smtpIgnoreSTARTTLS: true,
                    smtpFrom: mailFrom,
                    smtpTo: ownerEmail,
                }, null);
                if (!saved.ok) quit(false, `预置邮件通知失败：${saved.msg}`);
                mailMsg = "已预置邮件通知（新建监控默认把告警发进云吞私聊）";
            }
            mark(mailMarker);

            quit(true, needAccount
                ? `管理员账号已就绪，应用自己的登录已关（disableAuth），${mailMsg}`
                : mailMsg);
        }

        quit(true, "管理员账号已就绪，应用自己的登录已关（disableAuth）");
    } catch (e) {
        quit(false, `未预期的错误：${e.message}`);
    }
});
