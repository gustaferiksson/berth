import Foundation
import WebKit

enum BrowserPageContent {
    case text, html(String?), snapshot

    static let world = WKContentWorld.world(name: "berth")

    func read(in view: WKWebView) async throws -> String {
        let limit = 100_000
        let maxLength = 2 * limit + 2
        let result: String
        let name: String
        switch self {
        case .text:
            name = "Text"
            result = try await view.evaluateJavaScript("document.body?.innerText.slice(0, \(maxLength)) ?? ''", contentWorld: .defaultClient) as? String ?? ""

        case let .html(selector):
            name = "HTML"
            result = try await Self.run(Self.htmlScript, in: view, arguments: ["selector": selector as Any? ?? NSNull(), "maxLength": maxLength])

        case .snapshot:
            name = "Snapshot"
            result = try await Self.run(Self.snapshotScript, in: view, arguments: ["maxLength": maxLength])
        }

        let scalars = result.unicodeScalars
        let end = scalars.index(scalars.startIndex, offsetBy: limit, limitedBy: scalars.endIndex) ?? scalars.endIndex
        guard end != scalars.endIndex else { return result }

        return String(scalars[..<end]) + "\n\n[\(name) truncated at \(limit) characters]"
    }

    private struct ReadError: LocalizedError {
        let errorDescription: String?
    }

    private static func run(_ script: String, in view: WKWebView, arguments: [String: Any]) async throws -> String {
        let result = try await view.callAsyncJavaScript(outputScript + "\n" + script, arguments: arguments, contentWorld: world) as? [String: String]
        if let error = result?["error"] { throw ReadError(errorDescription: error) }
        guard let text = result?["text"] else { throw ReadError(errorDescription: "Couldn’t read the browser page") }

        return text
    }

    private static let outputScript = #"""
    let output = '';
    const line = (depth, text) => {
      if (output.length) output += '\n';
      output += '  '.repeat(depth).slice(0, maxLength - output.length);
      output += text.slice(0, maxLength - output.length);
    };
    """#

    private static let htmlScript = #"""
    let root = document.documentElement;
    if (selector !== null) {
      try {
        root = document.querySelector(selector);
      } catch {
        return { error: 'Invalid CSS selector ' + JSON.stringify(selector) };
      }
      if (!root) return { error: 'No element matches CSS selector ' + JSON.stringify(selector) };
    }
    if (!root) return { text: '' };

    const inertDocument = document.implementation.createHTMLDocument('');
    const escapeText = text => text.trim().replaceAll('&', '&amp;').replaceAll('\u00a0', '&nbsp;')
      .replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    const pending = [{ node: root, depth: 0 }];
    while (pending.length && output.length < maxLength) {
      const { node, depth, close } = pending.pop();
      if (close) {
        line(depth, close);
        continue;
      }
      if (node !== root && node.nextSibling) pending.push({ node: node.nextSibling, depth });
      if (node.nodeType === Node.TEXT_NODE) {
        const text = escapeText(node.data);
        if (text) line(depth, text);
        continue;
      }
      if (node.nodeType === Node.COMMENT_NODE) {
        line(depth, '<!--' + node.data + '-->');
        continue;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) continue;
      if (node.localName === 'script' || node.localName === 'style') {
        line(depth, node.outerHTML);
        continue;
      }

      const shell = inertDocument.importNode(node, false).outerHTML;
      const name = node.prefix ? node.prefix + ':' + node.localName : node.localName;
      const end = '</' + name + '>';
      const children = node.content instanceof DocumentFragment ? node.content : node;
      const child = children.firstChild;
      if (!shell.endsWith(end) || !child) {
        line(depth, shell);
        continue;
      }

      const start = shell.slice(0, -end.length);
      if (child === children.lastChild && child.nodeType === Node.TEXT_NODE) {
        line(depth, start + escapeText(child.data) + end);
        continue;
      }

      line(depth, start);
      pending.push({ depth, close: end }, { node: child, depth: depth + 1 });
    }
    return { text: output.replace(/[\uD800-\uDBFF]$/, '') };
    """#

    private static let snapshotScript = #"""
    const elementRefs = window.__berthElementRefs ??= new WeakMap();
    const refs = window.__berthRefs ??= new Map();
    const refFor = element => {
      if (elementRefs.has(element)) return elementRefs.get(element);
      const ref = 'e' + (refs.size + 1);
      elementRefs.set(element, ref);
      refs.set(ref, element);
      return ref;
    };

