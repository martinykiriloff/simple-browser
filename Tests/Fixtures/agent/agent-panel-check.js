// Runs inside the first tab's DevTools while mcp-e2e.py drives that tab over
// MCP: the Agent panel must list the calls, newest last, with their results.
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const out = { failures: [] };
const check = (name, ok, detail) => { if (!ok) out.failures.push(name + (detail !== undefined ? ": " + JSON.stringify(detail) : "")); };
for (let i = 0; i < 600 && !(window.AgentPanel && AgentPanel.calls.some((c) => c.tool === "get_page_content")); i++) await wait(500);
const panel = window.AgentPanel;
check("the Agent panel exists", !!panel);
if (panel) {
  const tab = document.querySelector('#tabs .tab[data-panel="agent"]');
  check("its tab appears once an agent acts", tab && !tab.hidden, tab && tab.textContent);
  DevTools.showPanel("agent"); await wait(300);
  const tools = panel.calls.map((c) => c.tool);
  check("calls arrive in order", tools.indexOf("snapshot") >= 0 && tools.indexOf("snapshot") < tools.indexOf("get_page_content"), tools);
  check("a failing call is marked", panel.calls.some((c) => c.isError) && document.querySelector(".agent-call.agent-error") !== null);
  check("rows render", document.querySelectorAll("#agent-list .agent-call").length === panel.calls.length, document.querySelectorAll("#agent-list .agent-call").length);
  document.querySelector("#agent-list .agent-head").click(); await wait(100);
  check("a row expands to arguments and result", document.querySelectorAll(".agent-detail pre").length >= 2);
  check("the session copies as Markdown", panel.markdown().startsWith("# Agent session") && panel.markdown().includes("### snapshot"));
  check("the client is named", /Claude Code|Agent E2e/i.test(document.querySelector("#agent-client").textContent), document.querySelector("#agent-client").textContent);
  out.calls = tools.length;
}
out.passed = out.failures.length === 0;
return out;
