# ui — Tailwind CSS 4 + shadcn/ui

Adds Tailwind 4 and shadcn/ui to a prototype that already has the `nextjs`
base. Additive: it touches nothing the base owns, so it can be applied at any
point, including after you have started building.

```sh
prototype layer add <name> ui
```

Then add components as you need them — not up front:

```sh
npx shadcn@latest add card input dialog
```

## What it does, and why each step

1. `tailwindcss @tailwindcss/postcss postcss` + `postcss.config.mjs` — Tailwind
   4 is a PostCSS plugin; there is no `tailwind.config.js` any more.
2. `jsconfig.json` with `@/*` — shadcn generates imports like
   `@/lib/utils`. Without the alias the components it writes do not resolve,
   and the failure appears in *its* files rather than yours.
3. `app/globals.css` seeded with `@import "tailwindcss";` — `shadcn init`
   appends its theme to this file, so it must exist first.
4. `shadcn init -d --yes` — installs deps, writes `components.json`, and lands
   `components/ui/button.jsx` + `lib/utils.js`. It detects JS from
   `jsconfig.json` and writes `.jsx`, not `.tsx`.
5. **Imports `globals.css` into `app/layout.jsx`** — `shadcn init` does not do
   this. Skip it and everything installs cleanly, reports success, and renders
   completely unstyled.

## Notes

- Re-running is a no-op (it checks for `components.json`).
- The base template's `/api/health` and plumbing are untouched.
