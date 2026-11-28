// node fixture-samples.mjs <out dir>
//
// The data API's answers for the routes Fieldmart calls, computed with the
// vendored generator (shared/fixtures/data.mjs) exactly as the gateway
// computes them, written as files for FieldmartCore's decoding test
// (FM_SAMPLES=<out dir> swift test).
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import * as D from '../../shared/fixtures/data.mjs';

const out = process.argv[2];
if (!out) {
  console.error('usage: fixture-samples.mjs <out dir>');
  process.exit(2);
}
mkdirSync(out, { recursive: true });
const data = D.buildData();
const write = (name, value) => writeFileSync(join(out, `${name}.json`), JSON.stringify(value));
write('products-0', D.productPage(data, { page: 0, size: 40 }));
write('products-cat3-0', D.productPage(data, { page: 0, size: 40, category: 3 }));
write('product-17', { ...data.products[16], ...data.details[16] });
write('reviews-17-0', D.reviewPage(data, 17, { page: 0, size: 50 }));
write('reviews-17-9', D.reviewPage(data, 17, { page: 9, size: 50 }));
write('categories', data.categories);
write('deals', data.deals);
write('hero', data.hero);
write('feed-0', D.feedPage(data, { cursor: 0, size: 100 }));
write('feed-5000', D.feedPage(data, { cursor: 5000, size: 100 }));
write('feed-9900', D.feedPage(data, { cursor: 9900, size: 100 }));
write('symbols', data.symbols);
write('candles-0-1H', D.candles(data.symbols, 0, '1H', data.seed, data.candleEnd));
write('search-trail', D.search(data, 'trail'));
write('promos-FIELD1', D.promos(data, 'FIELD1'));
write('countries', data.countries);
write('terms', data.terms);
console.log(out);
