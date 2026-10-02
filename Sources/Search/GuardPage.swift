/// Page-side evidence for a proposed browser action. It resolves through the
/// same drive resolver as execution and never changes page state.
// ponytail: DOM heuristics cannot infer every custom handler; unknown actions ask.
// Add explicit site adapters if repeated unknowns make a workflow impractical.
enum GuardPage {
    static let inspect = #"""
    function (d, op, args) {
      args = args || {};
      var verb = String(op || '').replace(/^act\./, '');
      var query = {};
      var payloadTextOp = /^(fill|type|press|clickAt)$/.test(verb);
      if (verb === 'drag') query = Array.isArray(args.source) ? { at: args.source } : (args.source || {});
      else {
        ['ref', 'loc', 'css'].forEach(function (k) {
          if (args[k] !== undefined) query[k] = args[k];
        });
        if (!payloadTextOp && args.text !== undefined) query.text = args.text;
      }
      var target, dragTarget = null, dragPoint = null, dragStart = null;
      try {
        if (op === 'guard.context') { target = document.body || document.documentElement; }
        else if (verb === 'drag') {
          if (Array.isArray(args.source)) dragStart = [+args.source[0], +args.source[1]];
          target = d.resolve(query);
          if (dragStart && (!dragStart.every(Number.isFinite) || dragStart[0] < 0 || dragStart[1] < 0 ||
              dragStart[0] >= (window.innerWidth || 1024) || dragStart[1] >= (window.innerHeight || 768)))
            return { error: 'drag source must be inside the viewport', code: 'NOT_FOUND' };
          if (args.to && typeof args.to === 'object' && !Array.isArray(args.to) &&
              ['ref', 'loc', 'css', 'text', 'at'].some(function (key) { return args.to[key] != null; })) {
            dragTarget = d.resolve(args.to);
          } else {
            dragPoint = Array.isArray(args.to) ? [+args.to[0], +args.to[1]] : args.to && typeof args.to === 'object' ? [+args.to.x, +args.to.y] : [NaN, NaN];
            if (!dragPoint.every(Number.isFinite) || dragPoint[0] < 0 || dragPoint[1] < 0 ||
                dragPoint[0] >= (window.innerWidth || 1024) || dragPoint[1] >= (window.innerHeight || 768))
              return { error: 'drag destination must be inside the viewport', code: 'NOT_FOUND' };
          }
        }
        else if (verb === 'clickAt') {
          var p = Array.isArray(args.at) ? args.at : (args.x !== undefined ? [args.x, args.y] : null);
          if (!p || !document.elementFromPoint) return { error: 'click target cannot be resolved', code: 'NOT_FOUND' };
          target = document.elementFromPoint(+p[0], +p[1]);
          if (!target) return { error: 'click target cannot be resolved', code: 'NOT_FOUND' };
        } else if (verb === 'press' && !Object.keys(query).length) {
          target = document.activeElement || document.body;
        } else if (verb === 'submit') {
          target = d.resolve(query);
          target = target.tagName === 'FORM' ? target : (target.form || (target.closest && target.closest('form')));
          if (!target) return { error: 'submit target has no form', code: 'NOT_FOUND' };
        } else {
          target = d.resolve(query);
        }
      } catch (e) { return { error: String(e && e.message || e), code: e && e.code || 'NOT_FOUND' }; }

      if (/^(click|clickAt)$/.test(verb) && target.closest) {
        target = target.closest('button,a[href],[role="button"],[role="menuitem"],input,select,textarea') || target;
      }
      var doc = target.ownerDocument || document;
      var state = d.__guardPageState;
      if (!state) {
        var bytes = new Uint8Array(16);
        try { window.crypto.getRandomValues(bytes); } catch (e) { for (var bi = 0; bi < bytes.length; bi++) bytes[bi] = Math.floor(Math.random() * 256); }
        state = { documents: new WeakMap(), nodes: new WeakMap(), next: 0, nonce: Array.prototype.map.call(bytes, function (b) { return b.toString(16).padStart(2, '0'); }).join('') };
        try { Object.defineProperty(d, '__guardPageState', { value: state }); } catch (e) { d.__guardPageState = state; }
      }
      var docId = state.documents.get(doc);
      if (!docId) { docId = state.nonce + ':' + (++state.next); state.documents.set(doc, docId); }
      var nodeId = state.nodes.get(target);
      if (!nodeId) { nodeId = ++state.next; state.nodes.set(target, nodeId); }
      var form = target.tagName === 'FORM' ? target : (target.form || (target.closest && target.closest('form')));
      var norm = function (s) { return String(s || '').replace(/\s+/g, ' ').trim(); };
      var rawText = function (el) { return norm((el && (el.innerText !== undefined ? el.innerText : el.textContent)) || ''); };
      var attr = function (el, name) { return el && el.getAttribute ? (el.getAttribute(name) || '') : ''; };
      var identity = function (el) {
        return { tag: el.tagName || '', id: el.id || '', name: attr(el, 'name'), type: attr(el, 'type'),
          role: attr(el, 'role'), href: attr(el, 'href'), action: attr(el, 'action'),
          aria: attr(el, 'aria-label'), title: attr(el, 'title'), text: rawText(el), value: el.value == null ? '' : String(el.value),
          checked: !!el.checked, selected: !!el.selected, documentId: docId, nodeId: nodeId };
      };
      var secretField = function (el) {
        var t = (attr(el, 'type') || '').toLowerCase(), n = (attr(el, 'id') + ' ' + (el.labels ? Array.prototype.map.call(el.labels, rawText).join(' ') : '') + ' ' + attr(el, 'name') + ' ' + attr(el, 'autocomplete') + ' ' + attr(el, 'aria-label') + ' ' + attr(el, 'placeholder')).toLowerCase();
        return t === 'password' || /\b(code|otp|one.?time|verification.?code|security.?code|auth.?code|passcode|token)\b/.test(n);
      };
      var fields = [];
      var sensitive = false;
      if (form || op === 'guard.context') {
        Array.prototype.forEach.call((form || doc).querySelectorAll('input,textarea,select,[contenteditable="true"]'), function (el) {
          var value = el.isContentEditable ? rawText(el) : (el.value == null ? '' : String(el.value));
          if (secretField(el) && value) sensitive = true;
          var selected = el.tagName === 'SELECT' ? Array.prototype.filter.call(el.options, function (o) { return o.selected; }).map(function (o) { return { value: o.value, text: rawText(o) }; }) : undefined;
          fields.push({ id: el.id || '', name: attr(el, 'name'), type: attr(el, 'type'), label: (el.labels && Array.prototype.map.call(el.labels, rawText).join(' ')) || attr(el, 'aria-label') || attr(el, 'placeholder'), value: value, checked: /^(checkbox|radio)$/i.test(attr(el, 'type')) ? !!el.checked : undefined, selected: selected });
        });
      }
      var scanSecrets = function (scanDoc) {
        Array.prototype.forEach.call(scanDoc.querySelectorAll('input'), function (el) { if (secretField(el)) sensitive = true; });
        Array.prototype.forEach.call(scanDoc.querySelectorAll('iframe,frame'), function (frame) {
          try { if (frame.contentDocument) scanSecrets(frame.contentDocument); else sensitive = true; } catch (e) { sensitive = true; }
        });
      };
      try { scanSecrets(document); if (/\b(password|verification code|one.time code|recovery code)\b.{0,30}\b[0-9]{4,8}\b/i.test(rawText(document.body))) sensitive = true; } catch (e) { sensitive = true; }
      var tgt = identity(target);
      var scope = target.closest && target.closest('dialog,[role="dialog"],section,article,main');
      scope = scope || (form && form.parentElement) || target.parentElement || target;
      var scopeClone = scope.cloneNode(true);
      Array.prototype.forEach.call(scopeClone.querySelectorAll('script,style,time,[role="timer"],input,textarea,select,[contenteditable]'), function(el) { el.remove(); });
      var surrounding = rawText(scopeClone);
      var formId = form ? { id: form.id || '', name: attr(form, 'name'), action: form.action || attr(form, 'action'), method: attr(form, 'method'), text: rawText(form), fields: fields } : null;
      var submitter = (verb === 'submit' || verb === 'press' || verb === 'type' || target.tagName === 'FORM') && form
        ? form.querySelector('button[type="submit"],input[type="submit"],button:not([type])') : null;
      var control = submitter || target;
      var link = control.closest && control.closest('a[href]');
      var destination = link ? link.href : (form ? form.action : '');
      var valueIsLabel = control.tagName === 'INPUT' && /^(submit|button|image)$/i.test(attr(control, 'type'));
      var labels = control.labels ? Array.prototype.map.call(control.labels, rawText).join(' ') : '';
      var subject = norm([rawText(control), attr(control, 'aria-label'), attr(control, 'title'), labels, valueIsLabel ? control.value : ''].join(' ')).toLowerCase();
      var safeFormText = '';
      if (form) {
        var clone = form.cloneNode(true);
        Array.prototype.forEach.call(clone.querySelectorAll('input,textarea,select,button,[contenteditable]'), function (el) { el.remove(); });
        safeFormText = rawText(clone);
      }
      var formContext = norm([form && form.getAttribute('aria-label'), form && form.getAttribute('name'), destination,
        doc.location && doc.location.href, safeFormText].join(' ')).toLowerCase();
      // Field values and other controls never classify a named action.
      var context = formContext;
      var genericCommit = !subject || /^(submit|next|continue|confirm|done|finish|apply|save|ok|yes)$/i.test(subject);
      var words = subject + (genericCommit ? ' ' + context : '');
      var categories = [];
      var add = function (c) { if (categories.indexOf(c) < 0) categories.push(c); };
      var has = function (re) { return re.test(words); };
      if (verb === 'drag') add('unverified');
      var key = String(args.key || '');
      var keyParts = key.length > 1 ? key.split('+').map(function (part) { return part.trim(); }) : [key];
      var hasKeyModifiers = (args.modifiers && args.modifiers.length) || keyParts.length > 1;
      key = keyParts[keyParts.length - 1];
      var enterKey = /^(Enter|Return)$/i.test(key);
      var activationKey = /^(Enter|Return| |Space|Spacebar)$/i.test(key);
      var keyboardCommit = verb === 'press' && enterKey && (target.isContentEditable || /^(INPUT|TEXTAREA)$/.test(target.tagName));
      var typeSubmit = verb === 'type' && /[\r\n]/.test(String(args.text || '')) && (target.isContentEditable || /^(INPUT|TEXTAREA)$/.test(target.tagName));
      var composerKey = (keyboardCommit || typeSubmit) && /message|reply|chat|comment/i.test([attr(target, 'placeholder'), attr(target, 'aria-label'), attr(target, 'name'), attr(target, 'role')].join(' '));
      var actionInput = target.tagName === 'INPUT' && /^(submit|button|image|reset|checkbox|radio)$/i.test(attr(target, 'type'));
      var keyboardActivation = verb === 'press' && activationKey && (target.tagName === 'BUTTON' || actionInput || !!link || /button|menuitem/.test(attr(target, 'role')));
      var unknownShortcut = verb === 'press' && !/^(Tab|Escape|Esc|ArrowUp|ArrowDown|ArrowLeft|ArrowRight|Home|End|PageUp|PageDown|Enter|Return| |Space|Spacebar)$/i.test(key) && (hasKeyModifiers || /^(Delete|Backspace)$/i.test(key));
      var clickable = target.tagName === 'BUTTON' || actionInput || /button|menuitem/.test(attr(target, 'role')) || !!link || target.tagName === 'FORM' || ((keyboardCommit || typeSubmit) && !!form) || composerKey || keyboardActivation;
      var isCommit = verb === 'submit' || verb === 'check' || verb === 'select' || keyboardCommit || typeSubmit || keyboardActivation || (verb === 'click' || verb === 'clickAt');
      var personal = fields.some(function (f) { return /^(email|tel|text|number|date)$/i.test(f.type || 'text') && /name|email|phone|address|birth|title|postcode|zip|personal/i.test((f.name || '') + ' ' + (f.label || '')); });
      var signup = /\b(sign.?up|create (an? )?account|register|join now|new account)\b/.test(subject + ' ' + formContext);
      var login = has(/\b(log.?in|sign.?in|existing account|verify|verification code|one.?time code)\b/);

      if (isCommit && clickable) {
        if (/\b(delete|remove permanently|cancel subscription|cancel service|discard changes|overwrite|erase|empty trash)\b/.test(subject)) add('destructive');
        if (/\b(send|reply|submit message|submit contact|invite|text message)\b/.test(subject)) add('messages');
        if (has(/\b(pay|purchase|buy|place order|checkout|donat|transfer funds|subscribe|start trial)\b/)) add('payments');
        if (has(/\b(publish|post|share|upload|make public|expose|grant access|invite people)\b/)) add('sharing');
        if (has(/\b(delete account|close account|change password|reset password|recovery|security settings|permissions|grant access|connect app|oauth|create (an? )?account|register|sign up)\b/)) add('account');
        if (login && !signup && (/\b(log.?in|sign.?in)\b/.test(subject) || fields.some(function (f) { return /password|verification|one.?time|otp|code/i.test((f.type || '') + ' ' + (f.id || '') + ' ' + (f.name || '') + ' ' + (f.label || '')); }))) add('signingIn');
        if (signup && fields.some(function (f) { return /password|otp|code/i.test((f.type || '') + ' ' + (f.id || '') + ' ' + (f.name || '') + ' ' + (f.label || '')); })) add('account');
        if (/\bnext|continue\b/.test(subject) && personal) add('sharing');
        if (composerKey) add('messages');
        var knownNav = !!link && /^(GET)?$/i.test(form ? attr(form, 'method') : 'GET') && !/\b(delete|remove|cancel|logout|log out|sign out)\b/.test(subject);
        var plainInput = /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) && !/^(submit|button|image|reset)$/i.test(attr(target, 'type'));
        var explicitSafe = (plainInput && verb !== 'check' && verb !== 'select') || knownNav || /^(submit|button|image|reset)$/i.test(attr(target, 'type')) && /reset/i.test(attr(target, 'type'));
        var localUI = /^(open|close|expand|collapse|show|hide|dismiss|menu|more options|previous|back|tab|filter|sort|zoom in|zoom out)$/i.test(subject);
        if (!categories.length && !explicitSafe && !localUI && (verb === 'submit' || clickable || verb === 'check' || verb === 'select')) add('unverified');
      }
      if (unknownShortcut) add('unverified');
      if (/^(fill|type|select|check)$/.test(verb) && /auto.?sav|saved automatically|changes saved/i.test(formContext)) add('unverified');
      var editable = /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) || target.isContentEditable;
      if (!categories.length && /^(click|clickAt)$/.test(verb) && !clickable && !editable) add('unverified');
      if (!categories.length && /^(fill|type|select|check)$/.test(verb) && !form) add('unverified');
      if (!categories.length && verb === 'press' && activationKey && !editable && !link && target.tagName !== 'BUTTON') add('unverified');

      var redact = function (s) { return String(s || '').replace(/\b(\d{4,8})\b/g, '[redacted code]'); };
      var shownFields = fields.map(function (f) { return { label: f.label || f.name || f.type || 'field', value: secretField({ getAttribute: function (k) { return ({ id: f.id, type: f.type, name: f.name, 'aria-label': f.label })[k] || ''; } }) && f.value ? '[redacted]' : f.value }; });
      if (op === 'guard.context') return {
        categories: [], sensitive: sensitive, url: doc.location.href,
        fingerprint: JSON.stringify({documentId:docId, url:doc.location.href, fields:fields, surrounding:surrounding})
      };
      var label = subject || (valueIsLabel ? control.value : '') || verb;
      if (verb === 'drag') label = 'drag ' + (dragStart ? dragStart.join(',') : (subject || rawText(target) || describeTarget(target))) + ' to ' +
        (dragTarget ? (rawText(dragTarget) || describeTarget(dragTarget)) : dragPoint.join(','));
      if (label.length > 500) return { error: 'action label is too large to inspect safely', code: 'EVIDENCE_TOO_LARGE' };
      var summary = categories.length ? (label + ' on ' + ((new URL(doc.location.href)).host)) : '';
      var destinationHost = '';
      try { destinationHost = destination ? new URL(destination, doc.location.href).host : ''; } catch (e) {}
      var details = categories.length ? [verb === 'drag' ? 'From: ' + redact(dragStart ? dragStart.join(',') : rawText(target) || describeTarget(target)) + '. To: ' + redact(dragTarget ? rawText(dragTarget) || describeTarget(dragTarget) : dragPoint.join(',')) : '', formId && formId.fields.length ? 'Fields: ' + shownFields.map(function (f) { return f.label + (f.value ? ' = ' + f.value : ''); }).join(', ') : '', destinationHost ? 'Destination: ' + destinationHost : '', subject ? 'Control: ' + redact(subject) : ''].filter(Boolean).join('. ') : '';
      if (categories.length && !sensitive && surrounding) details += '\nPage context: ' + surrounding;
      if (details.length > 8000) return { error: 'page evidence is too large to inspect safely', code: 'EVIDENCE_TOO_LARGE' };
      var fingerprint = JSON.stringify({ surrounding: surrounding, url: doc.location.href, documentId: docId, target: tgt, form: formId, destination: destination, dragFrom: dragStart || identity(target), dragTo: dragTarget ? identity(dragTarget) : dragPoint, dragPath: args.path || [], text: rawText(target), action: op, key: key, modifiers: args.modifiers || [], payload: { text: args.text, values: args.values, on: args.on, x: args.x, y: args.y, at: args.at, button: args.button, double: args.double } });
      var out = { categories: categories, summary: summary, details: details, actionLabel: label, fingerprint: fingerprint, sensitive: sensitive, url: doc.location.href };
      if (target.__driveRef && target.__driveRef.ref) out.targetRef = target.__driveRef.ref;
      return out;

      function describeTarget(el) { return el.tagName.toLowerCase() + (el.id ? '#' + el.id : ''); }
    }
    """#
}
