# shellcheck shell=bash
# Uptime Kuma：sso=none，用户第一次打开就是注册管理员页；清单没有 mcp。

web_assert() { grep -qi 'uptime kuma'; }   # 标准输入：应用页面

# 身份：Kuma 的应用登录已关（管理员账号预建，网页只经云吞网关进来），应用里没有可断言的用户身份，
# 主人能打开由 web_assert 和网关对匿名请求的 401 证明。
export IDENTITY_NA=1
export SMOKE_NOTE="Kuma 应用自己的登录已关（管理员账号预建），应用内没有用户身份可断言；主人会话能打开应用、网关拒绝匿名请求由网页项证明。"

marker_file() { # SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/kuma-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

_uma_container() { # 容器按核心打的标签找，不拼名字（钩子契约里没有 slug）
  local inst="${SMOKE_INSTANCE:-}" args=(--filter label=wonton.plugin=fyi.kuma.uptime-kuma --filter label=wonton.service=kuma)
  if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
    inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
  fi
  [[ -z "$inst" ]] || args+=(--filter "label=wonton.instance=${inst//-/}")
  docker ps --format '{{.Names}}' "${args[@]}" | head -1
}

# 数据：监控项就是用户数据（SQLite 在插件数据目录，重装保留）。Kuma 只有 socket.io 一个接口，
# 没有表单登录（管理员预建、应用登录已关，连接即认主人），所以用镜像自带的 node +
# socket.io-client 在容器里连本机应用建监控项，重装后监控列表里还在。
_kuma_node() { # <node 脚本> <标记>：容器内连 socket.io 跑一段脚本；清掉代理变量，127.0.0.1 不经 egress
  local container="$1" script="$2" marker="$3"
  docker exec -e KUMA_MARKER="$marker" -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= \
    -e ALL_PROXY= -e all_proxy= -e NO_PROXY=127.0.0.1,localhost -e no_proxy=127.0.0.1,localhost \
    "$container" node -e "$script"
}

data_write() {
  local container marker out
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设"; return 1; }
  container="$(_uma_container)"
  [[ -n "$container" ]] || { echo "找不到 kuma 容器（wonton.instance 标签）"; return 1; }
  marker="wonton-smoke-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
  out="$(_kuma_node "$container" '
    const io = require("socket.io-client");
    const s = io("http://127.0.0.1:3001");
    const fail = (m) => { console.error(m); process.exit(1); };
    // 连接错误只记到 stderr，socket.io-client 自动重连；总超时才判失败。
    const t = setTimeout(() => fail("socket 180 秒没连上"), 180000);
    s.on("connect_error", (e) => console.error("connect_error: " + e.message));
    s.on("connect", () => {
      s.emit("add", { type: "http", name: process.env.KUMA_MARKER,
        url: "http://127.0.0.1:3001/", interval: 120, retryInterval: 120, maxretries: 2,
        accepted_statuscodes: ["200-299"], conditions: [] },
        (res) => { clearTimeout(t); (res && res.ok) ? process.exit(0) : fail("add 被拒：" + JSON.stringify(res)); });
    });' "$marker")" || { echo "建监控项失败：$out"; return 1; }
  printf '%s' "$marker" >"$(marker_file)"
}

data_check() {
  local container marker out
  marker="$(cat "$(marker_file)" 2>/dev/null)" || { echo "没有 data_write 留下的标记"; return 1; }
  [[ -n "$marker" ]] || { echo "标记是空的"; return 1; }
  container="$(_uma_container)"
  [[ -n "$container" ]] || { echo "找不到 kuma 容器（wonton.instance 标签）"; return 1; }
  echo "data_check 容器：$container；HTTP 探测：$(docker exec "$container" node -e 'fetch("http://127.0.0.1:3001/").then(r=>console.log("HTTP",r.status)).catch(e=>console.log("ERR",e.message))' 2>&1 | tail -1)" >&2
  out="$(_kuma_node "$container" '
    const io = require("socket.io-client");
    const s = io("http://127.0.0.1:3001");
    const fail = (m) => { console.error(m); process.exit(1); };
    // 重装后 kuma 首次启动要做建库和初始化，socket 晚于容器 healthy 才收连接。
    // socket.io-client 会自动重连：连接错误只记到 stderr，不退出；总超时才判失败。
    s.on("connect_error", (e) => console.error("connect_error: " + e.message));
    const t = setTimeout(() => fail("180 秒没等到 monitorList 推送"), 180000);
    s.on("connect", () => {
      console.error("socket 已连上");
      // 2.5.9 的 getMonitorList handler 只收 ack 一个参数，emit 多传数据参数会把 ack 挤掉
      // （服务端拿数据参数当 callback 调，TypeError，ack 永远不回，客户端无任何错误事件）。
      s.emit("getMonitorList", (res) => {
        if (!(res && res.ok)) console.error("getMonitorList 被拒：" + JSON.stringify(res));
      });
    });
    // ack 只回 {ok:true}；列表经 monitorList 事件推给已自动登录（disableAuth）的这个 socket。
    s.on("monitorList", (list) => {
      clearTimeout(t);
      const names = Object.values(list || {}).map((m) => m.name);
      if (names.includes(process.env.KUMA_MARKER)) process.exit(0);
      fail("监控列表里没有标记，列表是：" + names.join(", "));
    });' "$marker")" || { echo "重装后监控项不在了：$out"; return 1; }
}
