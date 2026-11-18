/** Return the greeting that the starter shows. */
export function greeting(): string {
  return "Hello from the Node/Vite starter!";
}

const root =
  typeof document === "undefined"
    ? null
    : document.querySelector<HTMLDivElement>("#app");

if (root) {
  root.textContent = greeting();
}
