---
name: Release
trigger:
  button: { label: "Release", confirm: true }
permissions:
  - session:start
outputs: [report]
budget: { tokens: 30000, minutes: 60 }
---
Релиз watchtower одной сессией через скил /release: проверка и правка документации, сверка, что всё новое есть в доке и на Home, затем публичный релиз, корп и мобильное приложение.

```js
const s = session({
  title: "Release",
  prompt: "Cut a release of this product with the /release skill: the public release, the corp build and the iPhone app. " +
    "As part of it, check the documentation and fix what is wrong, and make sure every new feature and change since the last release is documented and shows up on Home. " +
    "Report the result in your final summary."
});
output.report({
  title: s.status === "finished" ? "Release finished" : "Release: " + s.status,
  body: s.summary || s.error || ""
});
```
