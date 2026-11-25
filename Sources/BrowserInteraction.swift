import BerthCore
import Foundation
import WebKit

enum BrowserInteraction {
    private struct Failure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    enum Wait: CustomStringConvertible {
        case selector(String), text(String), url(String), load, milliseconds(Int)

        init?(_ request: ControlRequest) {
            let conditions: [Self?] = [
                request.selector.flatMap { $0.isEmpty ? nil : .selector($0) },
                request.text.flatMap { $0.isEmpty ? nil : .text($0) },
                request.url.flatMap { $0.isEmpty ? nil : .url($0) },
                request.load == true ? .load : nil,
                request.milliseconds.flatMap { $0 >= 0 ? .milliseconds($0) : nil },
            ]
            let present = conditions.compactMap(\.self)
            guard present.count == 1, let condition = present.first else { return nil }

            self = condition
        }

        var description: String {
            switch self {
            case let .selector(selector): "visible element matching \(selector.debugDescription)"
            case let .text(text): "visible text \(text.debugDescription)"
            case let .url(substring): "URL containing \(substring.debugDescription)"
            case .load: "page load"
            case let .milliseconds(milliseconds): "\(milliseconds) ms"
            }
        }

        func matches(in view: WKWebView, navigating: () -> Bool) async throws -> Bool {
            let action: String
            let target: String?
            switch self {
            case let .selector(selector): (action, target) = ("wait-selector", selector)
            case let .text(text): (action, target) = ("wait-text", text)
            case .load: (action, target) = ("wait-load", nil)
            case .url, .milliseconds: return false
            }

            do {
                let result = try await BrowserInteraction.run(action, target: target, in: view)
                if case .load = self, navigating() { return false }

                return result["matched"] as? Bool == true
            } catch let error as WKError where navigating() || error.code == .javaScriptInvalidFrameTarget {
                return false
            }
        }
    }

    static func outcome(_ action: String, target: String?, in view: WKWebView, navigated: Bool, notes: [String]? = nil) throws -> ControlResponse {
        var outcome: [String: Any] = [
            "action": action, "target": target as Any? ?? NSNull(), "url": view.url?.absoluteString ?? "about:blank",
            "title": view.title ?? "", "navigated": navigated,
        ]
        if let notes { outcome["notes"] = notes }

        let data = try JSONSerialization.data(withJSONObject: outcome, options: [.sortedKeys, .withoutEscapingSlashes])
        return ControlResponse(text: String(decoding: data, as: UTF8.self))
    }

    static func evaluate(_ source: String, in view: WKWebView) async throws -> String {
        let result = try await view.callAsyncJavaScript("""
        const stringify = JSON.stringify;
        try {
          const value = await (async () => {
        \(source)
          })();
          const json = value === undefined ? 'null' : stringify(value);
          if (json === undefined) return { error: 'The return value cannot be serialized as JSON' };
          if (json.length > 100000 && (json.length > 200000 || Array.from(json).length > 100000)) {
            return { error: 'JavaScript result exceeds 100000 characters' };
          }
          return { text: json };
        } catch (error) {
          return { error: String(error) };
        }
        """, contentWorld: .page) as? [String: String]
        if let error = result?["error"] { throw Failure(message: error) }
        guard let value = result?["text"] else { throw Failure(message: "Couldn’t evaluate JavaScript") }

        return value
    }

    static func perform(_ action: String, request: ControlRequest, in view: WKWebView) async throws -> (target: String?, notes: [String]?) {
        let result = try await run(action, target: request.target, text: request.text, scrollTo: request.scrollTo, scrollBy: request.scrollBy, in: view)
        return (result["target"] as? String, result["notes"] as? [String])
    }

    private static func run(_ action: String, target: String?, text: String? = nil, scrollTo: String? = nil, scrollBy: Int? = nil, in view: WKWebView) async throws -> [String: Any] {
        let result = try await view.callAsyncJavaScript(script, arguments: [
            "action": action, "target": target as Any? ?? NSNull(), "text": text as Any? ?? NSNull(),
            "scrollTo": scrollTo as Any? ?? NSNull(), "scrollBy": scrollBy as Any? ?? NSNull(),
        ], contentWorld: BrowserPageContent.world) as? [String: Any]
        if let error = result?["error"] as? String { throw Failure(message: error) }
        guard let result else { throw Failure(message: "Couldn’t interact with the browser page") }

        return result
    }

