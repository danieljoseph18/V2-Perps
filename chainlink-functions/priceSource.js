// Convert to milliseconds
const timestamp = new Date(Number(args[0]) * 1000).toISOString();
const tickers = args.slice(1).join(",");

// Ensure the API key is set
if (secrets.apiKey === "") {
  throw new Error(
    "COINMARKETCAP_API_KEY environment variable not set for CoinMarketCap API.  Get a free key from https://coinmarketcap.com/api/"
  );
}

const cmcRequest = Functions.makeHttpRequest({
  url: `https://pro-api.coinmarketcap.com/v2/cryptocurrency/ohlcv/historical?symbol=${tickers}&time_start=${timestamp}&time_end=${timestamp+1}`,
  headers: { "X-CMC_PRO_API_KEY": secrets.apiKey },
});

const cmcResponse = await cmcRequest;
if (cmcResponse.error) {
    throw Error("Request Failed");
}

const data = cmcResponse.data.data;

console.log("Data: ", data);

// Function to get the asset with the highest market cap
// Multiple fake assets can be returned for the same ticker. This gets the real one.
const getHighestMarketCapAsset = (assets) => {
  return assets.reduce((max, asset) => {
    return (max.quote.USD.market_cap > asset.quote.USD.market_cap) ? max : asset;
  });
};

// Function to aggregate quotes
const aggregateQuotes = (quotes) => {
  const totalQuotes = quotes.length;
  const aggregated = quotes.reduce((acc, quote) => {
    acc.open += quote.quote.USD.open;
    acc.high += quote.quote.USD.high;
    acc.low += quote.quote.USD.low;
    acc.close += quote.quote.USD.close;
    return acc;
  }, { open: 0, high: 0, low: 0, close: 0 });

  return {
    open: aggregated.open / totalQuotes,
    high: aggregated.high / totalQuotes,
    low: aggregated.low / totalQuotes,
    close: aggregated.close / totalQuotes,
  };
};

// Filter the data to get only the asset with the highest market cap for each ticker
const filteredData = Object.keys(data).reduce((acc, key) => {
  const assets = data[key];
  if (assets.length > 0) {
    const highestMarketCapAsset = getHighestMarketCapAsset(assets);
    highestMarketCapAsset.aggregatedQuotes = aggregateQuotes(highestMarketCapAsset.quotes);
    acc.push(highestMarketCapAsset);
  }
  return acc;
}, []);

// Encode response for each token
const encodedPrices = filteredData.reduce((acc, tokenData) => {
  const { symbol, aggregatedQuotes } = tokenData;
  const { open, high, low, close } = aggregatedQuotes;

  const ticker = Buffer.from(symbol.padEnd(15, "\0")).slice(0, 15);
  const precision = Buffer.alloc(1);
  precision.writeUInt8(2, 0); // Assuming 2 decimal places

  // Calculate variance as a percentage with 5 significant figures
  const varianceValue = ((high - low) / low) * 10000; // Variance as a percentage
  const variance = Buffer.alloc(2);
  variance.writeUInt16BE(varianceValue, 0);

  // Write timestamp as uint48 to the next 6 bytes
  const timestampMs = BigInt(args[0]) * 1000n;
  const timestampBuf = Buffer.alloc(6);
  const tempTimestampBuf = Buffer.alloc(8);
  tempTimestampBuf.writeBigUInt64BE(timestampMs, 0);
  tempTimestampBuf.copy(timestampBuf, 0, 2); // Copy only the last 6 bytes

  // Calculate and write median price
  const medianPriceValue = BigInt((open + close) / 2 * 10 ** precision.readUInt8(0));
  const medianPrice = Buffer.alloc(8);
  medianPrice.writeBigUInt64BE(medianPriceValue, 0);

  const encoded = Buffer.concat([ticker, precision, variance, timestampBuf, medianPrice]);
  acc.push(encoded);
  return acc;
}, []);

const result = Buffer.concat(encodedPrices);
return Functions.encodeBytes(result);