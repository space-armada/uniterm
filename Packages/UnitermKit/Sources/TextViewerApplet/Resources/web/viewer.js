// The Markdown viewer's page logic. It runs only as a user script in its own content world, after
// markdown-it and DOMPurify. The page's own world runs no script, so nothing in a document can
// reach anything here.
//
// The document's text arrives by fetch from the scheme handler. Markdown parses here, in WebKit's
// content process, and never in uniterm's. Every block of output is sanitized before it is
// inserted. The line map that scroll anchors use is kept in this file's state, keyed by element
// identity. Nothing reads a DOM attribute to learn a source line, so markup in a document cannot
// forge one.
(function () {
  'use strict';

  const markdownit = window.markdownit;
  const purify = window.DOMPurify;

  const DOCUMENT_URL = 'uniterm-markdown://app/document';
  const IMAGE_URL = 'uniterm-markdown://app/image?p=';
  const MAX_HEADINGS = 5000;
  const MAX_HEADING_TEXT = 200;
  const SLICE_MILLISECONDS = 30;
  const MAX_SLICE_MILLISECONDS = 2000;
  const BATCH_GROUPS = 128;
  const BATCH_TOKENS = 2048;
  const MAX_UNIT_GROUPS = 400;
  const VOID_ELEMENTS = new Set([
    'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr',
  ]);

  function post(message) {
    window.webkit.messageHandlers.uniterm.postMessage(message);
  }

  // GitHub's README sanitization allowlist, as html-pipeline publishes it. web-assets.pin names the
  // source. Left out: longdesc on img, since it names a resource the viewer never fetches.
  const ELEMENTS = [
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'br', 'b', 'i', 'strong', 'em', 'a', 'pre', 'code', 'img',
    'tt', 'div', 'ins', 'del', 'sup', 'sub', 'p', 'picture', 'ol', 'ul', 'table', 'thead', 'tbody',
    'tfoot', 'blockquote', 'dl', 'dt', 'dd', 'kbd', 'q', 'samp', 'var', 'hr', 'ruby', 'rt', 'rp',
    'li', 'tr', 'td', 'th', 's', 'strike', 'summary', 'details', 'caption', 'figure', 'figcaption',
    'abbr', 'bdo', 'cite', 'dfn', 'mark', 'small', 'source', 'span', 'time', 'wbr',
  ];

  const ELEMENT_ATTRIBUTES = {
    a: ['href'],
    img: ['src', 'loading', 'alt'],
    div: ['itemscope', 'itemtype'],
    blockquote: ['cite'],
    del: ['cite'],
    ins: ['cite'],
    q: ['cite'],
    source: ['srcset'],
  };

  // The attributes the allowlist permits on every element. The form attributes among them do
  // nothing, since no form element is allowed.
  const GLOBAL_ATTRIBUTES = new Set([
    'abbr', 'accept', 'accept-charset', 'accesskey', 'action', 'align', 'alt', 'aria-describedby',
    'aria-hidden', 'aria-label', 'aria-labelledby', 'axis', 'border', 'char', 'charoff', 'charset',
    'checked', 'clear', 'cols', 'colspan', 'compact', 'coords', 'datetime', 'dir', 'disabled',
    'enctype', 'for', 'frame', 'headers', 'height', 'hreflang', 'hspace', 'id', 'ismap', 'label',
    'lang', 'maxlength', 'media', 'method', 'multiple', 'name', 'nohref', 'noshade', 'nowrap',
    'open', 'progress', 'prompt', 'readonly', 'rel', 'rev', 'role', 'rows', 'rowspan', 'rules',
    'scope', 'selected', 'shape', 'size', 'span', 'start', 'summary', 'tabindex', 'title', 'type',
    'usemap', 'valign', 'value', 'width', 'itemprop',
  ]);

  const SCOPED_ATTRIBUTES = new Map();

  for (const [tag, names] of Object.entries(ELEMENT_ATTRIBUTES)) {
    for (const name of names) {
      if (!SCOPED_ATTRIBUTES.has(name)) SCOPED_ATTRIBUTES.set(name, new Set());

      SCOPED_ATTRIBUTES.get(name).add(tag);
    }
  }

  const SANITIZER_CONFIG = {
    ALLOWED_TAGS: ELEMENTS,
    ALLOWED_ATTR: Array.from(new Set([...GLOBAL_ATTRIBUTES, ...SCOPED_ATTRIBUTES.keys()])),
    ALLOW_ARIA_ATTR: false,
    ALLOW_DATA_ATTR: false,
    ALLOW_UNKNOWN_PROTOCOLS: false,
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto):|[^a-z]|[a-z+.-]+(?:[^a-z+.:-]|$))/i,
    RETURN_DOM_FRAGMENT: true,
  };

  purify.addHook('uponSanitizeAttribute', function (node, data) {
    const name = data.attrName;

    if (GLOBAL_ATTRIBUTES.has(name)) return;

    const tags = SCOPED_ATTRIBUTES.get(name);

    if (!tags || !tags.has(node.nodeName.toLowerCase())) data.keepAttr = false;
  });

  // A plain relative path becomes a request the scheme handler serves from the document's folder.
  // The path stays whole in one encoded query value, so a `..` reaches the handler intact. Anything
  // else, such as a root-relative path, a `file:` URL, or a remote URL, has no image to show.
  function imageURL(reference) {
    const trimmed = reference.trim();

    if (trimmed === '' || /^[a-z][a-z0-9+.-]*:/i.test(trimmed) || /^[/\\]/.test(trimmed)) return null;

    if (/[\u0000-\u001f]/.test(trimmed)) return null;

    let path = trimmed.split(/[?#]/)[0];

    if (path === '') return null;

    try {
      path = decodeURIComponent(path);
    } catch (error) {
      return null;
    }

    if (/^[/\\]/.test(path)) return null;

    return IMAGE_URL + encodeURIComponent(path);
  }

  function rewriteSourceSet(value) {
    const candidates = [];
    let rest = value;

    while (rest.length > 0) {
      rest = rest.replace(/^[\s,]+/, '');

      if (rest === '') break;

      const match = /^\S+/.exec(rest);
      let url = match[0];

      rest = rest.slice(url.length);

      let descriptor = '';

      if (!/,$/.test(url)) {
        const end = rest.indexOf(',');

        descriptor = (end === -1 ? rest : rest.slice(0, end)).trim();
        rest = end === -1 ? '' : rest.slice(end + 1);
      } else {
        url = url.replace(/,+$/, '');
      }

      const rewritten = imageURL(url);

      if (rewritten) candidates.push(descriptor === '' ? rewritten : rewritten + ' ' + descriptor);
    }

    return candidates.join(', ');
  }

  function rewriteImages(fragment) {
    for (const image of fragment.querySelectorAll('img[src]')) {
      const rewritten = imageURL(image.getAttribute('src'));

      if (rewritten) {
        image.setAttribute('src', rewritten);
      } else {
        image.removeAttribute('src');
      }
    }

    for (const source of fragment.querySelectorAll('[srcset]')) {
      const rewritten = source.localName === 'source' ? rewriteSourceSet(source.getAttribute('srcset')) : '';

      if (rewritten === '') {
        source.removeAttribute('srcset');
      } else {
        source.setAttribute('srcset', rewritten);
      }
    }
  }

  function sanitizeMarkup(html) {
    const fragment = purify.sanitize(html, SANITIZER_CONFIG);

    rewriteImages(fragment);

    return fragment;
  }

  // Every insertion goes through api.sanitize. A debug build replaces that one member to prove the
  // policy holds without the sanitizer. Release builds never do.
  const api = { sanitize: sanitizeMarkup };

  const md = markdownit({ html: true, linkify: true, typographer: false });

  // Column alignment arrives as an inline style, which the sanitizer drops. The align attribute
  // is on the allowlist and does the same job.
  md.core.ruler.push('uniterm_align', function (state) {
    for (const token of state.tokens) {
      if ((token.type === 'th_open' || token.type === 'td_open') && token.attrs) {
        token.attrs = token.attrs.map(function (pair) {
          const match = pair[0] === 'style' && /^text-align:(left|center|right)$/.exec(pair[1]);

          return match ? ['align', match[1]] : pair;
        });
      }
    }
  });

  const state = {
    root: null,
    blocks: [],
    headings: [],
    headingNodes: [],
    headingsCut: false,
    usedIDs: new Set(),
    find: null,
    rendered: false,
    lastAnchor: null,
    token: null,
    generation: 0,
  };

  function slug(text) {
    return text
      .trim()
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\p{M}\- _]/gu, '')
      .replace(/ /g, '-');
  }

  function claimID(text) {
    const base = slug(text) || 'section';
    let candidate = base;
    let count = 0;

    while (state.usedIDs.has(candidate)) {
      count += 1;
      candidate = base + '-' + count;
    }

    state.usedIDs.add(candidate);

    return candidate;
  }

  function collectHeadings(elements, line) {
    for (const element of elements) {
      const found = /^H[1-6]$/.test(element.tagName) ? [element] : [];

      if (element.querySelectorAll) found.push(...element.querySelectorAll('h1,h2,h3,h4,h5,h6'));

      for (const heading of found) {
        const text = heading.textContent.trim();
        let id = heading.getAttribute('id');

        if (id) {
          state.usedIDs.add(id);
        } else {
          id = claimID(text);
          heading.setAttribute('id', id);
        }

        if (state.headings.length < MAX_HEADINGS) {
          state.headingNodes.push(heading);
          state.headings.push({
            level: Number(heading.tagName.slice(1)),
            text: text.slice(0, MAX_HEADING_TEXT),
            id: id,
            line: line,
          });
        } else {
          state.headingsCut = true;
        }
      }
    }
  }

  // Splits the token stream into top-level blocks. A block is an open token, everything to its
  // matching close at level 0, or a single token that stands alone.
  function groupTokens(tokens) {
    const groups = [];
    let index = 0;

    while (index < tokens.length) {
      const first = tokens[index];
      let last = index;

      if (first.nesting === 1) {
        while (last < tokens.length - 1 && !(tokens[last].level === 0 && tokens[last].nesting === -1)) {
          last += 1;
        }
      }

      groups.push({
        tokens: tokens.slice(index, last + 1),
        line: first.map ? first.map[0] : 0,
        hasHTML: false,
      });

      index = last + 1;
    }

    for (const group of groups) {
      group.hasHTML = group.tokens.some(function (token) {
        return (
          token.type === 'html_block' ||
          (token.type === 'inline' && token.children && token.children.some(function (child) {
            return child.type === 'html_inline';
          }))
        );
      });
    }

    return groups;
  }

  function renderGroup(group, env) {
    return md.renderer.render(group.tokens, md.options, env);
  }

  function place(fragment, group) {
    const elements = Array.from(fragment.children);

    if (elements.length === 0) return;

    collectHeadings(elements, group.line);
    state.blocks.push({ first: elements[0], last: elements[elements.length - 1], line: group.line });
    state.root.appendChild(fragment);
  }

  function placeHTML(html, group) {
    place(api.sanitize(html), group);
  }

  function placeAlone(group, env) {
    placeHTML(renderGroup(group, env), group);
  }

  // How many elements `html` opens and does not close. It reads the rendered markup, so code and
  // text are already escaped. A wrong count only changes how blocks are grouped, never what is
  // sanitized, since every unit goes through the sanitizer whole.
  function openDepth(html) {
    let depth = 0;

    for (const match of html.replace(/<!--[\s\S]*?-->/g, '').matchAll(/<(\/?)([a-zA-Z][a-zA-Z0-9-]*)[^>]*?(\/?)>/g)) {
      const name = match[2].toLowerCase();

      if (match[3] === '/' || VOID_ELEMENTS.has(name)) continue;

      depth += match[1] === '/' ? -1 : 1;
    }

    return depth;
  }

  // Raw HTML can open an element in one block and close it in a later one, as `<details>` does around
  // Markdown. Sanitizing the blocks apart would close the element early and strand its body outside.
  // A block that leaves an element open starts a unit, and the unit takes the following blocks until
  // the element is closed. A unit is one block for scroll anchors.
  function placeUnit(unit) {
    placeHTML(unit.parts.join('\n'), unit.groups[0]);
  }

  // Blocks that carry no raw HTML are the parser's own markup. Sanitizing them together costs one
  // call for many blocks. Each block yields exactly one element, which the count confirms. When
  // the count is off, each block is sanitized alone instead.
  function placeBatch(batch, env) {
    if (batch.length === 0) return;

    const fragment = api.sanitize(batch.map(function (group) { return renderGroup(group, env); }).join('\n'));

    if (fragment.children.length !== batch.length) {
      for (const group of batch) placeAlone(group, env);
      return;
    }

    const elements = Array.from(fragment.children);

    batch.forEach(function (group, position) {
      collectHeadings([elements[position]], group.line);
      state.blocks.push({ first: elements[position], last: elements[position], line: group.line });
    });

    state.root.appendChild(fragment);
  }

  function yieldToPage() {
    return new Promise(function (resolve) { setTimeout(resolve, 0); });
  }

  function currentAnchor() {
    const blocks = state.blocks;

    if (blocks.length === 0) return null;

    let low = 0;
    let high = blocks.length - 1;
    let found = 0;

    while (low <= high) {
      const middle = (low + high) >> 1;

      if (blocks[middle].first.getBoundingClientRect().top <= 1) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }

    const block = blocks[found];
    const top = block.first.getBoundingClientRect().top;
    const height = block.last.getBoundingClientRect().bottom - top;
    const fraction = height > 0 ? Math.min(1, Math.max(0, -top / height)) : 0;

    return { line: block.line, fraction: fraction };
  }

  function scrollToAnchor(anchor) {
    const blocks = state.blocks;

    if (blocks.length === 0 || !anchor) return false;

    let low = 0;
    let high = blocks.length - 1;
    let found = -1;

    while (low <= high) {
      const middle = (low + high) >> 1;

      if (blocks[middle].line <= anchor.line) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }

    if (found === -1) found = 0;

    const block = blocks[found];
    const top = block.first.getBoundingClientRect().top;
    const height = block.last.getBoundingClientRect().bottom - top;

    window.scrollTo(0, window.scrollY + top + height * Math.min(1, Math.max(0, anchor.fraction || 0)));

    return true;
  }

  function pushAnchor() {
    if (!state.rendered) return;

    const anchor = currentAnchor();

    if (!anchor) return;

    const last = state.lastAnchor;

    if (last && last.line === anchor.line && Math.abs(last.fraction - anchor.fraction) < 0.0005) return;

    state.lastAnchor = anchor;
    post({ kind: 'anchor', generation: state.token, line: anchor.line, fraction: anchor.fraction });
  }

  function applyTheme(theme) {
    const style = document.documentElement.style;

    for (const [name, value] of Object.entries(theme.variables || {})) style.setProperty(name, String(value));

    style.setProperty('color-scheme', theme.dark ? 'dark' : 'light');
  }

  // Find. The rule matches the host's other engines: Foundation's case- and diacritic-insensitive
  // comparison. Text is decomposed, combining marks are dropped, and the rest is case folded. The
  // folds JavaScript's lowercasing lacks are the ones Foundation applies: sharp s, final sigma,
  // long s, and the Latin ligatures. The query reaches this code as a call argument, never as
  // source text.
  const MAX_MATCHES = 10000;
  const MAX_QUERY = 500;
  const ASCII = /^[\u0000-\u007f]*$/;
  const MARKS = /\p{M}/gu;
  const FOLDS = {
    'ß': 'ss', 'ς': 'σ', 'ſ': 's', 'ﬀ': 'ff', 'ﬁ': 'fi', 'ﬂ': 'fl',
    'ﬃ': 'ffi', 'ﬄ': 'ffl', 'ﬅ': 'st', 'ﬆ': 'st',
  };
  const FOLD_CHARS = /[ßςſﬀ-ﬆ]/g;
  const INLINE = new Set([
    'a', 'abbr', 'b', 'bdo', 'cite', 'code', 'del', 'dfn', 'em', 'i', 'ins', 'kbd', 'mark', 'q',
    'rp', 'rt', 'ruby', 's', 'samp', 'small', 'span', 'strike', 'strong', 'sub', 'sup', 'time', 'tt',
    'u', 'var', 'wbr',
  ]);

  // Folds `text`. When the fold keeps every position, only the folded text comes back. Otherwise
  // `starts` and `ends` map each folded unit to the span of the original text that made it.
  function foldText(text, collapseBreaks) {
    if (ASCII.test(text)) {
      const folded = text.toLowerCase();

      return { text: collapseBreaks ? folded.replace(/\n/g, ' ') : folded, starts: null, ends: null };
    }

    let out = '';
    const starts = [];
    const ends = [];
    let position = 0;

    for (const character of text) {
      const width = character.length;
      let folded = character.normalize('NFD').replace(MARKS, '').toLowerCase().replace(FOLD_CHARS, function (c) {
        return FOLDS[c];
      });

      if (collapseBreaks && folded === '\n') folded = ' ';

      for (let unit = 0; unit < folded.length; unit += 1) {
        starts.push(position);
        ends.push(position + width);
      }

      out += folded;
      position += width;
    }

    return { text: out, starts: starts, ends: ends };
  }

  function blockOf(node, cache) {
    let element = node.parentElement;
    const first = element;

    while (element && INLINE.has(element.localName)) element = element.parentElement;

    cache.set(first, element);

    return element;
  }

  function clearFind() {
    const find = state.find;

    state.find = null;

    if (!find) return;

    const parents = new Set();

    for (const mark of find.marks) {
      const parent = mark.parentNode;

      if (!parent) continue;

      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);

      parent.removeChild(mark);
      parents.add(parent);
    }

    for (const parent of parents) parent.normalize();
  }

  function entryAt(entries, offset) {
    let low = 0;
    let high = entries.length - 1;

    while (low < high) {
      const middle = (low + high + 1) >> 1;

      if (entries[middle].start <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }

    return low;
  }

  // A hit counts only when it starts and ends between source characters. Foundation does not match
  // part of a character that folds to several, such as an s inside a sharp s or an f inside a
  // ligature, so neither does the page.
  function onBoundaries(entries, start, end) {
    const first = entries[entryAt(entries, start)];

    if (first.starts) {
      const index = start - first.start;

      if (index > 0 && first.starts[index - 1] === first.starts[index]) return false;
    }

    const last = entries[entryAt(entries, end - 1)];

    if (last.starts) {
      const index = end - 1 - last.start;

      if (index + 1 < last.starts.length && last.starts[index + 1] === last.starts[index]) return false;
    }

    return true;
  }

  // Searches the rendered text. A match may span inline elements, and never spans two blocks. A
  // match inside a closed details element counts. It is revealed when it becomes the current match.
  function find(query) {
    clearFind();

    const wanted = foldText(String(query).slice(0, MAX_QUERY), false).text.replace(/\u0000/g, '');

    if (wanted === '' || !state.root) return { count: 0, capped: false };

    const entries = [];
    const parts = [];
    const cache = new Map();
    const walker = document.createTreeWalker(state.root, NodeFilter.SHOW_TEXT);
    let total = 0;
    let previousBlock;

    while (walker.nextNode()) {
      const node = walker.currentNode;
      const value = node.nodeValue;

      if (!value) continue;

      const block = cache.has(node.parentElement) ? cache.get(node.parentElement) : blockOf(node, cache);

      if (previousBlock !== undefined && block !== previousBlock) {
        entries.push({ node: null, start: total, length: 1 });
        parts.push('\u0000');
        total += 1;
      }

      previousBlock = block;

      const inPre = block && block.localName === 'pre';
      const folded = foldText(value, !inPre);

      entries.push({ node: node, start: total, length: folded.text.length, starts: folded.starts, ends: folded.ends });
      parts.push(folded.text);
      total += folded.text.length;
    }

    const flat = parts.join('');
    const hits = [];
    let capped = false;

    for (let at = flat.indexOf(wanted); at !== -1; ) {
      if (!onBoundaries(entries, at, at + wanted.length)) {
        at = flat.indexOf(wanted, at + 1);
        continue;
      }

      if (hits.length >= MAX_MATCHES) {
        capped = true;
        break;
      }

      hits.push(at);
      at = flat.indexOf(wanted, at + wanted.length);
    }

    const matches = [];
    const byNode = new Map();

    hits.forEach(function (hit, index) {
      const end = hit + wanted.length;

      matches.push([]);

      for (let at = entryAt(entries, hit); at < entries.length && entries[at].start < end; at += 1) {
        const entry = entries[at];

        if (!entry.node) continue;

        const from = Math.max(hit, entry.start) - entry.start;
        const to = Math.min(end, entry.start + entry.length) - entry.start;

        if (to <= from) continue;

        const first = entry.starts ? entry.starts[from] : from;
        const last = entry.ends ? entry.ends[to - 1] : to;

        if (!byNode.has(entry.node)) byNode.set(entry.node, []);

        byNode.get(entry.node).push({ start: first, end: last, match: index });
      }
    });

    const marks = [];

    for (const [node, segments] of byNode) {
      segments.sort(function (a, b) { return b.start - a.start; });

      for (const segment of segments) {
        const middle = segment.start > 0 ? node.splitText(segment.start) : node;

        if (segment.end - segment.start < middle.length) middle.splitText(segment.end - segment.start);

        const mark = document.createElement('mark');

        mark.className = 'um-find';
        middle.parentNode.insertBefore(mark, middle);
        mark.appendChild(middle);
        marks.push(mark);
        matches[segment.match].push(mark);
      }
    }

    state.find = { marks: marks, matches: matches, current: -1 };

    return { count: matches.length, capped: capped };
  }

  function selectMatch(index) {
    const find = state.find;

    if (!find) return false;

    if (find.current >= 0) {
      for (const mark of find.matches[find.current] || []) mark.classList.remove('um-find-current');
    }

    find.current = -1;

    const marks = find.matches[index];

    if (!marks || marks.length === 0) return false;

    find.current = index;

    for (const mark of marks) mark.classList.add('um-find-current');

    for (let parent = marks[0].parentElement; parent; parent = parent.parentElement) {
      if (parent.localName === 'details' && !parent.open) parent.open = true;
    }

    marks[0].scrollIntoView({ block: 'center', inline: 'nearest' });

    return true;
  }

  function scrollToHeading(index) {
    const heading = state.headingNodes[index];

    if (!heading) return false;

    heading.scrollIntoView({ block: 'start' });

    return true;
  }

  // The reader's selection as text. The selection's range is kept, since a live range follows the
  // document as a search marks it, and `matchInSelection` finds the match that lies inside it.
  function selectedText() {
    const selection = window.getSelection ? window.getSelection() : null;

    state.selectionRange = selection && selection.rangeCount > 0 ? selection.getRangeAt(0).cloneRange() : null;

    return String(selection ? selection.toString() : '');
  }

  function matchInSelection() {
    const find = state.find;
    const range = state.selectionRange;

    if (!find || !range) return -1;

    for (let index = 0; index < find.matches.length; index += 1) {
      if (find.matches[index].some(function (mark) { return range.intersectsNode(mark); })) return index;
    }

    return -1;
  }

  async function start(options) {
    const generation = ++state.generation;

    state.token = options.generation;
    state.root = document.getElementById('um-root');
    state.blocks = [];
    state.headings = [];
    state.headingNodes = [];
    state.headingsCut = false;
    state.find = null;
    state.usedIDs = new Set();
    state.rendered = false;
    state.lastAnchor = null;
    state.root.textContent = '';

    if (options.theme) applyTheme(options.theme);

    try {
      const response = await fetch(DOCUMENT_URL, { cache: 'no-store' });

      if (!response.ok) throw new Error('The document could not be loaded.');

      const text = await response.text();

      if (generation !== state.generation) return;

      const env = {};
      const parsed = md.parse(text, env);
      const groups = groupTokens(parsed);
      const anchor = options.anchor || null;
      let restored = anchor === null;
      let batch = [];
      let batchTokens = 0;
      let slice = SLICE_MILLISECONDS;
      let sliceStart = performance.now();

      let unit = null;

      for (const group of groups) {
        if (unit) {
          const html = renderGroup(group, env);

          unit.groups.push(group);
          unit.parts.push(html);
          unit.depth += openDepth(html);

          if (unit.depth <= 0 || unit.groups.length >= MAX_UNIT_GROUPS) {
            placeUnit(unit);
            unit = null;
          }
        } else if (group.hasHTML) {
          placeBatch(batch, env);
          batch = [];
          batchTokens = 0;

          const html = renderGroup(group, env);
          const depth = openDepth(html);

          if (depth > 0) {
            unit = { groups: [group], parts: [html], depth: depth };
          } else {
            placeHTML(html, group);
          }
        } else {
          batch.push(group);
          batchTokens += group.tokens.length;

          if (batch.length >= BATCH_GROUPS || batchTokens >= BATCH_TOKENS) {
            placeBatch(batch, env);
            batch = [];
            batchTokens = 0;
          }
        }

        if (!restored && state.blocks.length > 0 && state.blocks[state.blocks.length - 1].line >= anchor.line) {
          placeBatch(batch, env);
          batch = [];
          batchTokens = 0;
          restored = scrollToAnchor(anchor);
        }

        if (performance.now() - sliceStart > slice) {
          // WebKit lays out everything inserted so far while the page is idle, and the cost grows
          // with the document. Each slice is a multiple of the last layout's cost, so layout stays
          // a fraction of the total however large the document is.
          const idleStart = performance.now();

          await yieldToPage();

          if (generation !== state.generation) return;

          slice = Math.min(MAX_SLICE_MILLISECONDS, Math.max(SLICE_MILLISECONDS, (performance.now() - idleStart) * 3));
          sliceStart = performance.now();
        }
      }

      if (unit) placeUnit(unit);

      placeBatch(batch, env);

      if (!restored) scrollToAnchor(anchor);

      state.rendered = true;

      // A final newline ends the last line. It does not start another.
      let lines = text.length === 0 || text.endsWith('\n') ? 0 : 1;

      for (let at = text.indexOf('\n'); at !== -1; at = text.indexOf('\n', at + 1)) lines += 1;

      const settled = currentAnchor();

      state.lastAnchor = settled;
      post({
        kind: 'rendered', generation: state.token, lines: lines, headings: state.headings,
        headingsCut: state.headingsCut, anchor: settled,
      });
    } catch (error) {
      post({ kind: 'failed', generation: state.token, reason: String(error && error.message ? error.message : error).slice(0, 200) });
    }
  }

  // The browser fires at most one scroll event for each frame. The handler reports at once, so the
  // host's cache trails a scroll by one message and no timer.
  window.addEventListener('scroll', pushAnchor, { passive: true });

  api.start = start;
  api.setTheme = applyTheme;
  api.find = find;
  api.clearFind = clearFind;
  api.selectMatch = selectMatch;
  api.scrollToHeading = scrollToHeading;
  api.selectedText = selectedText;
  api.matchInSelection = matchInSelection;
  api.foldText = function (text) { return foldText(String(text), false).text; };

  window.umViewer = api;

  post({ kind: 'ready' });
})();
