#!/usr/bin/env python3
"""Fixture site for the password manager self-test.

    python3 Tests/Fixtures/passwords/server.py        # http://127.0.0.1:8766/

Sign-in pages of every shape the password agent has to cope with: a classic
form, a form-less single-page sign-in, a sign-up, a change-password form, a
two-page (identifier first) sign-in, a React-style controlled form, and sign-in
forms inside same-origin and cross-origin frames. Accounts live in memory;
GET /state shows them, POST /reset puts them back.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

PORT = 8766
DEFAULT_USERS = {"ada": "correct-horse", "bob": "bobs-password"}
users = dict(DEFAULT_USERS)

STYLE = "<style>body{font:15px -apple-system,system-ui;margin:3em auto;max-width:30em}label{display:block;margin:.7em 0}input{font:inherit;width:18em}.error{color:#b00}</style>"


def page(title, body):
    return f"<!doctype html><meta charset=utf-8><title>{title}</title>{STYLE}<h1>{title}</h1>{body}"


def login_form(error="", username=""):
    return page("Sign in", f"""
<p class=error id=error>{error}</p>
<form method=post action=/login id=login>
  <label>Search the site <input name=q type=search></label>
  <label>Username <input name=username id=username value="{username}"></label>
  <label>Password <input name=password id=password type=password></label>
  <label><input type=checkbox id=show style="width:auto" onclick="password.type = this.checked ? 'text' : 'password'"> Show password</label>
  <button id=submit>Sign in</button>
</form>""")


SIGNUP = page("Create an account", """
<form method=post action=/signup id=signup>
  <label>Full name <input name=fullname id=fullname autocomplete=name></label>
  <label>Email <input name=email id=email type=email autocomplete=email></label>
  <label>Password <input name=password id=password type=password autocomplete=new-password></label>
  <label>Confirm password <input name=confirm id=confirm type=password autocomplete=new-password></label>
  <button id=submit>Create account</button>
</form>""")

# A sign-up form as most sites write one: nothing says "new-password", only
# the button's words. It also limits the password, as many banks do.
REGISTER = page("Register", """
<form method=post action=/register id=register>
  <label>Email <input name=email id=email type=email></label>
  <label>Password <input name=password id=password type=password maxlength=16
    passwordrules="required: upper; required: digit; required: [!#]; minlength: 12;"></label>
  <button id=submit>Create account</button>
</form>""")

CHANGE = page("Change your password", """
<form method=post action=/change id=change>
  <label>Current password <input name=current id=current type=password autocomplete=current-password></label>
  <label>New password <input name=password id=new type=password autocomplete=new-password></label>
  <label>Confirm <input name=confirm id=confirm type=password autocomplete=new-password></label>
  <button id=submit>Change password</button>
</form>""")

SPA = page("Single-page sign in", """
<div id=app><div class=card>
  <p class=error id=error></p>
  <label>Email <input id=username type=email></label>
  <label>Password <input id=password type=password></label>
  <div role=button tabindex=0 id=submit style="display:inline-block;padding:.4em 1em;border:1px solid #888;border-radius:6px;cursor:default">Sign in</div>