    private static let script = #"""
    const fail = message => { throw new Error(message); };
    const visible = element => {
      if (!element?.isConnected) return false;
      const { display, visibility } = getComputedStyle(element);
      return display !== 'none' && visibility === 'visible'
        && Array.from(element.getClientRects()).some(rect => rect.width > 0 && rect.height > 0);
    };
    const disabled = element => !!element.closest('[aria-disabled="true" i], fieldset[disabled]')
      || element.hasAttribute('disabled') || element.matches(':disabled');
    const interactive = 'a[href], button, input, select, textarea, summary, [tabindex], [contenteditable]:not([contenteditable="false" i]), [role="button"], [role="link"], [role="checkbox"], [role="tab"]';
    const visibleText = element => (element.innerText ?? '').trim();
    const cssMatches = selector => {
      try { return Array.from(document.querySelectorAll(selector)); }
      catch { fail('Invalid CSS selector ' + JSON.stringify(selector)); }
    };
    const resolve = target => {
      if (/^e[0-9]+$/.test(target)) {
        const element = window.__berthRefs?.get(target);
        if (!element?.isConnected) fail('Stale or unknown snapshot ref ' + target + '. Take a new snapshot.');
        return [element];
      }
      if (!target.startsWith('text=')) return cssMatches(target);
      const query = target.slice(5).trim();
      if (!query) fail('Expected visible text after text=');
      const candidates = Array.from(document.querySelectorAll('body, body *')).filter(visible)
        .map(element => [element, visibleText(element)]).filter(([, label]) => label.includes(query));
      const exact = candidates.filter(([, label]) => label === query);
      const matches = (exact.length ? exact : candidates).map(([element]) => element);
      const controls = matches.filter(element => element.matches(interactive));
      if (controls.length) return controls;
      const containers = new Set();
      for (const match of matches) {
        for (let parent = match.parentElement; parent && !containers.has(parent); parent = parent.parentElement) {
          containers.add(parent);
        }
      }
      return matches.filter(element => !containers.has(element));
    };
    const check = element => {
      if (!element.isConnected) fail('The target is detached');
      if (!visible(element)) fail('The target is hidden');
      if (disabled(element)) fail('The target is disabled');
    };
    const describe = element => {
      const labels = Array.from(element.labels ?? [], label => visibleText(label)).join(' ');
      const name = (element.getAttribute('aria-label') || labels || visibleText(element)
        || element.getAttribute('alt') || element.getAttribute('placeholder') || element.id).trim().slice(0, 100);
      return element.localName + (name ? ' ' + JSON.stringify(name) : '');
    };
    const scrollIntoView = element => element.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });

    const editor = element => {
      if (element.isContentEditable) return { content: true };
      if (element.readOnly) return null;
      if (element instanceof HTMLTextAreaElement) return { prototype: HTMLTextAreaElement.prototype };
      if (element instanceof HTMLInputElement && ['text', 'search', 'url', 'tel', 'email', 'password', 'number'].includes(element.type)) {
        return { prototype: HTMLInputElement.prototype };
      }
      return null;
    };
    const inputEvent = (element, event, type, data) => element.dispatchEvent(new InputEvent(event, {
      inputType: type, data, bubbles: true, composed: true, cancelable: event === 'beforeinput'
    }));
    const change = element => element.dispatchEvent(new Event('change', { bubbles: true }));
    const setValue = (element, edit, value) => {
      // The isolated world setter bypasses page-world instance overrides such as React's value tracker.
      Object.getOwnPropertyDescriptor(edit.prototype, 'value').set.call(element, value);
    };
    const editText = (element, edit, type, data) => {
      if (!inputEvent(element, 'beforeinput', type, data)) return;
      if (edit.content) {
        if (type === 'deleteContentBackward') document.execCommand('delete');
        else if (type === 'deleteContentForward') document.execCommand('forwardDelete');
        else document.execCommand('insertText', false, data);
        return;
      }
      const value = element.value;
      let start = element.selectionStart ?? value.length;
      let end = element.selectionEnd ?? value.length;
      if (start === end && type === 'deleteContentBackward') start -= Array.from(value.slice(0, start)).at(-1)?.length ?? 0;
      if (start === end && type === 'deleteContentForward') end += Array.from(value.slice(end))[0]?.length ?? 0;
      const next = value.slice(0, start) + (data ?? '') + value.slice(end);
      if (next === value) return;
      setValue(element, edit, next);
      const caret = start + (data?.length ?? 0);
      if (element.selectionStart !== null) element.setSelectionRange(caret, caret);
      inputEvent(element, 'input', type, data);
    };
    const fill = (element, value) => {
      const edit = editor(element);
      if (!edit) fail('The target is not editable');
      element.focus({ preventScroll: true });
      if (edit.content) {
        const range = document.createRange();
        range.selectNodeContents(element);
        getSelection().removeAllRanges();
        getSelection().addRange(range);
        if (value) document.execCommand('insertText', false, value);
        else document.execCommand('delete');
      } else {
        element.select();
        setValue(element, edit, value);
        inputEvent(element, 'input', 'insertText', value);
      }
      change(element);
    };

    const keys = new Set(['Enter', 'Tab', 'Escape', 'Backspace', 'Delete', 'Space', 'ArrowUp', 'ArrowDown',
      'ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown']);
    const punctuation = {
      '`': 'Backquote', '~': 'Backquote', '-': 'Minus', '_': 'Minus', '=': 'Equal', '+': 'Equal',
      '[': 'BracketLeft', '{': 'BracketLeft', ']': 'BracketRight', '}': 'BracketRight',
      '\\': 'Backslash', '|': 'Backslash', ';': 'Semicolon', ':': 'Semicolon', "'": 'Quote', '"': 'Quote',
      ',': 'Comma', '<': 'Comma', '.': 'Period', '>': 'Period', '/': 'Slash', '?': 'Slash'
    };
    const keyCode = key => {
      if (/^[a-z]$/i.test(key)) return 'Key' + key.toUpperCase();
      if (/^[0-9]$/.test(key)) return 'Digit' + key;
      const shiftedDigit = ')!@#$%^&*('.indexOf(key);
      if (key.length === 1 && shiftedDigit >= 0) return 'Digit' + shiftedDigit;
      if (key === ' ') return 'Space';
      return punctuation[key] ?? (keys.has(key) ? key : 'Unidentified');
    };
    const keyOptions = spec => {
      const parts = spec.endsWith('++') ? [...spec.slice(0, -2).split('+'), '+'] : spec === '+' ? [spec] : spec.split('+');
      const key = parts.pop();
      const modifiers = new Set(parts);
      if ((!keys.has(key) && Array.from(key).length !== 1) || modifiers.size !== parts.length
        || parts.some(part => !['Shift', 'Control', 'Alt', 'Meta'].includes(part))) fail('Invalid key ' + JSON.stringify(spec));
      return {
        key: key === 'Space' ? ' ' : key === key.toLowerCase() && modifiers.has('Shift') && /^[a-z]$/.test(key) ? key.toUpperCase() : key,
        code: keyCode(key), shiftKey: modifiers.has('Shift'), ctrlKey: modifiers.has('Control'),
        altKey: modifiers.has('Alt'), metaKey: modifiers.has('Meta')
      };
    };
    const moveFocus = (element, backwards) => {
      const candidates = Array.from(document.querySelectorAll(interactive + ', iframe, audio[controls], video[controls]'))
        .filter(node => node.tabIndex >= 0 && visible(node) && !disabled(node) && !node.closest('[inert]'))
        .sort((left, right) => (left.tabIndex || Infinity) - (right.tabIndex || Infinity));
      const index = candidates.indexOf(element);
      let next = index < 0 ? undefined : candidates[index + (backwards ? -1 : 1)];
      if (index < 0) {
        const direction = backwards ? Node.DOCUMENT_POSITION_PRECEDING : Node.DOCUMENT_POSITION_FOLLOWING;
        next = (backwards ? candidates.slice().reverse() : candidates)
          .find(candidate => element.compareDocumentPosition(candidate) & direction);
      }
      (next ?? (backwards ? candidates.at(-1) : candidates[0]))?.focus();
    };
    const moveCaret = (element, edit, key, extend) => {
      if (edit.content) {
        const direction = { ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'backward', ArrowDown: 'forward', Home: 'backward', End: 'forward' }[key];
        if (direction) getSelection().modify(extend ? 'extend' : 'move', direction, /^(Home|End)$/.test(key) ? 'lineboundary' : /Up|Down/.test(key) ? 'line' : 'character');
        return;
      }
      const { value, selectionStart: start, selectionEnd: end, selectionDirection } = element;
      if (start === null) return;
      const backwards = selectionDirection === 'backward';
      const anchor = backwards ? end : start;
      const caret = backwards ? start : end;
      const lineStart = caret === 0 ? 0 : value.lastIndexOf('\n', caret - 1) + 1;
      const newline = value.indexOf('\n', caret);
      const lineEnd = newline < 0 ? value.length : newline;
      const column = caret - lineStart;
      let next = caret;
      switch (key) {
        case 'ArrowLeft': next = !extend && start !== end ? start : caret - (Array.from(value.slice(0, caret)).at(-1)?.length ?? 0); break;
        case 'ArrowRight': next = !extend && start !== end ? end : caret + (Array.from(value.slice(caret))[0]?.length ?? 0); break;
        case 'Home': next = lineStart; break;
        case 'End': next = lineEnd; break;
        case 'ArrowUp': {
          const previousStart = lineStart < 2 ? 0 : value.lastIndexOf('\n', lineStart - 2) + 1;
          next = lineStart === 0 ? 0 : Math.min(previousStart + column, lineStart - 1);
          break;
        }
        case 'ArrowDown': {
          const followingEnd = value.indexOf('\n', lineEnd + 1);
          next = Math.min(lineEnd + 1 + column, followingEnd < 0 ? value.length : followingEnd);
          break;
        }
      }
      if (extend) element.setSelectionRange(Math.min(anchor, next), Math.max(anchor, next), next < anchor ? 'backward' : 'forward');
      else element.setSelectionRange(next, next);
    };
    const defaultKey = (element, edit, options) => {
      const { key, shiftKey, ctrlKey, altKey, metaKey } = options;
      if (key === 'Tab' && !ctrlKey && !metaKey && !altKey) {
        moveFocus(element, shiftKey);
        return;
      }
      if ((ctrlKey || metaKey) && !altKey && key.toLowerCase() === 'a' && edit) {
        if (edit.content) getSelection().selectAllChildren(element);
        else element.select();
        return;
      }
      if (key === 'Enter') {
        if (edit && (edit.content || element instanceof HTMLTextAreaElement)) editText(element, edit, 'insertLineBreak', '\n');
        else if (element.matches('a[href], button, input[type="button"], input[type="submit"], input[type="reset"], input[type="image"], summary')) element.click();
        else if (element instanceof HTMLInputElement && element.form) {
          const submitter = Array.from(element.form.elements).find(control => control.type === 'submit' || control.type === 'image');
          if (!submitter) HTMLFormElement.prototype.requestSubmit.call(element.form);
          else if (!disabled(submitter)) HTMLFormElement.prototype.requestSubmit.call(element.form, submitter);
        }
        return;
      }
      if (key === ' ' && !ctrlKey && !metaKey && !altKey && element.matches('button, input[type="button"], input[type="submit"], input[type="reset"], input[type="checkbox"], input[type="radio"], summary')) {
        element.click();
        return;
      }
      const navigationKey = /^(Arrow(Up|Down|Left|Right)|Home|End|PageUp|PageDown)$/.test(key);
      if (edit) {
        if (key === 'Backspace' || key === 'Delete') editText(element, edit, key === 'Backspace' ? 'deleteContentBackward' : 'deleteContentForward', null);
        else if (navigationKey && !key.startsWith('Page')) moveCaret(element, edit, key, shiftKey);
        else if (Array.from(key).length === 1 && !ctrlKey && !metaKey && !altKey) editText(element, edit, 'insertText', key);
      } else if (navigationKey && !ctrlKey && !metaKey && !altKey) {
        if (key === 'Home' || key === 'End') window.scrollTo({ top: key === 'Home' ? 0 : document.scrollingElement.scrollHeight, behavior: 'instant' });
        else {
          const distance = { ArrowUp: -40, ArrowDown: 40, PageUp: -innerHeight, PageDown: innerHeight, ArrowLeft: 0, ArrowRight: 0 };
          window.scrollBy({ top: distance[key], left: key === 'ArrowLeft' ? -40 : key === 'ArrowRight' ? 40 : 0, behavior: 'instant' });
        }
      }
    };
    const sendKey = (element, edit, options) => {
      const event = { ...options, bubbles: true, cancelable: true, composed: true };
      const allowed = element.dispatchEvent(new KeyboardEvent('keydown', event));
      const printable = Array.from(options.key).length === 1;
      if (allowed && (!printable || element.dispatchEvent(new KeyboardEvent('keypress', event)))) {
        if (element.isConnected && !disabled(element)) defaultKey(element, edit, options);
      }
      (document.activeElement ?? element).dispatchEvent(new KeyboardEvent('keyup', event));
    };

    const pointEvents = (element, hover) => {
      const rect = element.getBoundingClientRect();
      const position = { clientX: rect.x + rect.width / 2, clientY: rect.y + rect.height / 2, view: window };
      const dispatch = (name, buttons = 0) => {
        const enters = name.endsWith('enter');
        const event = { ...position, buttons, bubbles: !enters, cancelable: !enters, composed: !enters,
          detail: ['mousedown', 'mouseup', 'click'].includes(name) ? 1 : 0 };
        const pointer = name.startsWith('pointer') || name === 'click';
        return element.dispatchEvent(pointer
          ? new PointerEvent(name, { ...event, pointerType: 'mouse', pointerId: 1, isPrimary: true })
          : new MouseEvent(name, event));
      };
      dispatch('pointerover');
      dispatch('pointerenter');
      dispatch('mouseover');
      if (hover) {
        dispatch('mouseenter');
        dispatch('pointermove');
        dispatch('mousemove');
        return;
      }
      const pointerDown = dispatch('pointerdown', 1);
      if (pointerDown && dispatch('mousedown', 1)) {
        element.closest(interactive)?.focus?.({ preventScroll: true });
      }
      dispatch('pointerup');
      if (pointerDown) dispatch('mouseup');
      dispatch('click');
    };
    const select = (element, value) => {
      if (!(element instanceof HTMLSelectElement)) fail('The target is not a select element');
      const options = Array.from(element.options);
      const byValue = options.filter(option => option.value === value);
      const matches = byValue.length ? byValue : options.filter(option => option.label.trim() === value.trim());
      const option = matches[0];
      if (!option) fail('No option matches ' + JSON.stringify(value));
      if (option.matches(':disabled')) fail('The option is disabled');
      element.selectedIndex = option.index;
      element.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
      change(element);
      return matches.length;
    };

    try {
      if (action === 'wait-selector') return { matched: cssMatches(target).some(visible) };
      if (action === 'wait-text') return { matched: visible(document.body) && visibleText(document.body).includes(target) };
      if (action === 'wait-load') return { matched: document.readyState === 'complete' };

      if (action === 'scroll' && target === null) {
        if (scrollTo === 'top' || scrollTo === 'bottom') {
          window.scrollTo({ top: scrollTo === 'top' ? 0 : document.scrollingElement.scrollHeight, behavior: 'instant' });
          return { target: 'page ' + scrollTo };
        }
        if (scrollBy !== null) {
          window.scrollBy({ top: scrollBy, behavior: 'instant' });
          return { target: 'page by ' + scrollBy + ' px' };
        }
      }
      if (action === 'press' || action === 'type') {
        const element = document.activeElement;
        if (!element) fail('No focused element');
        if (text === null) fail(action === 'press' ? 'Missing key' : 'Missing text');
        const description = describe(element);
        if (element !== document.body) {
          check(element);
          scrollIntoView(element);
          check(element);
        }
        if (action === 'press') sendKey(element, editor(element), keyOptions(text));
        else {
          if (!editor(element)) fail('The focused element is not editable');
          for (const key of text) {
            const focused = document.activeElement;
            if (!focused) fail('No focused element');
            check(focused);
            const edit = editor(focused);
            if (!edit) fail('The focused element is not editable');
            sendKey(focused, edit, { key, code: keyCode(key), shiftKey: /^[A-Z]$/.test(key) });
          }
        }
        return { target: description };
      }

      if (!target) fail('Missing browser target');
      const matches = resolve(target);
      const element = matches[0];
      if (!element) fail('No element matches ' + JSON.stringify(target));
      check(element);
      scrollIntoView(element);
      check(element);
      const notes = [];
      if (matches.length > 1) notes.push(matches.length + ' elements matched; used the first in document order');
      const description = describe(element);
      switch (action) {
        case 'click': pointEvents(element, false); break;
        case 'hover': pointEvents(element, true); break;
        case 'fill':
          if (text === null) fail('Missing text');
          fill(element, text);
          break;
        case 'select': {
          if (text === null) fail('Missing option value');
          const options = select(element, text);
          if (options > 1) notes.push(options + ' options matched; used the first in document order');
          break;
        }
      }
      return notes.length ? { target: description, notes } : { target: description };
    } catch (error) {
      return { error: error.message };
    }
    """#
}
