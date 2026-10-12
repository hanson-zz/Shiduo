// 拾掇 Pro 授权中转（Cloudflare Worker）
// App 不能内置 Creem 的 API 密钥（代码是公开的），所以由这个小服务代为调用 Creem。
// 只转发三件事：激活、校验、解绑；并且只认拾掇 Pro 这个产品的授权码。
//
// 需要在 Cloudflare 里设置：
//   CREEM_API_KEY  （Secret）Creem 后台 ▸ Developers ▸ API Keys
//   PRODUCT_ID     （变量）Creem 里拾掇 Pro 产品的 ID，形如 prod_xxx；多个用英文逗号隔开
//   CREEM_API      （变量，可选）测试时填 https://test-api.creem.io
//
// 返回给 App 的格式（与 App 里 LicenseAPI.parse 对应）：
//   { activated|valid|deactivated: Bool, error?: String,
//     instance: { id }, license_key: { status }, meta: { product_id } }

const ACTIONS = { activate: "activated", validate: "valid", deactivate: "deactivated" };

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/v1\/licenses\/(activate|validate|deactivate)$/);
    if (request.method === "GET" && url.pathname === "/") return json({ ok: true, service: "shiduo-license" });
    if (!match || request.method !== "POST") return json({ error: "not found" }, 404);
    const action = match[1];
    const flag = ACTIONS[action];

    let input;
    try { input = await request.json(); } catch { return json({ [flag]: false, error: "invalid request" }, 400); }
    const key = String(input.key || "").trim();
    if (!key || key.length > 200) return json({ [flag]: false, error: "license_key not found." }, 404);

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
      return json({ error: "upstream unavailable" }, 502);
    }

    if (!res.ok) {
      const msg = Array.isArray(data?.message) ? data.message.join(" ") : (data?.message || data?.error || "");
      const low = String(msg).toLowerCase();
      let error = "license error";
      if (res.status === 404 || low.includes("not found")) error = action === "activate" ? "license_key not found." : "instance not found.";
      else if (low.includes("limit")) error = "activation limit reached";
      else if (low.includes("expired")) error = "license expired";
      else if (low.includes("disabled")) error = "license disabled";
      else if (res.status === 429) error = "too many requests";
      else if (res.status === 401 || res.status === 403) return json({ error: "server misconfigured" }, 502);
      // 校验时授权已失效：告诉 App 明确不可用
      return json({ [flag]: false, error }, res.status === 429 ? 429 : 400);
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
