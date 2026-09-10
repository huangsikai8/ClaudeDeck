const fs = require("fs");

// Transcripts are JSONL and usually a few MB. Read the whole file rather than
// a tail: the stage boundary this is looking for is the last real user prompt,
// and a tail that starts after it would see background-task launches with no
// prompt to retire them. Only absurdly large files fall back to a tail.
const MAX_WHOLE_FILE = 16 * 1024 * 1024;
const TAIL_BYTES = 4 * 1024 * 1024;

function readText(filePath) {
  let fd;
  try {
    fd = fs.openSync(filePath, "r");
    const size = fs.fstatSync(fd).size;
    if (size <= MAX_WHOLE_FILE) return fs.readFileSync(fd, "utf-8");
    const start = size - TAIL_BYTES;
    const buf = Buffer.allocUnsafe(TAIL_BYTES);
    fs.readSync(fd, buf, 0, TAIL_BYTES, start);
    const text = buf.toString("utf-8");
    return text.slice(text.indexOf("\n") + 1); // drop the partial first line
  } catch {
    return null;
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {}
    }
  }
}

/** Parsed records, or null when the transcript can't be read. */
function readRecords(filePath) {
  if (!filePath) return null;
  const text = readText(filePath);
  if (text == null) return null;
  const out = [];
  for (const line of text.split("\n")) {
    if (!line) continue;
    try {
      out.push(JSON.parse(line));
    } catch {}
  }
  return out;
}

module.exports = { readRecords };
