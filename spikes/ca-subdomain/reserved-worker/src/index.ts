// SP-A "reserved host" Worker.
// Bound to MORE-SPECIFIC routes (admin.clubaid.co/*, www.clubaid.co/*) so it wins
// over the wildcard owner route *.clubaid.co/* (Cloudflare routes by specificity).
// This proves the deterministic Option-A precedence mechanism and keeps the live
// staff console working while the wildcard owner Worker serves club subdomains.
//
//   admin.clubaid.co → transparent proxy to the admin Pages deployment (clubaid.pages.dev)
//   www.clubaid.co   → 301 redirect to the apex marketing site (clubaid.co)
//
// In production (SP-B) admin/www become their own Worker deployments on these same
// specific routes; this throwaway proves the routing + keeps admin up in the meantime.
const ADMIN_ORIGIN = 'https://clubaid.pages.dev';
const APEX = 'https://clubaid.co';

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const host = request.headers.get('host') ?? url.host;

    if (host === 'www.clubaid.co') {
      return Response.redirect(APEX + url.pathname + url.search, 301);
    }

    if (host === 'admin.clubaid.co') {
      // Transparent reverse proxy to the admin Pages origin, preserving everything.
      const upstream = new URL(url.pathname + url.search, ADMIN_ORIGIN);
      const proxied = new Request(upstream.toString(), request);
      proxied.headers.set('host', 'clubaid.pages.dev');
      return fetch(proxied, { redirect: 'manual' });
    }

    return new Response('reserved host: no handler\n', { status: 404 });
  },
};
