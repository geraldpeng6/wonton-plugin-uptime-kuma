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

  # 预置的邮件通知：恰一条，配置是核心注入的值（见 setup-admin.mjs 的预置）。
  # 2.5.9 把 SMTP 字段整个 JSON 字符串化存进 notification.config（server/notification.js 的 save），
  # 列表推回的也是 config 字符串，字段要 parse 出来比。
  _uma_notification_assert
}

# ---------- 邮件（notify）：预置通知核对 + 真实发一封（extra_check 由 e2e 冒烟跑） ----------

admin_container() { # setup-admin 一次性服务（跑完就退出）：按核心打的标签找
  docker ps -a --format '{{.Names}}' \
    --filter label=wonton.plugin=fyi.kuma.uptime-kuma --filter label=wonton.service=setup-admin |
    head -1
}

kuma_env_value() { # <变量名>：从 setup-admin 容器环境读核心注入的值（kuma 服务不用这些变量）
  docker inspect "$(admin_container)" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    sed -n "s/^$1=//p" | tail -1
}

_uma_notifications() { # stdout：notificationList 的 JSON（连上即自动登录，列表直接推来）
  local container="$1"
  _kuma_node "$container" '
    const io = require("socket.io-client");
    const s = io("http://127.0.0.1:3001");
    const fail = (m) => { console.error(m); process.exit(1); };
    // 重连由 socket.io-client 自动做；连接错误记到 stderr，总超时才判失败。
    s.on("connect_error", (e) => console.error("connect_error: " + e.message));
    const t = setTimeout(() => fail("180 秒没等到 notificationList 推送"), 180000);
    s.on("notificationList", (list) => {
      clearTimeout(t); console.log(JSON.stringify(list || [])); process.exit(0);
    });'
}

