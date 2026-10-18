// 拾掇 Pro 授权中转（Cloudflare Worker）
// App 不能内置 Creem 的 API 密钥（代码是公开的），所以由这个小服务代为调用 Creem。
// 只转发三件事：激活、校验、解绑；并且只认拾掇 Pro 这个产品的授权码。
//
// 需要在 Cloudflare 里设置：
//   CREEM_API_KEY  （Secret）Creem 后台 ▸ Developers ▸ API Keys
//   PRODUCT_ID     （变量）Creem 里拾掇 Pro 产品的 ID，形如 prod_xxx；多个用英文逗号隔开
//   CREEM_API      （变量，可选）测试时填 https://test-api.creem.io
//   ADMIN_TOKEN    （Secret）兑换码管理页的密码，自己定
//   GIFTS          （KV 绑定）存兑换码
//
// 返回给 App 的格式（与 App 里 LicenseAPI.parse 对应）：
//   { activated|valid|deactivated: Bool, error?: String,
//     instance: { id }, license_key: { status }, meta: { product_id } }
//
// 只有「明确不可用」（找不到、过期、停用、激活数用完、不是本产品）才返回 valid:false。
// Creem 5xx / 429 / 网络错误 / 看不懂的回答是暂时性的：返回 { error, transient: true }，不带 valid 字段，
// 状态码 502 / 503 / 429。App 收到后保持现状、稍后重试，不会解绑本机。

function transient(error, status = 503) {
  return json({ error, transient: true }, status);
}

const ACTIONS = { activate: "activated", validate: "valid", deactivate: "deactivated" };

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

// ---------- 兑换码（送朋友 / 粉丝） ----------
// 兑换码形如 SDG-XXXX-XXXX-XXXX，存在 KV（绑定名 GIFTS）里，每个码只能同时激活一台 Mac，
// 解绑后可以换到另一台。管理页：打开 <Worker 地址>/admin，输入 ADMIN_TOKEN 生成 / 查看 / 作废。

const ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"; // 去掉了 0 O 1 I 等容易看错的字符

function newGiftCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  const chars = Array.from(bytes, b => ALPHABET[b % 32]).join("");
  return `SDG-${chars.slice(0, 4)}-${chars.slice(4, 8)}-${chars.slice(8, 12)}`;
}

function isGift(key) {
  return /^SDG-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}$/.test(key);
}

async function handleGift(action, flag, key, input, env) {
  if (!env.GIFTS) return transient("gift codes not configured", 502);
  let raw;
  try { raw = await env.GIFTS.get("gift:" + key); } catch { return transient("upstream unavailable"); }
  if (!raw) return json({ [flag]: false, error: "license_key not found." }, 404);
  const rec = JSON.parse(raw);
  const meta = { product_id: env.PRODUCT_ID ? String(env.PRODUCT_ID).split(",")[0].trim() : "gift" };
  if (rec.status === "revoked") {
    return json({ [flag]: false, error: "license disabled", license_key: { status: "disabled" }, meta });
  }
  if (action === "activate") {
    if (rec.instance_id) return json({ activated: false, error: "activation limit reached" }, 400);
    rec.instance_id = "gift_inst_" + crypto.randomUUID();
    rec.instance_name = String(input.instance_name || "Mac").slice(0, 100);
    rec.activated_at = new Date().toISOString();
    await env.GIFTS.put("gift:" + key, JSON.stringify(rec));
    return json({ activated: true, instance: { id: rec.instance_id }, license_key: { status: "active" }, meta });
  }
  const same = rec.instance_id && rec.instance_id === String(input.instance_id || "");
  if (action === "validate") {
    return json({ valid: !!same, error: same ? undefined : "instance not found.", instance: same ? { id: rec.instance_id } : undefined,
      license_key: { status: rec.instance_id ? "active" : "inactive" }, meta });
  }
  // deactivate
  if (!same) return json({ deactivated: false, error: "instance not found." }, 404);
  delete rec.instance_id; delete rec.instance_name; delete rec.activated_at;
  await env.GIFTS.put("gift:" + key, JSON.stringify(rec));
  return json({ deactivated: true, license_key: { status: "inactive" }, meta });
}

