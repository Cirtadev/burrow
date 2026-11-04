// Before the first paint: the light or dark appearance the visitor picked with the switch, if any (main.js).
try {
  const theme = localStorage.getItem("theme");
  if (theme) document.documentElement.dataset.theme = theme;
} catch {}
