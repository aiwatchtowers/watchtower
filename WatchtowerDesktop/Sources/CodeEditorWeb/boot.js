// The page's bridge to Swift and its error reporting, loaded before
// anything else so a failure in languages.js or the Monaco loader is
// reported. Kept out of index.html: the page's CSP allows no inline script.
function post(message) {
  try { window.webkit.messageHandlers.wt.postMessage(message); } catch (e) {}
}
window.addEventListener("error", function (e) { post({ type: "error", message: String(e.message || e) }); });
window.addEventListener("unhandledrejection", function (e) {
  var reason = e.reason;
  post({ type: "error", message: "Editor: " + String((reason && reason.message) || reason) });
});
window.addEventListener("securitypolicyviolation", function (e) {
  post({ type: "error", message: "Editor: blocked by the page policy: " + e.violatedDirective + " " + e.blockedURI });
});
