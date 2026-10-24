import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { JSDOM } from "jsdom";

const webRoot = new URL("../../src/campusflow_agent/web/", import.meta.url);
const readWeb = (path) => readFileSync(new URL(path, webRoot), "utf8");
const scripts = ["vendor/marked-18.1.1.umd.js", "vendor/purify-3.4.17.min.js", "markdown.js"].map(readWeb);

function environment({ dependencies = true } = {}) {
  const dom = new JSDOM('<div id="messages"></div>', {
    url: "http://127.0.0.1:8000/",
    runScripts: "outside-only",
  });
  if (dependencies) scripts.slice(0, 2).forEach((script) => dom.window.eval(script));
  dom.window.eval(scripts[2]);
  return dom;
}

function reply(dom, source) {
  const bubble = dom.window.document.createElement("div");
  assert.equal(dom.window.CampusFlowMarkdown.render(bubble, source), true);
  return bubble;
}

test("assistant replies render mixed headings, lists, emphasis, quotes and literal code", () => {
  const dom = environment();
  const bubble = reply(dom, "## 今日安排\n\n**复习**和*练习*，使用 `a | b`。\n\n- 阅读\n- 实践\n\n3. 第三项\n4. 第四项\n\n> 记得休息\n\n```html\n<img src=x onerror=alert(1)>\n| 不是 | 表格 |\n```\n\n结束。");
  assert.equal(bubble.querySelector("h2").textContent, "今日安排");
  assert.equal(bubble.querySelector("strong").textContent, "复习");
  assert.equal(bubble.querySelector("em").textContent, "练习");
  assert.equal(bubble.querySelector("code").textContent, "a | b");
  assert.equal(bubble.querySelectorAll("ul li").length, 2);
  assert.equal(bubble.querySelector("ol").getAttribute("start"), "3");
  assert.match(bubble.querySelector("blockquote").textContent, /记得休息/);
  assert.match(bubble.querySelector("pre code").textContent, /<img src=x onerror=alert\(1\)>/);
  assert.equal(bubble.querySelectorAll("img, table").length, 0);
  assert.match(bubble.textContent, /结束/);
  dom.window.close();
});

test("GFM tables retain columns, alignment, escaped pipes and inline formatting", () => {
  const dom = environment();
  const bubble = reply(dom, "安排如下：\n\n| 课程 | 时间 | 地点 |\n| :--- | :---: | ---: |\n| **数学** | 08:00 | 1教 |\n| 名称\\|别名 | `09:00` | 2教 |\n\n记得带书。");
  const table = bubble.querySelector("table");
  assert.ok(table);
  assert.equal(table.querySelectorAll("th").length, 3);
  assert.equal(table.querySelectorAll("tbody tr").length, 2);
  assert.equal(table.querySelector("th").scope, "col");
  assert.equal(table.querySelectorAll("th")[1].getAttribute("align"), "center");
  assert.equal(table.querySelectorAll("th")[2].getAttribute("align"), "right");
  assert.equal(table.querySelectorAll("tbody tr")[1].children[0].textContent, "名称|别名");
  assert.equal(table.querySelector("td strong").textContent, "数学");
  assert.equal(table.style.minWidth, "420px");
  assert.equal(table.parentElement.className, "markdown-table-scroll");
  assert.equal(table.parentElement.tabIndex, 0);
  assert.match(bubble.textContent, /安排如下.*记得带书/s);
  dom.window.close();
});

test("incomplete table syntax and fenced pipes retain readable content", () => {
  const dom = environment();
  const bubble = reply(dom, "| 课程 | 时间 |\n\n```\n| a | b |\n| --- | --- |\n");
  assert.equal(bubble.querySelectorAll("table").length, 0);
  assert.match(bubble.textContent, /\| 课程 \| 时间 \|/);
  assert.match(bubble.querySelector("pre code").textContent, /\| --- \| --- \|/);
  dom.window.close();
});

test("overflow table cells fall back without losing content, while inline-code pipes stay in their cell", () => {
  const dom = environment();
  const raw = '| A | B |\n| --- | --- |\n| one | two | three <script>alert(1)</script> |';
  const bubble = reply(dom, `前文。\n\n${raw}\n\n后文。`);
  assert.equal(bubble.querySelectorAll("table, script").length, 0);
  assert.equal(bubble.querySelector("pre code").textContent, raw);
  assert.match(bubble.textContent, /前文.*three.*后文/s);
  const valid = reply(dom, "| A | B |\n| :---: | ---: |\n| `a | b` | right |\n| ``c ` | d`` | retained |\n| escape\\|pipe | end |");
  const rows = valid.querySelectorAll("tbody tr");
  assert.equal(rows.length, 3);
  assert.equal(rows[0].children.length, 2);
  assert.equal(rows[0].children[0].querySelector("code").textContent, "a | b");
  assert.equal(rows[0].children[1].textContent, "right");
  assert.equal(rows[1].children[0].querySelector("code").textContent, "c ` | d");
  assert.equal(rows[1].children[1].textContent, "retained");
  assert.equal(rows[2].children[0].textContent, "escape|pipe");
  assert.equal(valid.querySelectorAll("th")[0].getAttribute("align"), "center");
  assert.equal(rows[0].children[1].getAttribute("align"), "right");
  assert.equal(valid.querySelectorAll("pre").length, 0);
  dom.window.close();
});

