const timestampUnix = Number(args[0]);
const timeStart = timestampUnix - 1;
const timeEnd = timestampUnix;
const tickers = args.slice(1).join(",");

if (!secrets.apiKey) {
  throw new Error(
    "COINMARKETCAP_API_KEY environment variable not set for CoinMarketCap API. Get a free key from https://coinmarketcap.com/api/"
  );
}

const cmcRequest = Functions.makeHttpRequest({
  url: `https://pro-api.coinmarketcap.com/v2/cryptocurrency/ohlcv/historical?symbol=${tickers}&time_start=${timeStart}&time_end=${timeEnd}`,
  headers: { "X-CMC_PRO_API_KEY": secrets.apiKey },
  method: "GET",
});

const cmcResponse = await cmcRequest;

if (cmcResponse.error) {
  console.error("Request failed with status:", cmcResponse.status);
  console.error("Error details:", cmcResponse);
  throw new Error(`Request Failed with status ${cmcResponse.status}`);
}

const data = cmcResponse.data.data;

// Function to aggregate quotes
const aggregateQuotes = (quotes) => {
  const validQuotes = quotes.filter((quote) => quote.quote && quote.quote.USD);
  const totalQuotes = validQuotes.length;
  if (totalQuotes === 0) {
    return { open: 0, high: 0, low: 0, close: 0 };
  }

  const aggregated = validQuotes.reduce(
    (acc, quote) => {
      acc.open += quote.quote.USD.open;
      acc.high += quote.quote.USD.high;
      acc.low += quote.quote.USD.low;
      acc.close += quote.quote.USD.close;
      return acc;
    },
    { open: 0, high: 0, low: 0, close: 0 }
  );

  return {
    open: aggregated.open / totalQuotes,
    high: aggregated.high / totalQuotes,
    low: aggregated.low / totalQuotes,
    close: aggregated.close / totalQuotes,
  };
};

const filteredData = Object.keys(data).reduce((acc, key) => {
  const assets = data[key];
  if (assets.length > 0) {
    const highestMarketCapAsset = assets[0]; // Take the first asset
    highestMarketCapAsset.aggregatedQuotes = aggregateQuotes(
      highestMarketCapAsset.quotes
    );
    acc.push(highestMarketCapAsset);
  }
  return acc;
}, []);

const encodedPrices = filteredData.reduce((acc, tokenData) => {
  const { symbol, aggregatedQuotes } = tokenData;
  const { open, high, low, close } = aggregatedQuotes;

  // Encoding ticker to exactly 15 bytes with padding
  const tickerBuffer = Buffer.alloc(15);
  tickerBuffer.write(symbol);

  const ticker = new Uint8Array(tickerBuffer);

  const precision = new Uint8Array(1);
  precision[0] = 2; // Assuming 2 decimal places

  const varianceValue = Math.round(((high - low) / low) * 10000);
  const variance = new Uint8Array(2);
  new DataView(variance.buffer).setUint16(0, varianceValue);

  // Correct timestamp conversion to 6-byte array
  const timestampSeconds = BigInt(args[0]);
  const timestampBuf = new Uint8Array(6);
  for (let i = 0; i < 6; i++) {
    timestampBuf[5 - i] = Number(
      (timestampSeconds >> BigInt(i * 8)) & BigInt(0xff)
    );
  }

  // Correct median price calculation
  const medianPriceValue = BigInt(Math.round(((open + close) / 2) * 100)); // Ensure correct scaling
  const medianPrice = new Uint8Array(8);
  new DataView(medianPrice.buffer).setBigUint64(0, medianPriceValue);

  const encoded = new Uint8Array([
    ...ticker,
    ...precision,
    ...variance,
    ...timestampBuf,
    ...medianPrice,
  ]);

  acc.push(encoded);
  return acc;
}, []);

const result = encodedPrices.reduce((acc, bytes) => {
  const newBuffer = new Uint8Array(acc.length + bytes.length);
  newBuffer.set(acc);
  newBuffer.set(bytes, acc.length);
  return newBuffer;
}, new Uint8Array());

return Buffer.from(result, 'hex');
