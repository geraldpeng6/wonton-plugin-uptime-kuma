// 预建管理员账号，让第一次打开直接是登录页。
// 上游 2.5.9 只认自己的登录（不认代理用户、没有 OIDC），从环境变量建号的功能（UK_INITIAL_ADMIN_*）
// 只在未发布的 master（3.0.0-beta.0）上有。这里用镜像自带的 socket.io-client 调上游自己的 "setup"
// 事件建号，等价于在注册页里提交一次，不碰数据库内部结构。
// setup 只在用户表为空时生效：升级、重启时上游返回 initialized，本脚本按成功退出，所以天然幂等。
import { io } from "socket.io-client";

const username = process.env.WONTON_OWNER_NAME;
const password = process.env.WONTON_SECRET_ADMIN_PASSWORD;

if (!username || !password) {
    console.error("setup-admin: 缺少 WONTON_OWNER_NAME 或 WONTON_SECRET_ADMIN_PASSWORD");
    process.exit(1);
}

const socket = io("http://kuma:3001", {
    // 走轮询通道：上游只对 WebSocket 连接检查 Origin，polling 一律放行（server/uptime-kuma-server.js 的 allowRequest）。
    // kuma 还没监听时报 connect_error，靠自动重连等到它就绪。
    transports: ["polling"],
    reconnection: true,
    reconnectionDelay: 1000,
    reconnectionDelayMax: 1000,
    // 等待超过 kuma 启动（含数据库迁移）的合理时间仍连不上，按失败退出，由安装流程回滚并展示日志。
});

const timeout = setTimeout(() => {
    console.error("setup-admin: 120 秒内连不上 kuma 的 Socket.IO 接口");
    socket.disconnect();
    process.exit(1);
}, 120_000);

socket.on("connect", () => {
    clearTimeout(timeout);
    socket.timeout(30_000).emit("setup", username, password, (err, res) => {
        if (err) {
            console.error("setup-admin: 服务器 30 秒内没有回应 setup 请求");
            socket.disconnect();
            process.exit(1);
        } else if (res.ok) {
            console.log(`setup-admin: 管理员账号 ${username} 已创建`);
            socket.disconnect();
            process.exit(0);
        } else if (/initialized/i.test(res.msg)) {
            console.log("setup-admin: 已有账号，跳过");
            socket.disconnect();
            process.exit(0);
        } else {
            console.error(`setup-admin: 创建管理员失败：${res.msg}`);
            socket.disconnect();
            process.exit(1);
        }
    });
});
