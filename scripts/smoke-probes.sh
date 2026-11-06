# shellcheck shell=bash
# Uptime Kuma：sso=none，用户第一次打开就是注册管理员页；清单没有 mcp。

web_assert() { grep -qi 'uptime kuma'; }   # 标准输入：应用页面

identity_check() { # 首页在没账号时就是首次注册页（/setup），断言这是注册页而不是错误页
  local page
  page="$(web_get / -H 'Accept: text/html')" || { echo "首页失败：$page"; return 1; }
  grep -qiE 'setup|管理员|admin account|create' <<<"$page" || { echo "不是首次注册页：$(head -c 150 <<<"$page")"; return 1; }
}
