// The arithmetic that decides whether a keeper job is worth making.
//
// Everything here is pure, and that is the point rather than a stylistic
// preference. The jobs themselves are modules that build RPC clients, read the
// environment and start a loop the moment they are imported, so nothing inside
// them can be exercised without a chain in front of it. Split out, the numbers
// that decide whether money moves can be checked directly.
//
// What lives here are the worth-it floors, which have to compare a payout
// denominated in one currency against a gas cost denominated in another.


/// USD value of a raw token amount.
///
/// Scaled by the token's OWN decimals. On the stock cell the quote is an
/// arbitrary third-party token, so a fixed 1e18 here is wrong by however many
/// orders of magnitude the quote differs by — and wrong in a direction that
/// silently retires the token rather than failing loudly, because an
/// understated payout simply never clears a floor.
export function rawToUsd(amount: bigint, decimals: number, priceUsd: number): number {
  return (Number(amount) / 10 ** decimals) * priceUsd;
}

/// USD → raw units of a token, the inverse of `rawToUsd`. Rounds UP, because
/// every caller uses it to build a floor and a floor that rounds down is a floor
/// that occasionally is not one.
export function usdToRaw(usd: number, decimals: number, priceUsd: number): bigint {
  return BigInt(Math.ceil((usd / priceUsd) * 10 ** decimals));
}

/// ETH wei → raw quote units, routed through USD.
///
/// Needed because gas is paid in ether while a stock-cell payout arrives in a
/// stock token, so the two sides of "is this worth doing" are denominated
/// differently and there is no on-chain pair between them to ask.
export function ethWeiToQuoteRaw(ethWei: bigint, ethUsd: number, quoteUsd: number, quoteDecimals: number): bigint {
  return usdToRaw(rawToUsd(ethWei, 18, ethUsd), quoteDecimals, quoteUsd);
}

/// Raw quote units → ETH wei, the inverse. Rounds DOWN, so a payout is never
/// overstated when compared against a cost.
export function quoteRawToEthWei(raw: bigint, ethUsd: number, quoteUsd: number, quoteDecimals: number): bigint {
  const usd = rawToUsd(raw, quoteDecimals, quoteUsd);
  return BigInt(Math.floor((usd / ethUsd) * 1e18));
}