test("raw HTML, event handlers, SVG, iframes and Markdown images never create active elements", () => {
  const dom = environment();
  const source = '<script>window.attacked=true</script>\n\n<img src="https://example.com/track" onerror="alert(1)">\n\n<svg onload="alert(1)"></svg>\n\n<iframe src="https://example.com"></iframe>\n\n![课程图片](https://example.com/tracker.png)';
  const bubble = reply(dom, source);
  assert.equal(bubble.querySelectorAll("script,img,svg,iframe,object,embed,input,style").length, 0);
  assert.equal(dom.window.attacked, undefined);
  assert.match(bubble.textContent, /<script>window.attacked=true<\/script>/);
  assert.match(bubble.textContent, /课程图片/);
  for (const element of bubble.querySelectorAll("*")) {
    for (const attribute of element.attributes) {
      assert.equal(/^on/i.test(attribute.name), false);
      assert.notEqual(attribute.name, "src");
    }
  }
  dom.window.close();
});

test("dangerous and relative URLs have text labels without clickable destinations", () => {
  const dom = environment();
  const unsafe = ["javascript:alert(1)", "java&#x73;cript:alert(1)", "javascript&#58;alert(1)",
    "data:text/html;base64,PHNjcmlwdD4=", "vbscript:msgbox(1)", "file:///C:/secret", "/logout", "//evil.example/test", "ftp://example.com/test"];
  for (const href of unsafe) {
    const bubble = reply(dom, `[链接](${href})`);
    assert.equal(bubble.querySelectorAll("a[href]").length, 0, href);
    assert.match(bubble.textContent, /链接/);
  }
  const bubble = reply(dom, '[安全](https://example.com/?q=one&n=two "说明")、[邮箱](mailto:help@example.com)');
  const links = bubble.querySelectorAll("a");
  assert.equal(links.length, 2);
  assert.equal(links[0].href, "https://example.com/?q=one&n=two");
  assert.equal(links[0].getAttribute("title"), "说明");
  assert.equal(links[0].target, "_blank");
  assert.equal(links[0].rel, "noopener noreferrer");
  assert.equal(links[1].href, "mailto:help@example.com");
  dom.window.close();
});

test("dependency or parser failure preserves the complete original reply as text", () => {
  const dom = environment({ dependencies: false });
  const bubble = dom.window.document.createElement("div");
  bubble.innerHTML = "<p>old reply</p>";
  bubble.className = "markdown-content";
  const source = "| 原文 | 保留 |\n<img src=x onerror=alert(1)>";
  assert.equal(dom.window.CampusFlowMarkdown.render(bubble, source), false);
  assert.equal(bubble.textContent, source);
  assert.equal(bubble.children.length, 0);
  assert.equal(bubble.classList.contains("markdown-content"), false);
  dom.window.close();

  const failingDom = environment();
  failingDom.window.DOMPurify.sanitize = () => { throw new Error("Unexpected parser failure"); };
  const target = failingDom.window.document.createElement("div");
  assert.equal(failingDom.window.CampusFlowMarkdown.render(target, source), false);
  assert.equal(target.textContent, source);
  failingDom.window.close();
});

test("actual appendMessage renders new and restored assistant replies but keeps user text literal", () => {
  const dom = environment();
  const appSource = readWeb("app.js");
  const appendFunction = appSource.slice(appSource.indexOf("function appendMessage("), appSource.indexOf("const SVG_NS"));
  dom.window.eval(`
    const state = { user: { display_name: "同学" } };
    const elements = { messages: document.querySelector("#messages") };
    function clearEmptyState() {}
    function scrollMessages() {}
    function modelLabel() { return "FLASH"; }
    ${appendFunction}
  `);
  const source = "| 课程 | 时间 |\n| --- | --- |\n| 数学 | 08:00 |";
  dom.window.appendMessage("user", source);
  dom.window.appendMessage("assistant", source);
  // Reproduce the actual restoration path, which also calls appendMessage.
  [{ role: "user", content: "**输入**" }, { role: "assistant", content: source }]
    .forEach((message) => dom.window.appendMessage(message.role, message.content));
  const messages = dom.window.document.querySelectorAll(".message");
  assert.equal(messages[0].querySelector(".bubble").textContent, source);
  assert.equal(messages[0].querySelectorAll("table").length, 0);
  assert.equal(messages[1].querySelectorAll("table").length, 1);
  assert.equal(messages[2].querySelector(".bubble").textContent, "**输入**");
  assert.equal(messages[3].querySelectorAll("table").length, 1);
  const loading = dom.window.appendMessage("assistant", "", { loading: true });
  assert.equal(loading.querySelectorAll(".typing > span").length, 3);
  assert.equal(loading.querySelectorAll(".markdown-content").length, 0);
  assert.match(appSource, /history\.forEach\(\(message\) => appendMessage\(message\.role, message\.content\)\)/);
  dom.window.close();
});
