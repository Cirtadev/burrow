// Light or dark: the Mac's appearance until the visitor flips the switch. The screenshots follow, since their
// <source> elements only match the dark media query.
const root = document.documentElement;
const system = matchMedia("(prefers-color-scheme: dark)");
const isDark = () => (root.dataset.theme ? root.dataset.theme === "dark" : system.matches);
function applyTheme() {
  const theme = root.dataset.theme;
  document.querySelectorAll("picture source").forEach((source) => {
    source.media = theme ? (theme === "dark" ? "all" : "not all") : "(prefers-color-scheme: dark)";
  });
  document.querySelector(".theme-switch").title = isDark() ? "Light appearance" : "Dark appearance";
}
document.querySelector(".theme-switch").addEventListener("click", () => {
  const dark = !isDark();
  if (dark === system.matches) delete root.dataset.theme; else root.dataset.theme = dark ? "dark" : "light";
  try { root.dataset.theme ? localStorage.setItem("theme", root.dataset.theme) : localStorage.removeItem("theme"); } catch {}
  applyTheme();
});
system.addEventListener("change", applyTheme);
applyTheme();

// Point the download buttons at the newest disk image; without the API they open the latest release page.
fetch("https://api.github.com/repos/Cirtadev/burrow/releases/latest")
  .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
  .then((release) => {
    const dmg = release.assets.find((asset) => asset.name.endsWith(".dmg"));
    if (!dmg) return;
    const version = release.tag_name.replace(/^v/, "");
    const size = (dmg.size / 1e6).toFixed(1);
    document.querySelectorAll("[data-download]").forEach((link) => (link.href = dmg.browser_download_url));
    document.querySelectorAll("[data-version]").forEach((el) => (el.textContent = `Version ${version} · ${size} MB · `));
  })
  .catch(() => {});
