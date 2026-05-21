// Acepta /messages, /v1/messages y /v1/v1/messages — rewrites a /v1/messages
const UPSTREAM = 'http://localhost:4000';
const PORT = 4001;

function rewritePath(p: string): string {
  if (p === '/messages' || p === '/v1/v1/messages') return '/v1/messages';
  if (p === '/messages/count_tokens' || p === '/v1/v1/messages/count_tokens') return '/v1/messages/count_tokens';
  return p;
}

Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    const target = `${UPSTREAM}${rewritePath(url.pathname)}${url.search}`;
    const r = await fetch(target, {
      method: req.method,
      headers: req.headers,
      body: req.body,
      // @ts-ignore
      duplex: 'half',
    });
    return new Response(r.body, { status: r.status, headers: r.headers });
  },
});
console.log(`anthropic-shim listening on :${PORT} → ${UPSTREAM}`);
