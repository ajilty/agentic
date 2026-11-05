// Minimal YAML subset loader — enough for Seam profiles, zero dependencies.
// Supports: block maps, block lists (scalars or maps), inline arrays, quoted
// strings, numbers, booleans, comments. Anything fancier is a profile bug.

function parseScalar(raw) {
  const s = raw.trim();
  if (s === '' || s === '~' || s === 'null') return null;
  if (s === 'true') return true;
  if (s === 'false') return false;
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  if (s.startsWith('[')) {
    const inner = s.slice(1, s.indexOf(']'));
    return inner.trim() === '' ? [] : inner.split(',').map((x) => parseScalar(x));
  }
  if (/^-?\d+$/.test(s)) return parseInt(s, 10);
  if (/^-?\d+\.\d+$/.test(s)) return parseFloat(s);
  return s;
}

function stripComment(line) {
  // Remove trailing comments outside quotes.
  let inS = false; let inD = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === "'" && !inD) inS = !inS;
    else if (c === '"' && !inS) inD = !inD;
    else if (c === '#' && !inS && !inD) return line.slice(0, i);
  }
  return line;
}

export function parseYaml(text) {
  const lines = [];
  for (const rawLine of text.split('\n')) {
    const line = stripComment(rawLine).replace(/\s+$/, '');
    if (line.trim() === '') continue;
    const indent = line.match(/^ */)[0].length;
    lines.push({ indent, text: line.trim() });
  }
  let pos = 0;

  function parseBlock(indent) {
    if (pos >= lines.length) return null;
    if (lines[pos].text.startsWith('- ') || lines[pos].text === '-') return parseList(indent);
    return parseMap(indent);
  }

  function parseMap(indent) {
    const obj = {};
    while (pos < lines.length && lines[pos].indent === indent && !lines[pos].text.startsWith('- ')) {
      const { text } = lines[pos];
      const ci = text.indexOf(':');
      if (ci < 0) throw new Error(`yaml: expected key: value, got "${text}"`);
      const key = text.slice(0, ci).trim();
      const rest = text.slice(ci + 1).trim();
      pos++;
      if (rest !== '') {
        obj[key] = parseScalar(rest);
      } else if (pos < lines.length && lines[pos].indent > indent) {
        obj[key] = parseBlock(lines[pos].indent);
      } else {
        obj[key] = null;
      }
    }
    return obj;
  }

  function parseList(indent) {
    const arr = [];
    while (pos < lines.length && lines[pos].indent === indent && lines[pos].text.startsWith('-')) {
      const rest = lines[pos].text.replace(/^-\s*/, '');
      if (rest === '') {
        pos++;
        arr.push(pos < lines.length && lines[pos].indent > indent ? parseBlock(lines[pos].indent) : null);
      } else if (rest.includes(':')) {
        // Inline first pair of a map item: "- surface: email". Re-enter map
        // parsing at the effective indent of the first key.
        const itemIndent = lines[pos].indent + (lines[pos].text.length - rest.length);
        lines[pos] = { indent: itemIndent, text: rest };
        arr.push(parseMap(itemIndent));
      } else {
        arr.push(parseScalar(rest));
        pos++;
      }
    }
    return arr;
  }

  return parseBlock(lines.length ? lines[0].indent : 0) ?? {};
}