    const compact = text => (text ?? '').replace(/\s+/g, ' ').trim();
    const skippedTags = new Set(['head', 'script', 'style', 'template', 'noscript']);
    const hidden = element => {
      if (element.hasAttribute('hidden') || element.getAttribute('aria-hidden')?.toLowerCase() === 'true') return true;
      if (skippedTags.has(element.localName) || (element.localName === 'input' && element.type === 'hidden')) return true;
      const style = getComputedStyle(element);
      return style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse';
    };
    const contentText = element => {
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, node => {
        if (node.nodeType === Node.TEXT_NODE) return NodeFilter.FILTER_ACCEPT;
        if (hidden(node)) return NodeFilter.FILTER_REJECT;
        return node.localName === 'img' ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
      });
      let text = '';
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        text += node.nodeType === Node.TEXT_NODE ? node.data : (node.getAttribute('alt') ?? '');
      }
      return compact(text);
    };

    const roles = {
      article: 'article', aside: 'complementary', blockquote: 'blockquote', button: 'button',
      caption: 'caption', code: 'code', datalist: 'listbox', dd: 'definition', details: 'group',
      dialog: 'dialog', dl: 'list', dt: 'term', fieldset: 'group', figure: 'figure', figcaption: 'caption',
      form: 'form', hr: 'separator', li: 'listitem', main: 'main', menu: 'list', meter: 'meter',
      nav: 'navigation', ol: 'list', option: 'option', optgroup: 'group', output: 'status',
      p: 'paragraph', progress: 'progressbar', search: 'search', summary: 'button', table: 'table',
      tbody: 'rowgroup', td: 'cell', textarea: 'textbox', tfoot: 'rowgroup', thead: 'rowgroup',
      tr: 'row', ul: 'list'
    };
    const roleFor = element => {
      const explicit = compact(element.getAttribute('role')).split(' ')[0];
      if (explicit) return ['none', 'presentation', 'generic'].includes(explicit) ? '' : explicit;
      const tag = element.localName;
      if (/^h[1-6]$/.test(tag)) return 'heading';
      switch (tag) {
        case 'a': case 'area': return element.hasAttribute('href') ? 'link' : '';
        case 'img': return element.getAttribute('alt') === '' && !element.matches('[aria-label], [aria-labelledby], [title]') ? '' : 'img';
        case 'input':
          switch (element.type) {
            case 'button': case 'submit': case 'reset': case 'image': case 'file': return 'button';
            case 'checkbox': case 'radio': return element.type;
            case 'range': return 'slider';
            case 'number': return 'spinbutton';
            case 'search': return element.list ? 'combobox' : 'searchbox';
            default: return element.list ? 'combobox' : 'textbox';
          }
        case 'select': return element.multiple || element.size > 1 ? 'listbox' : 'combobox';
        case 'th': return ['row', 'rowgroup'].includes(element.scope) ? 'rowheader' : 'columnheader';
        case 'header': case 'footer':
          if (element.closest('article, aside, main, nav, section')) return '';
          return tag === 'header' ? 'banner' : 'contentinfo';
        case 'section': return element.matches('[aria-label], [aria-labelledby], [title]') ? 'region' : '';
        default: return Object.hasOwn(roles, tag) ? roles[tag] : (element.hasAttribute('contenteditable') && element.isContentEditable ? 'textbox' : '');
      }
    };
    const namedByContent = new Set([
      'button', 'caption', 'cell', 'checkbox', 'code', 'columnheader', 'definition', 'heading', 'link', 'listitem',
      'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'paragraph', 'radio', 'rowheader', 'switch', 'tab', 'term', 'treeitem'
    ]);
    const nameFor = (element, role) => {
      const labelled = compact(element.getAttribute('aria-labelledby')).split(' ').map(id => {
        const label = document.getElementById(id);
        return label && (compact(label.getAttribute('aria-label')) || label.textContent);
      }).filter(Boolean).join(' ');
      const labels = element.labels ? Array.from(element.labels, label => label.textContent).join(' ') : '';
      const supplied = [labelled, element.getAttribute('aria-label'), labels, element.getAttribute('alt'),
        element.getAttribute('title'), element.getAttribute('placeholder')].map(compact).find(Boolean);
      if (supplied) return supplied;
      if (element.localName === 'input' && role === 'button') {
        return compact(element.value) || ({ submit: 'Submit', reset: 'Reset' })[element.type] || '';
      }
      return namedByContent.has(role) ? contentText(element) : '';
    };
    const valueFor = (element, role) => {
      const aria = element.getAttribute('aria-valuetext') ?? element.getAttribute('aria-valuenow');
      if (aria !== null) return compact(aria);
      if (element.localName === 'select') return compact(Array.from(element.selectedOptions, option => option.value).join(', '));
      if (element.localName === 'input' && ['button', 'submit', 'reset', 'image', 'checkbox', 'radio'].includes(element.type)) return '';
      if (['input', 'textarea', 'meter', 'progress', 'output'].includes(element.localName)) return compact(String(element.value));
      return role === 'textbox' || role === 'searchbox' ? contentText(element) : '';
    };

    const root = document.body ?? document.documentElement;
    const pending = root ? [{ node: root, depth: 0, textInName: false }] : [];
    while (pending.length && output.length < maxLength) {
      const { node, depth, textInName } = pending.pop();
      if (node !== root && node.nextSibling) pending.push({ node: node.nextSibling, depth, textInName });
      if (node.nodeType === Node.TEXT_NODE) {
        const text = compact(node.data);
        if (text && !textInName) line(depth, '- text: ' + text);
        continue;
      }
      if (node.nodeType !== Node.ELEMENT_NODE || hidden(node)) continue;
      const role = roleFor(node);
      if (node.firstChild) pending.push({
        node: node.firstChild,
        depth: depth + Number(Boolean(role)),
        textInName: role ? namedByContent.has(role) || role === 'textbox' || role === 'searchbox' : textInName
      });
      if (!role) continue;

      const aria = state => node.getAttribute('aria-' + state);
      const rawName = nameFor(node, role);
      const name = Array.from(rawName.slice(0, 202)).slice(0, 100).join('');
      const states = [];
      if (role === 'heading') {
        const level = Number(aria('level'));
        states.push('level=' + (Number.isInteger(level) && level > 0 ? level : (/^h[1-6]$/.test(node.localName) ? node.localName[1] : '2')));
      }
      if (node.indeterminate || aria('checked') === 'mixed') states.push('checked=mixed');
      else if (node.checked || aria('checked') === 'true') states.push('checked');
      if (node.matches(':disabled') || aria('disabled') === 'true') states.push('disabled');
      if (aria('expanded') === 'true' || (node.localName === 'details' && node.open)) states.push('expanded');
      if (aria('expanded') === 'false' || (node.localName === 'details' && !node.open)) states.push('expanded=false');
      if (node.selected || aria('selected') === 'true') states.push('selected');
      if (node.required || aria('required') === 'true') states.push('required');
      if (node === document.activeElement) states.push('focused');
      states.push('ref=' + refFor(node));

      const value = valueFor(node, role);
      const url = role === 'link' ? compact(typeof node.href === 'string' ? node.href : node.getAttribute('href')) : '';
      line(depth, '- ' + role + (name ? ' ' + JSON.stringify(name) : '') + ' [' + states.join('] [') + ']'
        + (value ? ': ' + value : '') + (url ? ' /url: ' + url : ''));
    }
    return { text: output.replace(/[\uD800-\uDBFF]$/, '') };
    """#
}