</div></div>
<script>
document.getElementById('submit').addEventListener('click', async () => {
  const body = JSON.stringify({ username: username.value, password: password.value });
  const response = await fetch('/api/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body });
  if (response.ok) document.getElementById('app').innerHTML = '<p id=signed-in>Signed in. No page load happened.</p>';
  else document.getElementById('error').textContent = 'Wrong email or password.';
});
</script>""")

# What React does to inputs, without React: the instance's `value` property is
# shadowed to track what the framework last saw, the DOM is forced back to the
# component state after every event, and only a change the tracker did not see
# reaches the state. Filling by plain `el.value = x` from the page fails here.
REACT = page("Controlled-input sign in", """
<p class=error id=result></p>
<form id=login onsubmit="return false">
  <label>Username <input id=username autocomplete=username></label>
  <label>Password <input id=password type=password autocomplete=current-password></label>
  <button id=submit>Sign in</button>
</form>
<script>
window.__state = { username: '', password: '' };
for (const el of [username, password]) {
  const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
  let tracked = '';
  Object.defineProperty(el, 'value', {
    configurable: true,
    get() { return native.get.call(this); },
    set(v) { tracked = String(v); native.set.call(this, v); }
  });
  el.addEventListener('input', () => {
    const now = native.get.call(el);
    if (now !== tracked) { tracked = now; window.__state[el.id] = now; }   // onChange
    el.value = window.__state[el.id];                                        // re-render from state
  });
}
submit.addEventListener('click', async () => {
  const response = await fetch('/api/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(window.__state) });
  result.textContent = response.ok ? 'ok' : 'rejected';
  if (response.ok) login.remove();
});
</script>""")

FRAMES = page("Sign-in forms in frames", f"""
<p>This page has no sign-in form of its own.</p>
<iframe id=same src="/login" width=420 height=330></iframe>
<iframe id=cross src="http://localhost:{PORT}/login" width=420 height=330></iframe>""")

TWO_STEP_1 = page("Sign in: step 1", """
<form method=post action=/two-step id=step1>
  <label>Email or username <input name=username id=username autocomplete=username></label>
  <button id=submit>Next</button>
</form>""")


def two_step_2(username, error=""):
    return page("Sign in: step 2", f"""
<p class=error>{error}</p><p>Signing in as <b>{username}</b></p>
<form method=post action=/two-step/password id=step2>
  <input type=hidden name=username value="{username}">
  <label>Password <input name=password id=password type=password autocomplete=current-password></label>
  <button id=submit>Sign in</button>
</form>""")


INDEX = page("Password manager fixtures", "<ul>" + "".join(
    f'<li><a href="{p}">{p}</a>' for p in ["/login", "/signup", "/register", "/change", "/spa", "/react", "/frames", "/two-step", "/state"]) + "</ul>")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, status, body, content_type="text/html; charset=utf-8", headers=None):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, location):
        self.send(302, "", headers={"Location": location})

    def body(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        if "json" in (self.headers.get("Content-Type") or ""):
            return json.loads(raw or "{}")
        return {key: values[0] for key, values in parse_qs(raw, keep_blank_values=True).items()}

    def do_GET(self):
        path = self.path.split("?")[0]
        pages = {"/": INDEX, "/login": login_form(), "/signup": SIGNUP, "/register": REGISTER, "/change": CHANGE, "/spa": SPA,
                 "/react": REACT, "/frames": FRAMES, "/two-step": TWO_STEP_1,
                 "/welcome": page("Welcome", "<p id=welcome>You are signed in.</p><p><a href=/login>Sign in again</a></p>")}
        if path in pages:
            self.send(200, pages[path])
        elif path == "/state":
            self.send(200, json.dumps(users, indent=1), "application/json")
        else:
            self.send(404, page("Not found", ""))

    def do_POST(self):
        path = self.path.split("?")[0]
        form = self.body()
        username, password = form.get("username", ""), form.get("password", "")
        if path == "/login":
            if users.get(username) == password and password:
                self.redirect("/welcome")
            else:
                self.send(200, login_form("Wrong username or password.", username))
        elif path == "/api/login":
            ok = bool(password) and users.get(username) == password
            self.send(200 if ok else 401, json.dumps({"ok": ok}), "application/json")
        elif path == "/signup":
            if password and password == form.get("confirm"):
                users[form.get("email", "")] = password
                self.redirect("/welcome")
            else:
                self.send(200, SIGNUP)
        elif path == "/register":
            if password:
                users[form.get("email", "")] = password
                self.redirect("/welcome")
            else:
                self.send(200, REGISTER)
        elif path == "/change":
            owner = next((name for name, saved in users.items() if saved == form.get("current")), None)
            if owner and password and password == form.get("confirm"):
                users[owner] = password
                self.redirect("/welcome")
            else:
                self.send(200, CHANGE)
        elif path == "/two-step":
            self.send(200, two_step_2(username))
        elif path == "/two-step/password":
            if users.get(username) == password and password:
                self.redirect("/welcome")
            else:
                self.send(200, two_step_2(username, "Wrong password."))
        elif path == "/reset":
            users.clear()
            users.update(DEFAULT_USERS)
            self.send(200, "{}", "application/json")
        else:
            self.send(404, "")


if __name__ == "__main__":
    # All interfaces of the loopback name: `localhost` is the second origin.
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"http://127.0.0.1:{PORT}/")
    server.serve_forever()
