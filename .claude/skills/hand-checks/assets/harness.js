// Drives the runner like a tester: a fail verdict with a step, a note, and a tick, then export, a clear, an
// import, and the summary. Load the page with #<check-id> of a check whose launch is not "none".
window.addEventListener("load", function () {
  var ID = location.hash.slice(1);
  var check = (window.UHC_CHECKS || []).filter(function (c) { return c.id === ID; })[0];
  var out = [];
  function log(k, v) { out.push(k + "=" + JSON.stringify(v)); }
  try {
    var captured = null;
    var origCreate = URL.createObjectURL;
    URL.createObjectURL = function (b) { captured = b; return origCreate.call(URL, b); };
    HTMLAnchorElement.prototype.click = function () {};
    var t = document.getElementById("tester"); t.value = "Test Person"; t.dispatchEvent(new Event("input"));
    log("title", document.querySelector(".content h2").textContent);
    log("stamp", document.getElementById("stamp").textContent);
    var fail = document.querySelector(".verdicts button.fail"); fail.click();
    var sel = document.getElementById("failed-step"); sel.value = "2"; sel.dispatchEvent(new Event("change"));
    var n = document.getElementById("notes"); n.value = "Popup opened anyway"; n.dispatchEvent(new Event("input"));
    var cb = document.querySelector(".expected input"); cb.checked = true; cb.dispatchEvent(new Event("change"));
    var st = JSON.parse(localStorage.getItem("uhc-results-v1"));
    var r = st.results[ID];
    log("verdict", r.verdict); log("failedStep", r.failedStep); log("seen0", r.seen[0]); log("stampCommit", r.stamp && r.stamp.commit);
    log("pressed", document.querySelector(".verdicts button.fail").getAttribute("aria-pressed"));
    log("milestoneChip", Array.from(document.querySelectorAll(".milestone")).map(function(m){return m.textContent}).filter(function(t){return t.indexOf(check.milestone + ":")===0}));
    var f = document.getElementById("filter"); f.value = check.proposal; f.dispatchEvent(new Event("change"));
    log("listItems", document.querySelectorAll(".item").length);
    log("progress", document.getElementById("progress").textContent);
    document.getElementById("export").click();
    captured.text().then(function (txt) {
      var doc = JSON.parse(txt);
      log("export", { format: doc.format, tester: doc.tester, scope: doc.scope, n: doc.results.length, inScope: doc.checksInScope.length, v: doc.results[0].verdict, step: doc.results[0].failedStep });
      localStorage.clear();
      return new Promise(function (res) {
        var file = new File([txt], "r.json", { type: "application/json" });
        var input = document.getElementById("import-file");
        var dt = new DataTransfer(); dt.items.add(file); input.files = dt.files;
        input.dispatchEvent(new Event("change"));
        setTimeout(res, 300);
      });
    }).then(function () {
      var st2 = JSON.parse(localStorage.getItem("uhc-results-v1"));
      log("afterImport", st2.results[ID].verdict);
      document.getElementById("summary").click();
      log("summaryHas", document.querySelector(".summary textarea").value.indexOf("- Fail: ") >= 0);
      log("summarySnippet", document.querySelector(".summary textarea").value.split("\n").filter(function(l){return l.indexOf("Fail")>=0||l.indexOf("> ")>=0}).slice(0,4));
    }).catch(function (e) { log("error", String(e)); }).finally(function () {
      var pre = document.createElement("pre"); pre.id = "harness-out"; pre.textContent = out.join("\n"); document.body.appendChild(pre);
    });
  } catch (e) {
    log("error", e.stack || String(e));
    var pre = document.createElement("pre"); pre.id = "harness-out"; pre.textContent = out.join("\n"); document.body.appendChild(pre);
  }
});
