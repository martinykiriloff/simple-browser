// Password agent. Runs in its own isolated content world in every frame, so
// page script can neither see it nor reach the message handler it posts to.
//
// It never decides anything: it reports what sign-in forms the document has,
// which field has focus, and what was typed when a form was submitted. The app
// decides what to save, what to offer and what to fill, using the frame's
// origin as WebKit reports it -- not anything said here.
(function () {
  'use strict';
  if (window.__sbPasswords) return;
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.passwords;
  if (!handler) return;

  function post(message) {
    try { handler.postMessage(message); } catch (e) { /* the view is going away */ }
  }

  // ---------------------------------------------------------------- fields

  // A field that has been a password field stays one for us: "show password"
  // buttons flip the type to text just before people press Sign in.
  var knownPasswordFields = new WeakSet();

  function isPasswordField(el) {
    if (!(el instanceof HTMLInputElement)) return false;
    if (el.type === 'password') { knownPasswordFields.add(el); return true; }
    return knownPasswordFields.has(el) && el.type === 'text';
  }

  function isTextLike(el) {
    if (!(el instanceof HTMLInputElement) || isPasswordField(el)) return false;
    return el.type === 'text' || el.type === 'email' || el.type === 'tel' || el.type === '';
  }

  function isVisible(el) {
    if (!el.isConnected || el.disabled) return false;
    var rect = el.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) return false;
    var style = getComputedStyle(el);
    return style.visibility !== 'hidden' && style.display !== 'none';
  }

  function autocompleteTokens(el) {
    return (el.getAttribute('autocomplete') || '').toLowerCase().split(/\s+/);
  }

  var USERNAME_HINT = /user|email|e-mail|login|account|identifier|\buid\b|^id$|name_?id/i;
  var NOT_A_USERNAME = /search|query|captcha|otp|code|token|first|last|full|phone|zip|postal|city|address/i;

  function usernameScore(el) {
    var tokens = autocompleteTokens(el);
    if (tokens.indexOf('username') !== -1) return 100;
    var label = (el.name || '') + ' ' + (el.id || '');
    if (NOT_A_USERNAME.test(label) || tokens.indexOf('one-time-code') !== -1) return -1;
    var score = 1;
    if (tokens.indexOf('email') !== -1 || el.type === 'email') score += 20;
    if (USERNAME_HINT.test(label)) score += 30;
    return score;
  }

  // Everything that belongs to one sign-in: the form, or for the many
  // sign-ins built without a <form>, the nearest container that holds the
  // password field together with a text field.
  function scopeOf(el) {
    if (el.form) return el.form;
    var node = el.parentElement;
    for (var depth = 0; node && depth < 8; depth++, node = node.parentElement) {
      if (node.querySelectorAll('input').length > 1 && node.querySelector('input[type=password]')) return node;
    }
    return document.body || document.documentElement;
  }

  function inputsIn(scope) {
    var all = scope instanceof HTMLFormElement ? Array.prototype.slice.call(scope.elements) : Array.prototype.slice.call(scope.querySelectorAll('input'));
    return all.filter(function (el) { return el instanceof HTMLInputElement && (scope instanceof HTMLFormElement || !el.form); });
  }

  // Most sign-up forms never say `autocomplete=new-password`: one password
  // field and a "Create account" button is all there is. Read the field's own
  // name first, then the form's and its submit button's words. Any sign of a
  // sign-in wins, because a sign-in taken for a sign-up loses autofill, which
  // is worse than a sign-up taken for a sign-in, which only loses the offer.
  var SIGNUP_WORDS = /sign.?up|register|registration|create.?(an?.?|your.?)?account|new.?account|join|enrol|get.?started/i;
  var SIGNIN_WORDS = /sign.?in|log.?in|log.?on|authenticat/i;

  function looksLikeSignup(scope, field) {
    var hints = [field.getAttribute('name'), field.getAttribute('id'), field.getAttribute('aria-label'), field.getAttribute('placeholder')].join(' ');
    if (/current|old|existing/i.test(hints)) return false;
    if (/(^|[^a-z])new|create|choose|register|sign.?up/i.test(hints)) return true;
    var words = [];
    if (scope instanceof HTMLFormElement) {
      // getAttribute: `form.id` is shadowed by a field named "id".
      words.push(scope.getAttribute('id'), scope.getAttribute('name'), scope.getAttribute('action'), scope.getAttribute('class'));
    }
    Array.prototype.forEach.call(scope.querySelectorAll('button, input[type=submit]'), function (button) {
      if (button instanceof HTMLButtonElement && button.type !== 'submit') return;
      words.push(button instanceof HTMLInputElement ? button.value : button.textContent);
    });
    var text = words.join(' ');
    return SIGNUP_WORDS.test(text) && !SIGNIN_WORDS.test(text);
  }

  // { kind: 'login' | 'signup' | 'change', username, password, newPasswords: [] }
  function describe(scope) {
    var inputs = inputsIn(scope);
    var passwords = inputs.filter(function (el) { return isPasswordField(el) && isVisible(el); });
    if (!passwords.length) return null;

    var first = passwords[0];
    var before = inputs.filter(function (el) {
      return isTextLike(el) && isVisible(el) && (el.compareDocumentPosition(first) & Node.DOCUMENT_POSITION_FOLLOWING);
    });
    var username = null, best = 0;
    before.forEach(function (el) {
      // Later fields win ties: the one nearest the password is the likelier.
      var score = usernameScore(el);
      if (score >= best && score > 0) { best = score; username = el; }
    });

    var isNew = function (el) { return autocompleteTokens(el).indexOf('new-password') !== -1; };
    var isCurrent = function (el) { return autocompleteTokens(el).indexOf('current-password') !== -1; };
    var form = { scope: scope, username: username, password: null, newPasswords: [] };
    if (passwords.length === 1) {
      if (isNew(first) || (!isCurrent(first) && looksLikeSignup(scope, first))) { form.kind = 'signup'; form.newPasswords = [first]; }
      else { form.kind = 'login'; form.password = first; }
    } else if (passwords.length === 2 && !isCurrent(first)) {
      form.kind = 'signup'; form.newPasswords = passwords;          // password + confirm
    } else {
      form.kind = 'change'; form.password = first; form.newPasswords = passwords.slice(1);
    }
    return form;
  }

  function allForms() {
    var scopes = [], forms = [];
    Array.prototype.forEach.call(document.querySelectorAll('input[type=password]'), function (el) { isPasswordField(el); });
    Array.prototype.forEach.call(document.querySelectorAll('input'), function (el) {
      if (!isPasswordField(el)) return;
      var scope = scopeOf(el);
      if (scopes.indexOf(scope) !== -1) return;
      scopes.push(scope);
      var form = describe(scope);
      if (form) forms.push(form);
    });
    return forms;
  }

  // The first page of an identifier-first sign-in: a username, no password yet.
  function isLoneUsernameField(el) {
    if (!isTextLike(el) || !isVisible(el)) return false;
    var scope = el.form;
    if (scope && inputsIn(scope).some(isPasswordField)) return false;
    if (autocompleteTokens(el).indexOf('username') !== -1) return true;
    if (!scope) return false;
    var textFields = inputsIn(scope).filter(function (other) { return isTextLike(other) && isVisible(other); });
    return textFields.length === 1 && usernameScore(el) > 20;
  }

  function formFor(el) {
    if (!(el instanceof HTMLInputElement)) return null;
    var forms = allForms();
    for (var i = 0; i < forms.length; i++) {
      var form = forms[i];
      if (form.username === el || form.password === el || form.newPasswords.indexOf(el) !== -1) return form;
    }
    return null;
  }

  function roleOf(el, form) {
    if (form) {
      if (form.newPasswords.indexOf(el) !== -1) return 'new-password';
      if (form.password === el) return 'password';
      if (form.username === el) return form.kind === 'login' ? 'username' : null;
    }
    return isLoneUsernameField(el) ? 'username' : null;
  }

  // ------------------------------------------------------------- reporting

  var reported = null;
  var firstReport = true;

  function report() {
    var forms = allForms();
    var logins = forms.filter(function (f) { return f.kind === 'login'; });
    var summary = {
      kind: 'forms',
      login: logins.length,
      signup: forms.length - logins.length,
      // So the app fills the account the page already names, not another one.
      prefilledUsername: logins.length && logins[0].username ? logins[0].username.value : '',
      passwordEmpty: !logins.length || !logins[0].password.value
    };
    var key = JSON.stringify(summary);
    if (key === reported) return;
    // Frames with nothing to say stay quiet; the main frame always speaks,
    // because "the sign-in form is gone" is how a successful sign-in shows.
    if (reported === null && !forms.length && window !== window.top) return;
    reported = key;
    summary.fresh = firstReport;
    firstReport = false;
    post(summary);
  }

  var reportTimer = 0;
  function reportSoon() {
    clearTimeout(reportTimer);
    reportTimer = setTimeout(report, 250);
  }

  function start() {
    report();
    new MutationObserver(reportSoon).observe(document.documentElement, {
      childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'style', 'class', 'hidden', 'disabled']
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
  window.addEventListener('load', report);
  window.addEventListener('pageshow', function (event) {
    if (event.persisted) { reported = null; firstReport = true; report(); }
  });

  // ----------------------------------------------------------------- focus

  // In the top window's viewport, which is what the app can place a panel
  // against. Null inside a cross-origin frame, whose offset is unknowable.
  function topRect(el) {
    var rect = el.getBoundingClientRect();
    var x = rect.left, y = rect.top, w = window;
    try {
      while (w !== w.top) {
        var frame = w.frameElement;
        if (!frame) return null;
        var outer = frame.getBoundingClientRect();
        x += outer.left + frame.clientLeft;
        y += outer.top + frame.clientTop;
        w = w.parent;
      }
    } catch (e) { return null; }
    return { x: x, y: y, width: rect.width, height: rect.height };
  }

  var focused = null;

  function announceFocus(el) {
    var form = formFor(el);
    var role = roleOf(el, form);
    if (!role) { if (focused) { focused = null; post({ kind: 'blur' }); } return; }
    focused = { el: el, form: form, role: role };
    var message = { kind: 'focus', role: role, rect: topRect(el), text: role === 'username' ? el.value : '', empty: !el.value };
    if (role === 'new-password') {
      // What the site accepts, so the password offered is one it will take.
      message.rules = el.getAttribute('passwordrules') || '';
      message.minLength = el.minLength;
      message.maxLength = el.maxLength;
    }
    post(message);
  }

  document.addEventListener('focusin', function (event) { announceFocus(event.target); }, true);
  // A click on the field that already has focus asks for the list again.
  document.addEventListener('mousedown', function (event) {
    if (focused && event.target === focused.el) announceFocus(event.target);
  }, true);
  document.addEventListener('focusout', function () {
    if (focused) { focused = null; post({ kind: 'blur' }); }
  }, true);
  window.addEventListener('scroll', function () { if (focused) post({ kind: 'dismiss' }); }, true);
  window.addEventListener('resize', function () { if (focused) post({ kind: 'dismiss' }); });

  // ---------------------------------------------------------------- typing

  var touched = new WeakSet();   // fields the user typed in, or we filled
  var filling = false;           // our own input events are not the user typing

  document.addEventListener('input', function (event) {
    var el = event.target;
    if (!(el instanceof HTMLInputElement)) return;
    touched.add(el);
    if (filling) return;
    if (focused && focused.el === el) {
      // Only ever the username, to narrow the list. Never a password.
      post({ kind: 'input', role: focused.role, text: focused.role === 'username' ? el.value : '' });
    }
    if (isLoneUsernameField(el)) post({ kind: 'username-hint', username: el.value });
  }, true);

  // ------------------------------------------------------------ submission

  function candidateFrom(form, trigger) {
    var password = form.kind === 'login' ? form.password : form.newPasswords[0];
    if (!password || !password.value) return null;
    if (form.kind !== 'login' && form.newPasswords.length > 1 && form.newPasswords[1].value !== password.value) return null;
    var fields = [password, form.username].filter(Boolean);
    if (!fields.some(function (el) { return touched.has(el); })) return null;
    return {
      kind: 'candidate', trigger: trigger, form: form.kind,
      username: form.username ? form.username.value : '',
      password: password.value,
      // Whose password a change form is changing, when it has no username.
      currentPassword: form.kind === 'change' && form.password ? form.password.value : ''
    };
  }

  function formAround(node) {
    var forms = allForms();
    for (var i = 0; i < forms.length; i++) {
      if (forms[i].scope === node || forms[i].scope.contains(node)) return forms[i];
    }
    return null;
  }

  function capture(node, trigger) {
    var form = formAround(node);
    var candidate = form && candidateFrom(form, trigger);
    if (candidate) post(candidate);
  }

  document.addEventListener('submit', function (event) { capture(event.target, 'submit'); }, true);

  // Sign-ins without a <form> never fire `submit`: pressing the button or
  // Return is all there is. The app only acts on these once the form is gone.
  document.addEventListener('click', function (event) {
    var button = event.target instanceof Element && event.target.closest('button, input[type=submit], input[type=button], [role=button], a');
    if (!button || (button instanceof HTMLButtonElement && button.type === 'reset')) return;
    capture(button, 'click');
  }, true);
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Enter' && event.target instanceof HTMLInputElement) capture(event.target, 'enter');
  }, true);

  // --------------------------------------------------------------- filling

  // This world's own, untouched setter. Frameworks that track a field's value
  // (React) do it on the page world's wrapper, which this call goes beneath:
  // the framework then sees a real change when the input event arrives.
  var nativeValueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;

  function setValue(el, value) {
    if (el.readOnly || el.disabled) return false;
    nativeValueSetter.call(el, value);
    touched.add(el);
    filling = true;
    try {
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } finally { filling = false; }
    return el.value === value;
  }

  function targetForm(kinds) {
    if (focused && focused.form && kinds.indexOf(focused.form.kind) !== -1) return focused.form;
    var forms = allForms().filter(function (f) { return kinds.indexOf(f.kind) !== -1; });
    return forms[0] || null;
  }

  window.__sbPasswords = {
    // Fill a saved sign-in. `onlyIfEmpty` is the fill that happens on its own
    // when a page loads: it never overwrites what the person or page put there.
    fill: function (options) {
      var result = { username: false, password: false };
      if (focused && focused.role === 'username' && !focused.form) {
        result.username = setValue(focused.el, options.username);      // identifier-first page
        return result;
      }
      var form = targetForm(['login', 'change']);
      if (!form) return result;
      if (options.onlyIfEmpty) {
        if (form.password.value) return result;
        if (form.username && form.username.value && form.username.value !== options.username) return result;
      }
      if (form.username && form.username.value !== options.username) result.username = setValue(form.username, options.username);
      result.password = setValue(form.password, options.password);
      return result;
    },

    // Fill a generated password into the new-password field and its confirmation.
    fillNew: function (options) {
      var form = targetForm(['signup', 'change']);
      if (!form) return { filled: false, username: '' };
      var filled = form.newPasswords.map(function (el) { return setValue(el, options.password); });
      return { filled: filled.length > 0 && filled.every(Boolean), username: form.username ? form.username.value : '' };
    },

    state: function () {
      return allForms().map(function (form) {
        return { kind: form.kind, hasUsername: !!form.username, newPasswords: form.newPasswords.length };
      });
    }
  };
})();
