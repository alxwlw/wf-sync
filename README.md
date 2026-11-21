# wf-sync

A Bun service that syncs crypto exchanges (Binance, OKX, Kraken, WhiteBIT), EVM and Solana wallets and Monobank
into a self-hosted Wealthfolio, with plugins for any other source.

The service, its documentation and the deploy files live in [`apps/wf-sync`](apps/wf-sync/README.md).

## Development

```bash
pnpm install
pnpm exec moon run :lint :format :typecheck :test
pnpm exec stack check
```

## License

[MIT](LICENSE)
