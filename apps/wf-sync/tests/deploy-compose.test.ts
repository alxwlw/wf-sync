import { readFileSync } from 'node:fs';

import { describe, expect, test } from 'bun:test';
import { parse } from 'yaml';

const compose = parse(
	readFileSync(new URL('../deploy/docker-compose.dokploy.yml', import.meta.url), 'utf8'),
);

describe('deploy/docker-compose.dokploy.yml', () => {
	test('no service publishes a port on the host', () => {
		for (const s of Object.values<any>(compose.services)) expect(s.ports).toBeUndefined();
	});

	test('the tailscale sidecar is the tag:apps node "wealthfolio"', () => {
		const ts = compose.services.tailscale;
		expect(ts.image).toMatch(/^tailscale\/tailscale:v[\d.]+@sha256:[0-9a-f]{64}$/);
		expect(ts.environment).toMatchObject({
			TS_HOSTNAME: 'wealthfolio',
			TS_EXTRA_ARGS: '--advertise-tags=tag:apps',
			TS_AUTH_ONCE: 'true',
			TS_USERSPACE: 'true',
			TS_STATE_DIR: '/var/lib/tailscale',
			TS_SERVE_CONFIG: '/config/serve.json',
		});
		expect(ts.environment.TS_AUTHKEY).toStartWith('${TS_AUTHKEY:?');
		expect(ts.cap_drop).toEqual(['ALL']);
		expect(ts.security_opt).toEqual(['no-new-privileges:true']);
		expect(ts.volumes).toContain('tailscale:/var/lib/tailscale');
		expect(Object.keys(compose.volumes)).toEqual(['wealthfolio-data', 'wf-sync-data', 'tailscale']);
	});

	test('serve proxies 443 to wealthfolio:8088, tailnet only', () => {
		const raw: string = compose.configs['ts-serve'].content;
		expect(raw).toContain('$${TS_CERT_DOMAIN}');
		const serve = JSON.parse(raw.replaceAll('$$', '$'));
		expect(serve.TCP).toEqual({ '443': { HTTPS: true } });
		expect(serve.Web).toEqual({
			'${TS_CERT_DOMAIN}:443': { Handlers: { '/': { Proxy: 'http://wealthfolio:8088' } } },
		});
		expect(serve.AllowFunnel).toBeUndefined();
	});
});
