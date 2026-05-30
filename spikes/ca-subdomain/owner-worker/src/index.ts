// SP-A throwaway spike Worker.
// Proves a single Worker on the wildcard route *.clubaid.co/* serves every club
// subdomain with no per-host setup. Echoes the request host + derived club label.
export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const host = request.headers.get('host') ?? url.host;
    const label = host.split('.')[0]; // would become the club/tenant id in the real owner app
    const body = {
      worker: 'clubaid-owner-spike',
      host,
      clubLabel: label,
      path: url.pathname,
      note: 'SP-A wildcard routing proof — this Worker was reached via *.clubaid.co/*',
    };
    return new Response(JSON.stringify(body, null, 2), {
      headers: { 'content-type': 'application/json; charset=utf-8' },
    });
  },
};