const ADMIN_HTML = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>拾掇 Pro 兑换码</title>
<style>body{font:15px -apple-system,system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 16px;color:#222}
input,select,button{font:inherit;padding:8px 10px;margin:4px 0;border:1px solid #ccc;border-radius:8px}button{background:#2f6fed;color:#fff;border:0;cursor:pointer}
textarea{width:100%;height:260px;font:13px ui-monospace,monospace;border-radius:8px;border:1px solid #ccc;padding:8px}label{display:block;margin-top:10px}</style>
<h2>拾掇 Pro 兑换码</h2>
<label>管理密码 <input id="t" type="password" placeholder="ADMIN_TOKEN"></label>
<label>数量 <input id="n" type="number" value="5" min="1" max="200"></label>
<label>备注（送给谁） <input id="note" placeholder="例如：小红书粉丝抽奖"></label>
<p><button onclick="go('new')">生成兑换码</button> <button onclick="go('list')">查看全部</button></p>
<label>作废某个码 <input id="code" placeholder="SDG-XXXX-XXXX-XXXX"> <button onclick="go('revoke')">作废</button></label>
<textarea id="out" readonly></textarea>
<script>
async function go(a){const r=await fetch('/admin/'+a,{method:'POST',headers:{'content-type':'application/json'},
body:JSON.stringify({token:t.value,count:+n.value,note:note.value,code:code.value.trim().toUpperCase()})});out.value=await r.text();}
</script></html>`;

async function handleAdmin(path, request, env) {
  if (request.method === "GET" && path === "/admin") {
    return new Response(ADMIN_HTML, { headers: { "content-type": "text/html; charset=utf-8" } });
  }
  if (request.method !== "POST") return json({ error: "not found" }, 404);
  let input = {};
  try { input = await request.json(); } catch {}
  if (!env.ADMIN_TOKEN || String(input.token || "") !== env.ADMIN_TOKEN) {
    return new Response("管理密码不对。", { status: 401 });
  }
  if (!env.GIFTS) return new Response("还没有绑定 KV（变量名 GIFTS）。", { status: 500 });
  const text = (s, status = 200) => new Response(s, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
  if (path === "/admin/new") {
    const count = Math.min(200, Math.max(1, parseInt(input.count, 10) || 1));
    const note = String(input.note || "").slice(0, 100);
    const codes = [];
    for (let i = 0; i < count; i++) {
      const code = newGiftCode();
      await env.GIFTS.put("gift:" + code, JSON.stringify({ status: "ok", note, created_at: new Date().toISOString() }));
      codes.push(code);
    }
    return text(codes.join("\n"));
  }
  if (path === "/admin/list") {
    const lines = [];
    let cursor;
    do {
      const page = await env.GIFTS.list({ prefix: "gift:", cursor });
      for (const k of page.keys) {
        const rec = JSON.parse((await env.GIFTS.get(k.name)) || "{}");
        const state = rec.status === "revoked" ? "已作废" : rec.instance_id ? `已激活（${rec.instance_name || "Mac"}）` : "未使用";
        lines.push(`${k.name.slice(5)}\t${state}\t${rec.note || ""}`);
      }
      cursor = page.list_complete ? undefined : page.cursor;
    } while (cursor);
    return text(lines.length ? lines.join("\n") : "还没有兑换码。");
  }
  if (path === "/admin/revoke") {
    const code = String(input.code || "");
    const raw = await env.GIFTS.get("gift:" + code);
    if (!raw) return text("找不到这个码。", 404);
    const rec = JSON.parse(raw);
    rec.status = "revoked";
    await env.GIFTS.put("gift:" + code, JSON.stringify(rec));
    return text(`${code} 已作废。`);
  }
  return json({ error: "not found" }, 404);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/admin" || url.pathname.startsWith("/admin/")) return handleAdmin(url.pathname, request, env);
    const match = url.pathname.match(/^\/v1\/licenses\/(activate|validate|deactivate)$/);
    if (request.method === "GET" && url.pathname === "/") return json({ ok: true, service: "shiduo-license" });
    if (!match || request.method !== "POST") return json({ error: "not found" }, 404);
    const action = match[1];
    const flag = ACTIONS[action];

    let input;
    try { input = await request.json(); } catch { return json({ [flag]: false, error: "invalid request" }, 400); }
    const key = String(input.key || "").trim();
    if (!key || key.length > 200) return json({ [flag]: false, error: "license_key not found." }, 404);

    if (isGift(key.toUpperCase())) return handleGift(action, flag, key.toUpperCase(), input, env);

    const payload = { key };
    if (action === "activate") payload.instance_name = String(input.instance_name || "Mac").slice(0, 100);
    else {
      const id = String(input.instance_id || "");
      if (!id) return json({ [flag]: false, error: "instance not found." }, 404);
      payload.instance_id = id;
    }

    const base = env.CREEM_API || "https://api.creem.io";
    let res, data;
    try {
      res = await fetch(`${base}/v1/licenses/${action}`, {
        method: "POST",
        headers: { "x-api-key": env.CREEM_API_KEY, "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify(payload),
      });
      data = await res.json();
    } catch {
      // 网络错误，或 Creem 出故障时返回的不是 JSON（比如 502 的 HTML 页面）。
      return transient("upstream unavailable", 502);
    }

    if (!res.ok) {
      const msg = Array.isArray(data?.message) ? data.message.join(" ") : (data?.message || data?.error || "");
      const low = String(msg).toLowerCase();
      // 暂时性的问题先判断：限流、Creem 自己出错、密钥配置错。都不能告诉 App「授权无效」。
      if (res.status === 429) return transient("too many requests", 429);
      if (res.status >= 500) return transient("upstream unavailable", 502);
      if (res.status === 401 || res.status === 403) return transient("server misconfigured", 502);
      let error;
      if (res.status === 404 || low.includes("not found")) error = action === "activate" ? "license_key not found." : "instance not found.";
      else if (low.includes("limit")) error = "activation limit reached";
      else if (low.includes("expired")) error = "license expired";
      else if (low.includes("disabled")) error = "license disabled";
      // 激活时的「授权码无效」不会让 App 解绑什么，可以直接告诉用户；校验时不这样猜。
      else if (action === "activate" && low.includes("invalid")) error = "license_key not found.";
      // 其他看不懂的 4xx：按暂时性处理，宁可稍后重试也不误解绑。
      if (!error) return transient("upstream unavailable", 502);
      // 授权明确不可用：告诉 App
      return json({ [flag]: false, error }, 400);
    }

    const allowed = String(env.PRODUCT_ID || "").split(",").map(s => s.trim()).filter(Boolean);
    if (allowed.length && !allowed.includes(data.product_id)) {
      // 不是拾掇 Pro 的授权码；激活时把刚占用的名额还回去
      if (action === "activate" && data.instance?.id) {
        await fetch(`${base}/v1/licenses/deactivate`, {
          method: "POST",
          headers: { "x-api-key": env.CREEM_API_KEY, "content-type": "application/json" },
          body: JSON.stringify({ key, instance_id: data.instance.id }),
        }).catch(() => {});
      }
      return json({ [flag]: false, error: "license_key not found." }, 404);
    }

    // 回答里没有授权状态：看不懂，按暂时性处理。
    if (typeof data?.status !== "string") return transient("upstream unavailable", 502);
    const instanceActive = !data.instance || data.instance.status !== "deactivated";
    const statusOK = data.status === "active" || data.status === "inactive";
    let ok = true;
    if (action === "validate") ok = statusOK && instanceActive;
    if (action === "activate") ok = statusOK && !!data.instance?.id;
    return json({
      [flag]: ok,
      error: ok ? undefined : (data.status === "expired" ? "license expired" : data.status === "disabled" ? "license disabled" : "instance not found."),
      instance: data.instance ? { id: data.instance.id } : undefined,
      license_key: { status: data.status },
      meta: { product_id: data.product_id },
    });
  },
};