_uma_notification_assert() { # 预置的 Wonton 邮件通知恰一条，值都是核心注入的
  local want_host want_port want_from want_to notifs n
  want_host="$(kuma_env_value WONTON_SMTP_HOST)"
  want_port="$(kuma_env_value WONTON_SMTP_PORT)"
  want_from="$(kuma_env_value WONTON_MAIL_FROM)"
  want_to="$(kuma_env_value WONTON_OWNER_EMAIL)"
  [[ -n "$want_host" && -n "$want_port" && -n "$want_from" && -n "$want_to" ]] ||
    { echo "setup-admin 容器里读不到注入的 SMTP 变量（安装没带 notify？）"; return 1; }
  local container
  container="$(_uma_container)"
  [[ -n "$container" ]] || { echo "找不到 kuma 容器（wonton.instance 标签）"; return 1; }
  notifs="$(_uma_notifications "$container")" ||
    { echo "读通知列表失败：$(head -c 200 <<<"$notifs")"; return 1; }
  n="$(jq '[.[] | select((.config | fromjson? | .type // "") == "smtp")] | length' <<<"$notifs")"
  [[ "$n" == 1 ]] || { echo "邮件通知该恰有一条，实际 $n：$(head -c 300 <<<"$notifs")"; return 1; }
  jq -e --arg h "$want_host" --arg p "$want_port" --arg f "$want_from" --arg t "$want_to" '
    .[0] as $n | ($n.config | fromjson) as $c |
    $n.name == "Wonton" and $n.isDefault == true and $n.active == true
      and $c.type == "smtp" and $c.smtpHost == $h and ($c.smtpPort | tostring) == $p
      and $c.smtpFrom == $f and $c.smtpTo == $t
      and $c.smtpSecure == false and $c.smtpIgnoreSTARTTLS == true
      and ($c.smtpUsername // "") == "" and ($c.smtpPassword // "") == ""' <<<"$notifs" >/dev/null ||
    { echo "预置邮件通知的配置不是核心注入的值：$(jq -c '.[0]' <<<"$notifs")"; return 1; }
  echo "预置邮件通知在（$want_host:$want_port，from $want_from，to $want_to）"
}

core_container() { # 核心容器：和插件容器同一个 compose 项目（Mailpit 只在核心的私有网络里）
  local project
  project="$(docker inspect "$(_uma_container)" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)"
  [[ -n "$project" ]] || { echo "读不到插件容器的 compose 项目"; return 1; }
  docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$project" |
    grep -E -- '--core$' | head -1
}

mailpit_messages() { # 经核心的网络栈读 Mailpit 收件箱 API（SMTP 25/HTTP 8025 都不发布到宿主）
  docker run --rm --network "container:$(core_container)" curlimages/curl:8.23.0 --noproxy '*' -s \
    "http://mailpit.wonton.internal:8025/api/v1/messages?limit=50"
}

extra_check() { # 邮件专项：真实发一封测试信，核对核心投递；再验证外部收件人被 550 拒收
  local want_host want_port want_from want_to out mails delivered
  want_host="$(kuma_env_value WONTON_SMTP_HOST)"
  want_port="$(kuma_env_value WONTON_SMTP_PORT)"
  want_from="$(kuma_env_value WONTON_MAIL_FROM)"
  want_to="$(kuma_env_value WONTON_OWNER_EMAIL)"
  [[ -n "$want_host" && -n "$want_port" && -n "$want_from" && -n "$want_to" ]] ||
    { echo "注入的 SMTP 变量读不到"; return 1; }
  [[ "$want_host" == "smtp.wonton.internal" && "$want_port" == "25" &&
     "$want_from" == "fyi.kuma.uptime-kuma@plugins.wonton.internal" ]] ||
    { echo "注入值不对：host=$want_host port=$want_port from=$want_from"; return 1; }
  echo "注入值就位：$want_host:$want_port，from $want_from，to $want_to"
  _uma_notification_assert || return 1

  local container
  container="$(_uma_container)"
  [[ -n "$container" ]] || { echo "找不到 kuma 容器（wonton.instance 标签）"; return 1; }

  # 测试信（应用设置页的“测试”走同一个事件，主题固定“Wonton Testing”）：预置通知的原样配置。
  # 不填用户名密码——上游 smtp.js 只在两者非空时才发 AUTH。
  out="$(docker exec -e KUMA_NOTIFICATION="$(
      jq -cn --arg h "$want_host" --arg p "$want_port" --arg f "$want_from" --arg t "$want_to" \
        '{name:"Wonton",type:"smtp",smtpHost:$h,smtpPort:($p|tonumber),smtpSecure:false,
          smtpIgnoreSTARTTLS:true,smtpFrom:$f,smtpTo:$t}')" \
    -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= \
    -e ALL_PROXY= -e all_proxy= -e NO_PROXY=127.0.0.1,localhost -e no_proxy=127.0.0.1,localhost \
    "$container" node -e '
    const io = require("socket.io-client");
    const s = io("http://127.0.0.1:3001");
    const fail = (m) => { console.error(m); process.exit(1); };
    s.on("connect_error", (e) => console.error("connect_error: " + e.message));
    const t = setTimeout(() => fail("60 秒没等到测试结果"), 60000);
    s.on("connect", () => {
      s.emit("testNotification", JSON.parse(process.env.KUMA_NOTIFICATION), (res) => {
        clearTimeout(t); console.log(JSON.stringify(res));
        process.exit(res && res.ok ? 0 : 1);
      });
    });' 2>&1)" || { echo "测试信没发出去：$out"; return 1; }
  grep -q 'Sent Successfully' <<<"$out" || { echo "应用没报发送成功：$(head -c 300 <<<"$out")"; return 1; }
  echo "测试信应用报发送成功（$want_from → $want_to）"

  # 核心订阅 Mailpit、把信投进收件人的 Wonton 私聊后从 Mailpit 删掉：轮询等它取走，取不走才算失败。
  delivered=1
  for _ in {1..12}; do
    sleep 5
    mails="$(mailpit_messages)" || { echo "读 Mailpit 失败：$(head -c 200 <<<"$mails")"; return 1; }
    delivered="$(jq -r '[.messages[] | select(.Subject == "Wonton Testing")] | length' <<<"$mails" 2>/dev/null)"
    [[ "$delivered" == 0 ]] && { delivered=0; break; }
  done
  [[ "$delivered" == 0 ]] || { echo "等了 60 秒测试信还在 Mailpit 里没被投递"; return 1; }
  echo "测试信已被核心投递（Mailpit 里删了）"

  # 外部收件人：同一配置发给外部地址，应用要报发送失败（核心在 SMTP 阶段 550 拒收）
  out="$(docker exec -e KUMA_NOTIFICATION="$(
      jq -cn --arg h "$want_host" --arg p "$want_port" --arg f "$want_from" \
        '{name:"Wonton",type:"smtp",smtpHost:$h,smtpPort:($p|tonumber),smtpSecure:false,
          smtpIgnoreSTARTTLS:true,smtpFrom:$f,smtpTo:"wonton-smoke-external@example.com"}')" \
    -e HTTP_PROXY= -e HTTPS_PROXY= -e http_proxy= -e https_proxy= \
    -e ALL_PROXY= -e all_proxy= -e NO_PROXY=127.0.0.1,localhost -e no_proxy=127.0.0.1,localhost \
    "$container" node -e '
    const io = require("socket.io-client");
    const s = io("http://127.0.0.1:3001");
    const fail = (m) => { console.error(m); process.exit(1); };
    s.on("connect_error", (e) => console.error("connect_error: " + e.message));
    const t = setTimeout(() => fail("60 秒没等到测试结果"), 60000);
    s.on("connect", () => {
      s.emit("testNotification", JSON.parse(process.env.KUMA_NOTIFICATION), (res) => {
        clearTimeout(t); console.log(JSON.stringify(res));
        process.exit(res && res.ok ? 1 : 0);   // 这里期望失败
      });
    });' 2>&1)"
  if grep -q '"ok":true' <<<"$out"; then
    echo "发往外部地址竟然成功：$(head -c 300 <<<"$out")"
    return 1
  fi
  grep -q '550' <<<"$out" || { echo "外部收件人的失败不是 550 拒收：$(head -c 300 <<<"$out")"; return 1; }
  echo "发往外部地址应用报失败，核心 550 拒收"
}
